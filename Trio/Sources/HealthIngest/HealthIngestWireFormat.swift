import CryptoKit
import Foundation
import zlib

/// Wire contract for `POST {baseURL}/v1/ingest` and `GET {baseURL}/v1/status`.
///
/// Adjust this file when the private ingest server changes the JSON. The rest of the uploader
/// talks to these types and does not build request bodies itself.
///
/// HTTP 200 body: `{ "results": [ { "type", "id", "status", "reason"? } ] }`.
/// `status` is `accepted`, `duplicate`, or `rejected`. The upsert key is `(type, id)`.
///
/// A HealthKit sample may add optional siblings of `payload`: `sourceName`,
/// `sourceBundleIdentifier`, `deviceName`, `deviceModel`, `deviceManufacturer`.
/// Each value is 1...256 UTF-16 code units (JavaScript string length) and has no
/// Unicode control characters. An empty, too-long, or control-bearing value is
/// omitted. Values are not trimmed or shortened. There is no device object when
/// the sample has no `HKDevice`. `payload.source` stays the coarse label
/// (`healthkit`). Trio's own records omit the siblings. On a matching `(type, id)`
/// the server updates those source columns instead of treating the row as a duplicate.
enum HealthIngestWire {
    static let schemaVersion = 1
    static let appName = "trio"
    static let defaultDeviceID = "trio-iphone"
    static let ingestPath = "/v1/ingest"
    static let statusPath = "/v1/status"
    static let gzipThreshold = 1024
    static let maxBatchRecords = 500
    static let maxBatchBytes = 1024 * 1024
    static let maxPayloadBytes = 128 * 1024
    static let profileIDPrefix = "profile"
    static let settingsIDPrefix = "settings"
    static let effectiveIDPrefix = "effective"

    static func authorizationValue(token: String) -> String {
        "Bearer \(token)"
    }

    static func endpoint(_ origin: URL, path: String) -> URL? {
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else { return nil }
        let extra = path.hasPrefix("/") ? path : "/" + path
        let base = components.path == "/" ? "" : components.path
        components.path = base + extra
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// Bump when stored HealthKit rows must be read and sent again. A higher version
    /// clears rejected receipts, drops queued contract rows, resets HealthKit
    /// backfill cursors, and rewinds the Core Data read. The following pass uses
    /// the same page size, batch limits, and backlog pause as any other backfill.
    /// 4 resends Core Data loop cycles and effective profiles the server used to reject
    /// (finite predicted glucose, and schedule starts in HH:MM or HH:MM:SS).
    /// 5 clears the reject counter and the reason log together. Version 4 left the
    /// old counter in place after the new buffer was empty.
    /// 6 resends HealthKit history with each sample's source and device beside
    /// `payload`. The payload is unchanged, so the local receipt hash includes
    /// those fields and an accepted `(type, id)` is queued again.
    /// 7 rewinds the Core Data read so stored loop cycles are sent again with
    /// top-level glucose, eventual glucose, recommended bolus, target, threshold,
    /// carbs required, and carb ratio. Those values are already on
    /// `OrefDetermination`. The receipt hash changes only when the payload does,
    /// so an unchanged HealthKit sample or treatment is not uploaded again.
    /// An upgrade from 6 does not clear HealthKit cursors or anchors, and it does
    /// not start a HealthKit backfill. Stored Trio rows are reread from their own
    /// cursor. A fresh install, or an upgrade from before 6, still resets that backfill.
    /// 8 writes that same Core Data cursor so stored glucose is sent again with
    /// `trend` as well as `direction`. It does not clear HealthKit cursors or
    /// anchors and does not start a HealthKit backfill. `trendRate` and `sensor`
    /// are added only for readings the live G7 manager still has; they are not
    /// stored on the glucose row. `GlucoseStored` has `direction` and no numeric
    /// rate, so a later mapping version would reread the same payloads and is
    /// not used for `trendRate`. Meal `enteredAt` / `editedAt` and bolus
    /// `bolusSource` / `decisionId` are notes taken when Trio saved the row.
    /// They are not columns a Core Data rewind would newly find.
    /// 9 rewinds that Core Data cursor again so stored glucose is sent with
    /// `source` in the payload. The source was already in the record id. It does
    /// not clear HealthKit cursors or anchors and does not start a HealthKit backfill.
    /// Each later version needs a step in `HealthIngestMappingUpgrade.steps`.
    /// A missing step resets the HealthKit backfill instead of skipping the resend.
    static let mappingVersion = 9

    static func encodeEnvelope(_ envelope: HealthIngestEnvelope) throws -> Data {
        // CanonicalJSON matches the server's stableJson, so content-addressed
        // ids and the bytes on the wire cannot drift apart.
        Data(HealthIngestCanonicalJSON.string(envelope.asJSON()).utf8)
    }

    static func encode(_ value: some Encodable) throws -> Data {
        try makeEncoder().encode(value)
    }

    static func encodePayload(_ payload: HealthIngestJSON) -> Data {
        Data(HealthIngestCanonicalJSON.string(payload).utf8)
    }

    /// Gzip when it actually shrinks the body. Callers send the original bytes when this returns nil.
    static func gzipIfWorthwhile(_ data: Data) -> Data? {
        guard data.count >= gzipThreshold, let compressed = HealthIngestGzip.compress(data), compressed.count < data.count else {
            return nil
        }
        return compressed
    }

    static func parseAcks(_ data: Data) throws -> [HealthIngestAck] {
        guard !data.isEmpty else { throw HealthIngestWireError.unrecognizedResponse }
        let json = try JSONSerialization.jsonObject(with: data)
        guard let object = json as? [String: Any], let rows = object["results"] as? [Any] else {
            throw HealthIngestWireError.unrecognizedResponse
        }
        let acks = rows.compactMap(HealthIngestAck.init(json:))
        guard acks.count == rows.count else { throw HealthIngestWireError.unrecognizedResponse }
        return acks
    }

    static func payloadHash(_ payload: HealthIngestJSON) -> String {
        HealthIngestCanonicalJSON.digest(payload)
    }

    static func payloadByteCount(_ payload: HealthIngestJSON) -> Int {
        encodePayload(payload).count
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(HealthIngestTime.string(from: date))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = HealthIngestTime.date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO8601 timestamp"
                )
            }
            return date
        }
        return decoder
    }

    static func jsonValue(_ value: some Encodable) -> HealthIngestJSON {
        guard let data = try? makeEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return .object([:]) }
        return HealthIngestJSON(jsonObject: object)
    }

    static func contentID(for payload: HealthIngestJSON) -> String {
        HealthIngestCanonicalJSON.digest(payload)
    }
}

enum HealthIngestWireError: Error, Equatable {
    case unrecognizedResponse
    case invalidOrigin
}

enum HealthIngestType {
    static let glucose = "glucose"
    static let bolus = "bolus"
    static let bolusDecision = "bolus_decision"
    static let bolusFailure = "bolus_failure"
    static let tempBasal = "temp_basal"
    static let carbs = "carbs"
    static let override = "override"
    static let tempTarget = "temp_target"
    static let profileSnapshot = "profile_snapshot"
    static let settingsSnapshot = "settings_snapshot"
    static let smb = "smb"
    static let loopCycle = "loop_cycle"
    static let pumpEvent = "pump_event"
    static let workout = "workout"
    static let heartRate = "heart_rate"
    static let restingHR = "resting_hr"
    static let hrv = "hrv"
    static let sleepStage = "sleep_stage"
    static let activeEnergy = "active_energy"
    static let exerciseMinutes = "exercise_minutes"
    static let deletion = "deletion"
    static let cgmEvent = "cgm_event"
    static let profileSwitch = "profile_switch"
    static let effectiveProfile = "effective_profile"
    static let loopStat = "loop_stat"
    static let tzChange = "tz_change"

    static let contentAddressed: Set<String> = [profileSnapshot, settingsSnapshot, effectiveProfile]

    /// Samples read from HealthKit. Trio glucose is not in this set: the uploader
    /// does not read HealthKit glucose, and Trio's own glucose records do not
    /// carry HealthKit source fields.
    static let healthKitTypes: Set<String> = [
        workout, heartRate, restingHR, hrv, sleepStage, activeEnergy, exerciseMinutes
    ]

    /// Trio's own records. They upload ahead of a HealthKit backfill.
    static func isPriorityLane(_ type: String) -> Bool {
        !healthKitTypes.contains(type)
    }

    /// Types a mapping bump should drop and send again. The server dedupes.
    static let contractResendTypes: Set<String> = healthKitTypes.union([loopCycle, effectiveProfile])

    static func displayName(_ type: String) -> String {
        switch type {
        case glucose: return "Glucose"
        case bolus: return "Bolus"
        case bolusDecision: return "Bolus decision"
        case bolusFailure: return "Bolus failure"
        case tempBasal: return "Temp basal"
        case carbs: return "Carbs"
        case override: return "Override"
        case tempTarget: return "Temp target"
        case profileSnapshot: return "Profile snapshot"
        case settingsSnapshot: return "Settings snapshot"
        case smb: return "SMB"
        case loopCycle: return "Loop cycle"
        case pumpEvent: return "Pump event"
        case workout: return "Workout"
        case heartRate: return "Heart rate"
        case restingHR: return "Resting heart rate"
        case hrv: return "HRV"
        case sleepStage: return "Sleep"
        case activeEnergy: return "Active energy"
        case exerciseMinutes: return "Exercise minutes"
        case deletion: return "Deletion"
        case cgmEvent: return "CGM event"
        case profileSwitch: return "Profile switch"
        case effectiveProfile: return "Effective profile"
        case loopStat: return "Loop stat"
        case tzChange: return "Time zone change"
        default:
            return type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static let all: Set<String> = [
        activeEnergy,
        bolus,
        bolusDecision,
        bolusFailure,
        carbs,
        cgmEvent,
        deletion,
        effectiveProfile,
        exerciseMinutes,
        glucose,
        heartRate,
        hrv,
        loopCycle,
        loopStat,
        override,
        profileSnapshot,
        profileSwitch,
        pumpEvent,
        restingHR,
        settingsSnapshot,
        sleepStage,
        smb,
        tempBasal,
        tempTarget,
        tzChange,
        workout
    ]
}

enum HealthIngestTime {
    private static let lock = NSLock()
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static var zoneIdentifier: String { TimeZone.current.identifier }

    static func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return fractional.string(from: date)
    }

    static func date(from string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return fractional.date(from: string) ?? plain.date(from: string)
    }
}

enum HealthIngestIdentity {
    /// Upsert key is `(type, id)`. The same id is reused when the payload changes and on retry.
    static func glucose(source: String, start: Date) -> String {
        "cgm:\(source.replacingOccurrences(of: ":", with: "-")):\(HealthIngestTime.string(from: start))"
    }

    static func loop(start: Date) -> String {
        "loop:\(HealthIngestTime.string(from: start))"
    }

    static func hex(_ digest: SHA256.Digest, bytes: Int) -> String {
        digest.prefix(bytes).map { String(format: "%02x", $0) }.joined()
    }
}

enum HealthIngestPayload {
    /// JSON cannot represent NaN or infinity. Every other stored value is sent as-is.
    static func finiteNumber(_ value: Double) -> HealthIngestJSON? {
        guard value.isFinite else { return nil }
        return .number(value)
    }

    static func diaHours(_ hours: Double) -> HealthIngestJSON? {
        finiteNumber(hours)
    }

    /// Trio stores an override as a percent; the wire field is a multiplier.
    static func unitMultiplier(percentage: Double?) -> HealthIngestJSON? {
        guard let percentage, percentage.isFinite else { return nil }
        return .number(percentage / 100)
    }

    static func predictedBG(_ value: Double) -> HealthIngestJSON? {
        finiteNumber(value)
    }

    static func predictedBG(_ value: Decimal?) -> HealthIngestJSON? {
        guard let value else { return nil }
        return predictedBG(NSDecimalNumber(decimal: value).doubleValue)
    }

    static func predictedBG(_ value: NSDecimalNumber?) -> HealthIngestJSON? {
        guard let value else { return nil }
        return predictedBG(value.doubleValue)
    }
}

struct HealthIngestDevice: Codable, Equatable {
    var id: String
    var app: String
    var appVersion: String
}

struct HealthIngestEnvelope: Encodable, Equatable {
    var schemaVersion: Int
    var device: HealthIngestDevice
    var records: [HealthIngestRecord]

    func asJSON() -> HealthIngestJSON {
        .object([
            "schemaVersion": .number(Double(schemaVersion)),
            "device": .object([
                "id": .string(device.id),
                "app": .string(device.app),
                "appVersion": .string(device.appVersion)
            ]),
            "records": .array(records.map { $0.asJSON() })
        ])
    }
}

struct HealthIngestRecord: Codable, Equatable {
    var type: String
    var id: String
    var start: Date
    var end: Date?
    var tz: String
    var payload: HealthIngestJSON
    /// HealthKit `HKSource.name`. Omitted for Trio's own records.
    var sourceName: String? = nil
    /// HealthKit `HKSource.bundleIdentifier`.
    var sourceBundleIdentifier: String? = nil
    /// HealthKit `HKDevice.name`. Nil when the sample has no device.
    var deviceName: String? = nil
    /// HealthKit `HKDevice.model`.
    var deviceModel: String? = nil
    /// HealthKit `HKDevice.manufacturer`.
    var deviceManufacturer: String? = nil

    func asJSON() -> HealthIngestJSON {
        var fields: [String: HealthIngestJSON?] = [
            "type": .string(type),
            "id": .string(id),
            "start": .string(HealthIngestTime.string(from: start)),
            "end": end.map { .string(HealthIngestTime.string(from: $0)) },
            "tz": .string(tz),
            "payload": payload
        ]
        for (key, value) in provenanceWireFields() {
            fields[key] = .string(value)
        }
        return .object(fields)
    }

    /// Local dedup text. Equals the payload JSON unless a HealthKit source field
    /// is present, so an accepted receipt does not block the same id after mapping 6.
    func receiptCanonical(payloadCanonical: String) -> String {
        let extras = provenanceWireFields()
        guard !extras.isEmpty else { return payloadCanonical }
        var fields: [String: HealthIngestJSON?] = [:]
        for (key, value) in extras {
            fields[key] = .string(value)
        }
        return payloadCanonical + "\n" + HealthIngestCanonicalJSON.string(.object(fields))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(id, forKey: .id)
        try container.encode(start, forKey: .start)
        try container.encodeIfPresent(end, forKey: .end)
        try container.encode(tz, forKey: .tz)
        try container.encode(payload, forKey: .payload)
        let provenance = provenanceWireFields()
        try container.encodeIfPresent(provenance["sourceName"], forKey: .sourceName)
        try container.encodeIfPresent(provenance["sourceBundleIdentifier"], forKey: .sourceBundleIdentifier)
        try container.encodeIfPresent(provenance["deviceName"], forKey: .deviceName)
        try container.encodeIfPresent(provenance["deviceModel"], forKey: .deviceModel)
        try container.encodeIfPresent(provenance["deviceManufacturer"], forKey: .deviceManufacturer)
    }

    func provenanceWireUTF8Count() -> Int {
        provenanceWireFields().values.reduce(0) { $0 + $1.utf8.count }
    }

    private func provenanceWireFields() -> [String: String] {
        HealthIngestProvenance.wireFields(
            sourceName: sourceName,
            sourceBundleIdentifier: sourceBundleIdentifier,
            deviceName: deviceName,
            deviceModel: deviceModel,
            deviceManufacturer: deviceManufacturer
        )
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case start
        case end
        case tz
        case payload
        case sourceName
        case sourceBundleIdentifier
        case deviceName
        case deviceModel
        case deviceManufacturer
    }
}

/// HealthKit source and device strings the server will store beside `payload`.
enum HealthIngestProvenance {
    /// Keeps a string the server accepts. Empty, longer than 256 UTF-16 code units,
    /// or containing a Unicode control character is dropped whole. Nothing is trimmed
    /// or shortened to pass that check.
    static func accepted(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let length = raw.utf16.count
        guard length >= 1, length <= 256 else { return nil }
        guard raw.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .control }) else { return nil }
        return raw
    }

    static func wireFields(
        sourceName: String?,
        sourceBundleIdentifier: String?,
        deviceName: String?,
        deviceModel: String?,
        deviceManufacturer: String?
    ) -> [String: String] {
        var fields: [String: String] = [:]
        if let value = accepted(sourceName) { fields["sourceName"] = value }
        if let value = accepted(sourceBundleIdentifier) { fields["sourceBundleIdentifier"] = value }
        if let value = accepted(deviceName) { fields["deviceName"] = value }
        if let value = accepted(deviceModel) { fields["deviceModel"] = value }
        if let value = accepted(deviceManufacturer) { fields["deviceManufacturer"] = value }
        return fields
    }
}

struct HealthIngestAck: Equatable {
    enum Status: String {
        case accepted
        case duplicate
        case rejected
    }

    var type: String
    var id: String
    var status: Status
    var reason: String?
    /// Longer explanation when the server sends one beside `reason`.
    var message: String?

    init(type: String, id: String, status: Status, reason: String? = nil, message: String? = nil) {
        self.type = type
        self.id = id
        self.status = status
        self.reason = reason
        self.message = message
    }

    /// Rows the server accepted in this response. Duplicates and rejects are not counted.
    static func acceptedRowCount(_ acks: [HealthIngestAck]) -> Int {
        acks.reduce(0) { count, ack in
            count + (ack.status == .accepted ? 1 : 0)
        }
    }

    init?(json: Any) {
        guard let row = json as? [String: Any],
              let type = row["type"] as? String,
              let id = row["id"] as? String,
              let raw = (row["status"] as? String)?.lowercased(),
              let status = Status(rawValue: raw)
        else { return nil }
        self.type = type
        self.id = id
        self.status = status
        reason = row["reason"] as? String
        message = row["message"] as? String
    }
}

enum HealthIngestJSON: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: HealthIngestJSON])
    case array([HealthIngestJSON])
    case null

    static func object(_ fields: [String: HealthIngestJSON?]) -> HealthIngestJSON {
        .object(fields.compactMapValues { $0 })
    }

    static func decimal(_ value: Decimal?) -> HealthIngestJSON? {
        guard let value else { return nil }
        return HealthIngestPayload.finiteNumber(NSDecimalNumber(decimal: value).doubleValue)
    }

    static func decimal(_ value: NSDecimalNumber?) -> HealthIngestJSON? {
        guard let value else { return nil }
        return HealthIngestPayload.finiteNumber(value.doubleValue)
    }

    init(jsonObject: Any) {
        if jsonObject is NSNull {
            self = .null
        } else if let value = jsonObject as? String {
            self = .string(value)
        } else if let value = jsonObject as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
        } else if let value = jsonObject as? [String: Any] {
            self = .object(value.mapValues { HealthIngestJSON(jsonObject: $0) })
        } else if let value = jsonObject as? [Any] {
            self = .array(value.map { HealthIngestJSON(jsonObject: $0) })
        } else {
            self = .null
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode([String: HealthIngestJSON].self) {
            self = .object(value)
        } else if let value = try? container.decode([HealthIngestJSON].self) {
            self = .array(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .string(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .number(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .bool(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .object(value):
            // Encode through a keyed container. Encoding `[String: HealthIngestJSON]`
            // as a single-value Dictionary can drop keys on some JSONEncoder paths.
            var container = encoder.container(keyedBy: JSONKey.self)
            for (key, nested) in value {
                try container.encode(nested, forKey: JSONKey(key))
            }
        case let .array(value):
            var container = encoder.unkeyedContainer()
            for item in value {
                try container.encode(item)
            }
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
}

private struct JSONKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ string: String) {
        stringValue = string
        intValue = nil
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

enum HealthIngestGzip {
    static func compress(_ input: Data) -> Data? {
        transform(input, initStream: { stream in
            deflateInit2_(
                stream,
                Z_DEFAULT_COMPRESSION,
                Z_DEFLATED,
                MAX_WBITS + 16,
                8,
                Z_DEFAULT_STRATEGY,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            )
        }, process: { stream in
            deflate(stream, Z_FINISH)
        }, finish: { stream in
            deflateEnd(stream)
        }, bound: Int(compressBound(uLong(input.count))) + 32)
    }

    static func decompress(_ input: Data) -> Data? {
        guard !input.isEmpty else { return Data() }
        var stream = z_stream()
        guard inflateInit2_(
            &stream,
            MAX_WBITS + 16,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else { return nil }
        defer { _ = inflateEnd(&stream) }

        let inputCount = input.count
        let chunkSize = 16 * 1024
        var output = Data()
        let finished = input.withUnsafeBytes { raw -> Bool in
            guard let source = raw.bindMemory(to: Bytef.self).baseAddress else { return false }
            stream.next_in = UnsafeMutablePointer(mutating: source)
            stream.avail_in = uInt(inputCount)
            while true {
                var chunk = Data(count: chunkSize)
                let status: Int32 = chunk.withUnsafeMutableBytes { out in
                    guard let destination = out.bindMemory(to: Bytef.self).baseAddress else { return Z_BUF_ERROR }
                    stream.next_out = destination
                    stream.avail_out = uInt(chunkSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    chunk.removeSubrange(produced ..< chunk.count)
                    output.append(chunk)
                }
                if status == Z_STREAM_END { return true }
                if status != Z_OK { return false }
            }
        }
        return finished ? output : nil
    }

    private static func transform(
        _ input: Data,
        initStream: (UnsafeMutablePointer<z_stream>) -> Int32,
        process: (UnsafeMutablePointer<z_stream>) -> Int32,
        finish: (UnsafeMutablePointer<z_stream>) -> Int32,
        bound: Int
    ) -> Data? {
        guard !input.isEmpty else { return Data() }
        var stream = z_stream()
        guard initStream(&stream) == Z_OK else { return nil }
        defer { _ = finish(&stream) }

        var output = Data(count: max(bound, 64))
        let inputCount = input.count
        let outputCount = output.count
        let result: Int32 = input.withUnsafeBytes { raw in
            guard let source = raw.bindMemory(to: Bytef.self).baseAddress else { return Z_BUF_ERROR }
            return output.withUnsafeMutableBytes { out in
                guard let destination = out.bindMemory(to: Bytef.self).baseAddress else { return Z_BUF_ERROR }
                stream.next_in = UnsafeMutablePointer(mutating: source)
                stream.avail_in = uInt(inputCount)
                stream.next_out = destination
                stream.avail_out = uInt(outputCount)
                return process(&stream)
            }
        }
        guard result == Z_STREAM_END else { return nil }
        let produced = Int(stream.total_out)
        guard produced <= output.count else { return nil }
        output.removeSubrange(produced ..< output.count)
        return output
    }
}

enum HealthIngestOrigin {
    /// `https` origin only. Userinfo is rejected so a token cannot hide in the URL.
    static func parse(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil
        else { return nil }

        var origin = URLComponents()
        origin.scheme = "https"
        origin.host = host
        origin.port = components.port
        var path = components.path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        origin.path = path == "/" ? "" : path
        return origin.url
    }
}

enum HealthIngestAppVersion {
    static func current() -> String {
        let release = Bundle.main.releaseVersionNumber ?? "0"
        let build = Bundle.main.buildVersionNumber ?? "0"
        if let dev = Bundle.main.appDevVersion, !dev.isEmpty, !dev.contains("$"), dev != release {
            return "\(release) (\(build)) \(dev)"
        }
        return "\(release) (\(build))"
    }
}
