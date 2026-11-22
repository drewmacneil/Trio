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

    /// Bump when on-device payloads change so rejected receipts and HealthKit
    /// backfill cursors can be cleared and the records sent again.
    /// 4 resends Core Data loop cycles and effective profiles the server used to reject
    /// (finite predicted glucose, and schedule starts in HH:MM or HH:MM:SS).
    static let mappingVersion = 4

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
    static let profileSwitch = "profile_switch"
    static let effectiveProfile = "effective_profile"
    static let loopStat = "loop_stat"
    static let tzChange = "tz_change"

    static let contentAddressed: Set<String> = [profileSnapshot, settingsSnapshot, effectiveProfile]

    static let healthKitTypes: Set<String> = [
        workout, heartRate, restingHR, hrv, sleepStage, activeEnergy, exerciseMinutes
    ]

    /// Types a mapping bump should drop and send again. The server dedupes.
    static let contractResendTypes: Set<String> = healthKitTypes.union([loopCycle, effectiveProfile])

    static func displayName(_ type: String) -> String {
        switch type {
        case glucose: return "Glucose"
        case bolus: return "Bolus"
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
        carbs,
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

    func asJSON() -> HealthIngestJSON {
        .object([
            "type": .string(type),
            "id": .string(id),
            "start": .string(HealthIngestTime.string(from: start)),
            "end": end.map { .string(HealthIngestTime.string(from: $0)) },
            "tz": .string(tz),
            "payload": payload
        ])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(id, forKey: .id)
        try container.encode(start, forKey: .start)
        try container.encodeIfPresent(end, forKey: .end)
        try container.encode(tz, forKey: .tz)
        try container.encode(payload, forKey: .payload)
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case start
        case end
        case tz
        case payload
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
