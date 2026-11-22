import CryptoKit
import Foundation

/// Canonical JSON for content-addressed ids. Matches JavaScript `JSON.stringify`
/// with object keys sorted at every level: UTF-8, no insignificant whitespace.
enum HealthIngestCanonicalJSON {
    static func string(_ value: HealthIngestJSON) -> String {
        switch value {
        case let .string(text):
            return literal(text)
        case let .number(number):
            return numberLiteral(number)
        case let .bool(flag):
            return flag ? "true" : "false"
        case .null:
            return "null"
        case let .array(items):
            return "[" + items.map(string).joined(separator: ",") + "]"
        case let .object(fields):
            let body = fields.keys.sorted().map { key in
                literal(key) + ":" + string(fields[key] ?? .null)
            }
            return "{" + body.joined(separator: ",") + "}"
        }
    }

    /// First 32 lowercase hex characters of SHA-256 over the canonical payload JSON.
    /// Matches the server's `contentHash` / `stableJson`.
    static func digest(_ payload: HealthIngestJSON) -> String {
        let hashed = SHA256.hash(data: Data(string(payload).utf8))
        return HealthIngestIdentity.hex(hashed, bytes: 16)
    }

    /// `<prefix>:` plus the first 32 lowercase hex characters of SHA-256 over the payload only.
    static func contentID(prefix: String, payload: HealthIngestJSON) -> String {
        "\(prefix):\(digest(payload))"
    }

    static func clock(seconds: Int) -> String {
        let bounded = min(max(seconds, 0), (23 * 60 + 59) * 60)
        return String(format: "%02d:%02d", bounded / 3600, (bounded % 3600) / 60)
    }

    /// `HH:MM` from a stored clock string (`HH:MM` or `HH:MM:SS`) or from seconds.
    static func clock(start: String, seconds: Int) -> String {
        let parts = start.split(separator: ":")
        if parts.count >= 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
           (0 ... 23).contains(hour), (0 ... 59).contains(minute)
        {
            return String(format: "%02d:%02d", hour, minute)
        }
        return clock(seconds: seconds)
    }

    /// Stored override SMB window values are hours (22 means 22:00).
    static func clock(hour value: Decimal) -> String? {
        let number = NSDecimalNumber(decimal: value).doubleValue
        guard number.isFinite, number >= 0, number < 24 else { return nil }
        let hour = Int(number)
        let minute = Int(((number - Double(hour)) * 60).rounded())
        guard (0 ... 59).contains(minute) else { return nil }
        return String(format: "%02d:%02d", hour, minute)
    }

    static func mgdl(_ value: Double, units: String) -> Double {
        if units == "mmol/L" { return value * 18 }
        return value
    }

    private static func literal(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let encoded = String(data: data, encoding: .utf8),
              encoded.count >= 2
        else { return "\"\"" }
        return String(encoded.dropFirst().dropLast())
    }

    /// Shortest decimal that round-trips, matching `JSON.stringify` for ordinary values.
    private static func numberLiteral(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value == 0 { return "0" }
        let locale = Locale(identifier: "en_US_POSIX")
        if abs(value) < 1e21, value == value.rounded() {
            return String(format: "%.0f", locale: locale, value)
        }
        for precision in 1 ... 17 {
            let text = String(format: "%.\(precision)g", locale: locale, value)
            guard !text.contains("e"), !text.contains("E"), let parsed = Double(text), parsed == value else { continue }
            return text
        }
        return String(value)
    }
}
