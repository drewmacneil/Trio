import CryptoKit
import Foundation
import zlib

/// Wire contract for `POST {baseURL}/v1/ingest` and `GET {baseURL}/v1/status`.
///
/// Adjust this file when the private ingest server changes the JSON. The rest of the uploader
/// talks to these types and does not build request bodies itself.
///
/// Assumed response body (any one of these):
/// `{ "records": [ { "id", "status", "reason"? } ] }`,
/// `{ "results": [ { "id", "status", "reason"? } ] }`,
/// or a top-level array of those objects.
/// `status` is `accepted`, `duplicate`, or `rejected`.
enum HealthIngestWire {
    static let schemaVersion = 1
    static let appName = "Trio"
    static let ingestPath = "/v1/ingest"
    static let statusPath = "/v1/status"
    static let gzipThreshold = 1024

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

    static func encodeEnvelope(_ envelope: HealthIngestEnvelope) throws -> Data {
        try makeEncoder().encode(envelope)
    }

    static func encode(_ value: some Encodable) throws -> Data {
        try makeEncoder().encode(value)
    }

    /// Gzip when it actually shrinks the body. Callers send the original bytes when this returns nil.
    static func gzipIfWorthwhile(_ data: Data) -> Data? {
        guard data.count >= gzipThreshold, let compressed = HealthIngestGzip.compress(data), compressed.count < data.count else {
            return nil
        }
        return compressed
    }

    static func parseAcks(_ data: Data) throws -> [HealthIngestAck] {
        guard !data.isEmpty else { return [] }
        let json = try JSONSerialization.jsonObject(with: data)
        let rows = ackRows(in: json)
        guard let rows else { throw HealthIngestWireError.unrecognizedResponse }
        return rows.compactMap(HealthIngestAck.init(json:))
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
        let data = (try? makeEncoder().encode(payload)) ?? Data()
        return HealthIngestIdentity.hex(SHA256.hash(data: data), bytes: 16)
    }

    private static func ackRows(in json: Any) -> [Any]? {
        if let rows = json as? [Any] { return rows }
        guard let object = json as? [String: Any] else { return nil }
        if let rows = object["records"] as? [Any] { return rows }
        if let rows = object["results"] as? [Any] { return rows }
        return nil
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
    static let loopCycle = "loop_cycle"
    static let pumpEvent = "pump_event"
    static let workout = "workout"
    static let heartRate = "heart_rate"
    static let restingHR = "resting_hr"
    static let hrv = "hrv"
    static let sleepStage = "sleep_stage"
    static let activeEnergy = "active_energy"
    static let exerciseMinutes = "exercise_minutes"

    static let all: Set<String> = [
        activeEnergy,
        bolus,
        carbs,
        exerciseMinutes,
        glucose,
        heartRate,
        hrv,
        loopCycle,
        override,
        profileSnapshot,
        pumpEvent,
        restingHR,
        settingsSnapshot,
        sleepStage,
        tempBasal,
        tempTarget,
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
    /// Stable id for a record that can be revised. The same source and canonical text always
    /// produce the same id, so a resend is a duplicate. A changed payload is a new id because
    /// the server treats a duplicate id as success and keeps the first body.
    static func revision(sourceID: String, canonical: String) -> String {
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return "\(sourceID)#\(hex(digest, bytes: 8))"
    }

    static func hex(_ digest: SHA256.Digest, bytes: Int) -> String {
        digest.prefix(bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func canonical(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 8
        formatter.decimalSeparator = "."
        return formatter.string(from: NSDecimalNumber(decimal: value))
            ?? NSDecimalNumber(decimal: value).stringValue
    }

    static func canonical(_ value: NSDecimalNumber?) -> String {
        guard let value else { return "" }
        return canonical(value.decimalValue)
    }

    static func canonical(_ date: Date?) -> String {
        guard let date else { return "" }
        return HealthIngestTime.string(from: date)
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
}

struct HealthIngestRecord: Codable, Equatable {
    var type: String
    var id: String
    var start: Date
    var end: Date?
    var tz: String
    var payload: HealthIngestJSON

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

    var id: String
    var status: Status
    var reason: String?

    init(id: String, status: Status, reason: String? = nil) {
        self.id = id
        self.status = status
        self.reason = reason
    }

    init?(json: Any) {
        guard let row = json as? [String: Any],
              let id = row["id"] as? String,
              let raw = (row["status"] as? String)?.lowercased(),
              let status = Status(rawValue: raw)
        else { return nil }
        self.id = id
        self.status = status
        reason = (row["reason"] as? String) ?? (row["error"] as? String)
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
        return .number(NSDecimalNumber(decimal: value).doubleValue)
    }

    static func decimal(_ value: NSDecimalNumber?) -> HealthIngestJSON? {
        guard let value else { return nil }
        return .number(value.doubleValue)
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
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
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
        transform(input, initStream: { stream in
            inflateInit2_(
                stream,
                MAX_WBITS + 16,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            )
        }, process: { stream in
            inflate(stream, Z_FINISH)
        }, finish: { stream in
            inflateEnd(stream)
        }, bound: max(input.count * 4, 64))
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
        defer { finish(&stream) }

        var output = Data(count: max(bound, 64))
        let result: Int32 = input.withUnsafeBytes { raw in
            guard let source = raw.bindMemory(to: Bytef.self).baseAddress else { return Z_BUF_ERROR }
            return output.withUnsafeMutableBytes { out in
                guard let destination = out.bindMemory(to: Bytef.self).baseAddress else { return Z_BUF_ERROR }
                stream.next_in = UnsafeMutablePointer(mutating: source)
                stream.avail_in = uInt(input.count)
                stream.next_out = destination
                stream.avail_out = uInt(output.count)
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
