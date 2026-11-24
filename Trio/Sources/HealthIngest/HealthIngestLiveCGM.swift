import Foundation
import G7SensorKit

/// What the upload pass can see on a live G7 without reading a secret.
/// Pairing codes, shared keys, and Share account fields are not here.
struct HealthIngestCGMSnapshot: Equatable {
    var sensor: String?
    var activatedAt: Date?
    var readingAt: Date?
    var trendRateMgdlPerMin: Double?
    var algorithmState: String?
    var glucoseIsReliable: Bool
    var suspectedSessionEndAt: Date?
    var calibration: Calibration?
    var previous: EndedSensor?

    struct Calibration: Equatable {
        var meterMgdl: Double
        var enteredAt: Date
        var outcome: String
    }

    struct EndedSensor: Equatable {
        var sensor: String
        var activatedAt: Date?
        var endedAt: Date
        var endReason: String
        var failureMessage: String?
    }
}

/// Logging-only view of the G7 manager. Glucose math and dosing are untouched.
enum HealthIngestLiveCGM {
    struct Annotation: Equatable {
        var trendRate: Double?
        var sensor: String?
    }

    private struct Store: Codable {
        var rates: [Rate] = []
        var windows: [Window] = []
        var emitted: [String] = []
        var lastAlgorithm: String?
        var lastAlgorithmSensor: String?
        var sawWarmup: Bool = false
        var sawWarmupSensor: String?
        var signalLossAt: Date?
        var calibrationKey: String?

        struct Rate: Codable {
            var at: Date
            var rate: Double
        }

        struct Window: Codable {
            var sensor: String
            var start: Date
            var end: Date?
        }
    }

    private static let lock = NSLock()
    private static var cached: Store?
    private static var cachedDirectory: URL?
    private static let fileName = "cgm-live.json"
    /// A glucose row and a G7 timestamp are the same instant, plus a little clock noise.
    private static let rateMatchSeconds: TimeInterval = 2

    static func snapshot(from manager: G7CGMManager) -> HealthIngestCGMSnapshot {
        // Copy the fields the log is allowed to keep. Do not pass `state` onward:
        // the manager state also holds the pairing code, the link key, and Share.
        let state = manager.state
        let reading = state.latestReading
        let ended = state.previousSensor
        return HealthIngestCGMSnapshot(
            sensor: acceptedSensor(state.sensorID),
            activatedAt: state.activatedAt,
            readingAt: state.latestReadingTimestamp,
            trendRateMgdlPerMin: reading?.trend,
            algorithmState: reading.map { $0.algorithmState.description },
            glucoseIsReliable: reading?.hasReliableGlucose == true,
            suspectedSessionEndAt: state.suspectedSessionEndAt,
            calibration: state.calibration.map { record in
                HealthIngestCGMSnapshot.Calibration(
                    meterMgdl: Double(record.glucose),
                    enteredAt: record.enteredAt,
                    outcome: outcomeName(record.outcome)
                )
            },
            previous: ended.flatMap { record in
                guard let sensor = acceptedSensor(record.sensorID) else { return nil }
                return HealthIngestCGMSnapshot.EndedSensor(
                    sensor: sensor,
                    activatedAt: record.activatedAt,
                    endedAt: record.endedAt,
                    endReason: endReason(recorded: record.endReason.rawValue, failureMessage: record.failureMessage),
                    failureMessage: record.failureMessage
                )
            }
        )
    }

    /// Records the snapshot and returns CGM events that have not been returned yet.
    static func observe(_ snapshot: HealthIngestCGMSnapshot) -> [HealthIngestRecord] {
        lock.lock()
        defer { lock.unlock() }
        var store = loadLocked()
        let events = apply(snapshot, to: &store)
        saveLocked(store)
        return events
    }

    static func annotation(at date: Date) -> Annotation? {
        lock.lock()
        defer { lock.unlock() }
        let store = loadLocked()
        let rate = store.rates.min { lhs, rhs in
            abs(lhs.at.timeIntervalSince(date)) < abs(rhs.at.timeIntervalSince(date))
        }.flatMap { sample -> Double? in
            abs(sample.at.timeIntervalSince(date)) <= rateMatchSeconds ? sample.rate : nil
        }
        let sensor = store.windows
            .filter { window in
                date >= window.start && (window.end.map { date < $0 } ?? true)
            }
            .max { $0.start < $1.start }?
            .sensor
        if rate == nil, sensor == nil { return nil }
        return Annotation(trendRate: rate, sensor: sensor)
    }

    static func currentSensor() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked().windows
            .filter { $0.end == nil }
            .max { $0.start < $1.start }?
            .sensor
    }

    static func alreadyRecorded(kind: String, at: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked().emitted.contains(eventID(kind: kind, at: at))
    }

    static func discardCachedStore() {
        lock.lock()
        cached = nil
        cachedDirectory = nil
        lock.unlock()
    }

    static func acceptedText(_ raw: String?, max: Int) -> String? {
        guard let raw else { return nil }
        let length = raw.utf16.count
        guard length >= 1, length <= max else { return nil }
        guard raw.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .control }) else { return nil }
        return raw
    }

    /// The advertised sensor name. A 4-digit string is a pairing code and is dropped.
    static func acceptedSensor(_ raw: String?) -> String? {
        guard let text = acceptedText(raw, max: 64) else { return nil }
        if text.count == 4, text.allSatisfy(\.isNumber) { return nil }
        return text
    }

    static func acceptedEndReason(_ raw: String?) -> String? {
        switch raw {
        case "replaced", "expired", "failed", "deleted":
            return raw
        default:
            return nil
        }
    }

    static func acceptedOutcome(_ raw: String?) -> String? {
        switch raw {
        case "pending", "accepted", "rejected", "expired":
            return raw
        default:
            return nil
        }
    }

    static func endReason(recorded: String, failureMessage: String?) -> String {
        let text = (failureMessage ?? "").lowercased()
        if text.contains("fail") { return "failed" }
        if text.contains("expir") || text.contains("sessionended") { return "expired" }
        switch recorded {
        case "deleted": return "deleted"
        case "expired": return "expired"
        case "failed": return "failed"
        default: return "replaced"
        }
    }

    private static func apply(_ snapshot: HealthIngestCGMSnapshot, to store: inout Store) -> [HealthIngestRecord] {
        if let at = snapshot.readingAt, let rate = snapshot.trendRateMgdlPerMin, rate.isFinite, rate >= -30, rate <= 30 {
            store.rates.removeAll { abs($0.at.timeIntervalSince(at)) <= rateMatchSeconds }
            store.rates.append(Store.Rate(at: at, rate: rate))
            if store.rates.count > 3_000 {
                store.rates.removeFirst(store.rates.count - 3_000)
            }
        }

        if let sensor = snapshot.sensor, let start = snapshot.activatedAt {
            upsert(sensor: sensor, start: start, end: nil, in: &store)
        }
        if let previous = snapshot.previous {
            let start = previous.activatedAt ?? previous.endedAt
            upsert(sensor: previous.sensor, start: start, end: previous.endedAt, in: &store)
        }

        var events: [HealthIngestRecord] = []
        if let sensor = snapshot.sensor, let activatedAt = snapshot.activatedAt {
            events.append(contentsOf: once(
                store: &store,
                record: HealthIngestTherapy.cgmRecord(
                    at: activatedAt,
                    kind: "sensor_start",
                    message: nil,
                    sensor: sensor,
                    activatedAt: activatedAt
                )
            ))
        }

        if let previous = snapshot.previous {
            let kind = endKind(previous.endReason)
            events.append(contentsOf: once(
                store: &store,
                record: HealthIngestTherapy.cgmRecord(
                    at: previous.endedAt,
                    kind: kind,
                    message: previous.failureMessage,
                    sensor: previous.sensor,
                    activatedAt: previous.activatedAt,
                    endReason: previous.endReason
                )
            ))
        }

        if let state = snapshot.algorithmState, !snapshot.glucoseIsReliable {
            let sensor = snapshot.sensor
            if state != store.lastAlgorithm || sensor != store.lastAlgorithmSensor {
                store.lastAlgorithm = state
                store.lastAlgorithmSensor = sensor
                let kind = HealthIngestCGM.issueKind(code: state, fatal: false)
                if kind == "warmup_start" {
                    store.sawWarmup = true
                    store.sawWarmupSensor = sensor
                }
                let at = snapshot.readingAt ?? Date()
                events.append(contentsOf: once(
                    store: &store,
                    record: HealthIngestTherapy.cgmRecord(
                        at: at,
                        kind: kind,
                        message: state,
                        sensor: sensor,
                        algorithmState: state
                    )
                ))
            }
        } else if snapshot.glucoseIsReliable {
            let sameSensor = store.sawWarmupSensor == nil || store.sawWarmupSensor == snapshot.sensor
            if store.sawWarmup, sameSensor {
                let at = snapshot.readingAt ?? Date()
                events.append(contentsOf: once(
                    store: &store,
                    record: HealthIngestTherapy.cgmRecord(
                        at: at,
                        kind: "warmup_end",
                        message: nil,
                        sensor: snapshot.sensor
                    )
                ))
                store.sawWarmup = false
            }
            store.lastAlgorithm = snapshot.algorithmState
            store.lastAlgorithmSensor = snapshot.sensor
        }

        if let suspected = snapshot.suspectedSessionEndAt, store.signalLossAt != suspected {
            store.signalLossAt = suspected
            events.append(contentsOf: once(
                store: &store,
                record: HealthIngestTherapy.cgmRecord(
                    at: suspected,
                    kind: "signal_loss",
                    message: nil,
                    sensor: snapshot.sensor
                )
            ))
        }

        if let calibration = snapshot.calibration {
            let key = "\(calibration.enteredAt.timeIntervalSince1970)-\(calibration.outcome)"
            if key != store.calibrationKey {
                store.calibrationKey = key
                let record = HealthIngestTherapy.cgmRecord(
                    at: calibration.enteredAt,
                    kind: "calibration",
                    message: nil,
                    sensor: snapshot.sensor,
                    meterMgdl: calibration.meterMgdl,
                    outcome: calibration.outcome
                )
                // Outcome changes keep the same id and must be sent again.
                store.emitted.removeAll { $0 == record.id }
                events.append(contentsOf: once(store: &store, record: record))
            }
        }

        return events
    }

    private static func endKind(_ endReason: String) -> String {
        switch endReason {
        case "failed": return "sensor_failed"
        case "expired": return "sensor_expired"
        case "replaced": return "sensor_replaced"
        default: return "sensor_end"
        }
    }

    private static func upsert(sensor: String, start: Date, end: Date?, in store: inout Store) {
        if let index = store.windows.firstIndex(where: {
            $0.sensor == sensor && abs($0.start.timeIntervalSince(start)) < 1
        }) {
            if let end { store.windows[index].end = end }
            return
        }
        store.windows.append(Store.Window(sensor: sensor, start: start, end: end))
        if store.windows.count > 24 {
            store.windows.removeFirst(store.windows.count - 24)
        }
    }

    private static func once(store: inout Store, record: HealthIngestRecord) -> [HealthIngestRecord] {
        guard !store.emitted.contains(record.id) else { return [] }
        store.emitted.append(record.id)
        if store.emitted.count > 500 {
            store.emitted.removeFirst(store.emitted.count - 500)
        }
        return [record]
    }

    private static func eventID(kind: String, at: Date) -> String {
        "cgm-event:\(kind):\(HealthIngestTime.string(from: at))"
    }

    private static func outcomeName(_ outcome: G7CalibrationRecord.Outcome) -> String {
        switch outcome {
        case .pending: return "pending"
        case .accepted: return "accepted"
        case .rejected: return "rejected"
        case .expired: return "expired"
        }
    }

    private static func loadLocked() -> Store {
        let directory = HealthIngestTherapy.ingestDirectory(create: false)
        if cached != nil, cachedDirectory == directory { return cached ?? Store() }
        let loaded = read(directory) ?? Store()
        cached = loaded
        cachedDirectory = directory
        return loaded
    }

    private static func saveLocked(_ store: Store) {
        let directory = HealthIngestTherapy.ingestDirectory(create: true)
        cached = store
        cachedDirectory = directory
        guard let folder = directory else { return }
        let url = folder.appendingPathComponent(fileName)
        guard let data = try? HealthIngestWire.makeEncoder().encode(store) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func read(_ directory: URL?) -> Store? {
        guard let folder = directory else { return nil }
        let url = folder.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? HealthIngestWire.makeDecoder().decode(Store.self, from: data)
    }
}
