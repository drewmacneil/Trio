import Foundation
import HealthKit

enum HealthIngestSleep {
    /// Server stages. Apple's finer values collapse onto this set.
    static func stage(hkValue: Int) -> String {
        switch HKCategoryValueSleepAnalysis(rawValue: hkValue) {
        case .asleep,
             .asleepUnspecified:
            return "asleep"
        case .asleepCore: return "core"
        case .asleepDeep: return "deep"
        case .asleepREM: return "rem"
        case .awake: return "awake"
        case .inBed: return "inBed"
        default: return "asleep"
        }
    }
}

/// Incremental HealthKit reads. Anchors persist on disk. The first sync is one day; older samples
/// come from an explicit backfill, paged so a long history does not run as one radio burst.
final class HealthIngestHealthKitReader {
    static let queryTimeout: TimeInterval = 30

    private let store: HKHealthStore
    private let disk: HealthIngestDisk
    private let lock = NSLock()
    private var observers: [HKObserverQuery] = []
    private var anchors: [String: HKQueryAnchor] = [:]
    private var cursors: [String: Date] = [:]
    private var loaded = false

    init(store: HKHealthStore, disk: HealthIngestDisk) {
        self.store = store
        self.disk = disk
    }

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let types = Set(Self.readTypes().map(\.sampleType) as [HKObjectType])
        guard !types.isEmpty else { return }
        do {
            try await store.requestAuthorization(toShare: [], read: types)
        } catch {
            warning(.healthKit, "Health Ingest HealthKit authorization failed", error: error)
        }
    }

    func startObservers(wake: @escaping () -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        stopObservers()
        for kind in Self.readTypes() {
            let query = HKObserverQuery(sampleType: kind.sampleType, predicate: nil) { _, completion, _ in
                wake()
                completion()
            }
            observers.append(query)
            store.execute(query)
            store.enableBackgroundDelivery(for: kind.sampleType, frequency: .hourly) { _, error in
                if let error {
                    warning(.healthKit, "Health Ingest background delivery failed for \(kind.recordType)", error: error)
                }
            }
        }
    }

    func stopObservers() {
        for query in observers {
            store.stop(query)
        }
        observers.removeAll()
        for kind in Self.readTypes() {
            store.disableBackgroundDelivery(for: kind.sampleType) { _, _ in }
        }
    }

    func beginBackfill(since: Date, preferences: HealthIngestPreferences) {
        loadIfNeeded()
        lock.lock()
        for kind in Self.readTypes() where preferences.isOn(kind.category) {
            if let existing = cursors[kind.recordType] {
                cursors[kind.recordType] = min(existing, since)
            } else {
                cursors[kind.recordType] = since
            }
        }
        lock.unlock()
        persist()
    }

    func resetBackfillCursors() {
        loadIfNeeded()
        lock.lock()
        cursors.removeAll()
        lock.unlock()
        persist()
    }

    func hasPendingBackfill(preferences: HealthIngestPreferences) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return Self.readTypes().contains { preferences.isOn($0.category) && cursors[$0.recordType] != nil }
    }

    func incremental(preferences: HealthIngestPreferences) async -> HealthIngestReadResult {
        guard HKHealthStore.isHealthDataAvailable() else { return HealthIngestReadResult() }
        loadIfNeeded()
        var result = HealthIngestReadResult()
        for kind in Self.readTypes() where preferences.isOn(kind.category) {
            let page = await anchoredPage(kind: kind)
            result.records.append(contentsOf: page.records)
            result.errors.append(contentsOf: page.errors)
        }
        persist()
        return result
    }

    func backfill(preferences: HealthIngestPreferences) async -> HealthIngestReadResult {
        guard HKHealthStore.isHealthDataAvailable() else { return HealthIngestReadResult() }
        loadIfNeeded()
        var result = HealthIngestReadResult()
        for kind in Self.readTypes() where preferences.isOn(kind.category) && cursors[kind.recordType] != nil {
            let page = await backfillPage(kind: kind)
            result.records.append(contentsOf: page.records)
            result.errors.append(contentsOf: page.errors)
        }
        persist()
        return result
    }

    private func anchoredPage(kind: SampleKind) async -> HealthIngestReadResult {
        let existing = anchor(for: kind.recordType)
        let predicate: NSPredicate? = existing == nil
            ? HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-24 * 3600), end: nil, options: .strictStartDate)
            : nil
        do {
            let page = try await anchoredQuery(type: kind.sampleType, predicate: predicate, anchor: existing)
            setAnchor(page.anchor, for: kind.recordType)
            return HealthIngestReadResult(records: page.samples.compactMap { Self.map($0, kind: kind) }, errors: [])
        } catch {
            warning(.healthKit, "Health Ingest \(kind.recordType) query failed", error: error)
            return HealthIngestReadResult(records: [], errors: ["Could not read \(kind.recordType)"])
        }
    }

    /// Reads up to 20 pages, then saves a cursor so the next wake continues. Completed cursors are cleared.
    private func backfillPage(kind: SampleKind) async -> HealthIngestReadResult {
        guard var cursor = cursors[kind.recordType] else { return HealthIngestReadResult() }
        var records: [HealthIngestRecord] = []
        var pages = 0
        while pages < 20 {
            let predicate = HKQuery.predicateForSamples(withStart: cursor, end: nil, options: .strictStartDate)
            do {
                let samples = try await sampleQuery(type: kind.sampleType, predicate: predicate, limit: 400)
                if samples.isEmpty {
                    cursors[kind.recordType] = nil
                    break
                }
                records.append(contentsOf: samples.compactMap { Self.map($0, kind: kind) })
                guard let last = samples.last else { break }
                if last.startDate > cursor {
                    cursor = last.startDate
                } else {
                    cursor = last.startDate.addingTimeInterval(1)
                }
                cursors[kind.recordType] = cursor
                pages += 1
                if samples.count < 400 {
                    cursors[kind.recordType] = nil
                    break
                }
            } catch {
                warning(.healthKit, "Health Ingest \(kind.recordType) backfill failed", error: error)
                return HealthIngestReadResult(records: records, errors: ["Could not backfill \(kind.recordType)"])
            }
        }
        return HealthIngestReadResult(records: records, errors: [])
    }

    private func anchoredQuery(
        type: HKSampleType,
        predicate: NSPredicate?,
        anchor: HKQueryAnchor?
    ) async throws -> (samples: [HKSample], anchor: HKQueryAnchor?) {
        let gate = HealthKitQueryGate<(samples: [HKSample], anchor: HKQueryAnchor?)>(store: store)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.setContinuation(continuation)
                let query = HKAnchoredObjectQuery(
                    type: type,
                    predicate: predicate,
                    anchor: anchor,
                    limit: HKObjectQueryNoLimit
                ) { _, samples, _, newAnchor, error in
                    if let error {
                        gate.finish(.failure(error))
                    } else {
                        gate.finish(.success((samples ?? [], newAnchor)))
                    }
                }
                gate.attach(query)
                gate.startTimeout(seconds: Self.queryTimeout)
            }
        } onCancel: {
            gate.cancel()
        }
    }

    private func sampleQuery(type: HKSampleType, predicate: NSPredicate, limit: Int) async throws -> [HKSample] {
        let gate = HealthKitQueryGate<[HKSample]>(store: store)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.setContinuation(continuation)
                let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
                let query = HKSampleQuery(
                    sampleType: type,
                    predicate: predicate,
                    limit: limit,
                    sortDescriptors: [sort]
                ) { _, samples, error in
                    if let error {
                        gate.finish(.failure(error))
                    } else {
                        gate.finish(.success(samples ?? []))
                    }
                }
                gate.attach(query)
                gate.startTimeout(seconds: Self.queryTimeout)
            }
        } onCancel: {
            gate.cancel()
        }
    }

    private func loadIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !loaded else { return }
        loaded = true
        cursors = disk.loadCursors()
        for (key, data) in disk.loadAnchors() {
            if let anchor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data) {
                anchors[key] = anchor
            }
        }
    }

    private func persist() {
        lock.lock()
        let cursors = self.cursors
        var stored: [String: Data] = [:]
        for (key, anchor) in anchors {
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) {
                stored[key] = data
            }
        }
        lock.unlock()
        disk.saveCursors(cursors)
        disk.saveAnchors(stored)
    }

    private func anchor(for key: String) -> HKQueryAnchor? {
        lock.lock()
        defer { lock.unlock() }
        return anchors[key]
    }

    private func setAnchor(_ anchor: HKQueryAnchor?, for key: String) {
        guard let anchor else { return }
        lock.lock()
        anchors[key] = anchor
        lock.unlock()
    }

    private struct SampleKind {
        var recordType: String
        var category: HealthIngestCategory
        var sampleType: HKSampleType
    }

    private static func readTypes() -> [SampleKind] {
        var kinds: [SampleKind] = [
            SampleKind(recordType: HealthIngestType.workout, category: .workouts, sampleType: HKWorkoutType.workoutType())
        ]
        let quantities: [(String, HealthIngestCategory, HKQuantityTypeIdentifier)] = [
            (HealthIngestType.heartRate, .heart, .heartRate),
            (HealthIngestType.restingHR, .heart, .restingHeartRate),
            (HealthIngestType.hrv, .heart, .heartRateVariabilitySDNN),
            (HealthIngestType.activeEnergy, .activity, .activeEnergyBurned),
            (HealthIngestType.exerciseMinutes, .activity, .appleExerciseTime)
        ]
        for (recordType, category, identifier) in quantities {
            if let type = HKQuantityType.quantityType(forIdentifier: identifier) {
                kinds.append(SampleKind(recordType: recordType, category: category, sampleType: type))
            }
        }
        if let sleep = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) {
            kinds.append(SampleKind(recordType: HealthIngestType.sleepStage, category: .sleep, sampleType: sleep))
        }
        return kinds
    }

    private static func map(_ sample: HKSample, kind: SampleKind) -> HealthIngestRecord? {
        if let workout = sample as? HKWorkout, kind.recordType == HealthIngestType.workout {
            return mapWorkout(workout)
        }
        if let quantity = sample as? HKQuantitySample {
            return mapQuantity(quantity, recordType: kind.recordType)
        }
        if let category = sample as? HKCategorySample, kind.recordType == HealthIngestType.sleepStage {
            return mapSleep(category)
        }
        return nil
    }

    private static func mapWorkout(_ workout: HKWorkout) -> HealthIngestRecord? {
        guard workout.endDate >= workout.startDate else { return nil }
        var energy: Double?
        if let type = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
           let sum = workout.statistics(for: type)?.sumQuantity()
        {
            energy = sum.doubleValue(for: .kilocalorie())
        }
        var heartRate: Double?
        if let type = HKQuantityType.quantityType(forIdentifier: .heartRate),
           let average = workout.statistics(for: type)?.averageQuantity()
        {
            heartRate = average.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        }
        let distance = workout.totalDistance.map { $0.doubleValue(for: .meter()) }
        guard let payload = HealthIngestHealthMapping.workoutPayload(
            activity: activityName(workout.workoutActivityType),
            durationSeconds: workout.duration,
            energyKcal: energy,
            distanceMeters: distance,
            avgHeartRate: heartRate
        ) else { return nil }
        return HealthIngestRecord(
            type: HealthIngestType.workout,
            id: HealthIngestRecordID.sanitize(workout.uuid.uuidString),
            start: workout.startDate,
            end: workout.endDate,
            tz: HealthIngestTime.zoneIdentifier,
            payload: payload
        )
    }

    private static func mapQuantity(_ sample: HKQuantitySample, recordType: String) -> HealthIngestRecord? {
        let value: Double
        switch recordType {
        case HealthIngestType.heartRate,
             HealthIngestType.restingHR:
            value = sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        case HealthIngestType.hrv:
            value = sample.quantity.doubleValue(for: HKUnit.secondUnit(with: .milli))
        case HealthIngestType.activeEnergy:
            value = sample.quantity.doubleValue(for: .kilocalorie())
        case HealthIngestType.exerciseMinutes:
            value = sample.quantity.doubleValue(for: .minute())
        default:
            return nil
        }
        guard let payload = HealthIngestHealthMapping.quantityPayload(recordType: recordType, value: value) else {
            return nil
        }
        guard case .value(let end) = HealthIngestHealthMapping.sampleEnd(
            recordType: recordType,
            start: sample.startDate,
            end: sample.endDate
        ) else { return nil }
        return HealthIngestRecord(
            type: recordType,
            id: HealthIngestRecordID.sanitize(sample.uuid.uuidString),
            start: sample.startDate,
            end: end,
            tz: HealthIngestTime.zoneIdentifier,
            payload: payload
        )
    }

    private static func mapSleep(_ sample: HKCategorySample) -> HealthIngestRecord? {
        let payload = HealthIngestHealthMapping.sleepPayload(hkValue: sample.value)
        guard case .value(let end) = HealthIngestHealthMapping.sampleEnd(
            recordType: HealthIngestType.sleepStage,
            start: sample.startDate,
            end: sample.endDate
        ) else { return nil }
        return HealthIngestRecord(
            type: HealthIngestType.sleepStage,
            id: HealthIngestRecordID.sanitize(sample.uuid.uuidString),
            start: sample.startDate,
            end: end,
            tz: HealthIngestTime.zoneIdentifier,
            payload: payload
        )
    }

    private static func activityName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .cycling: return "cycling"
        case .socialDance,
             .cardioDance: return "dance"
        case .elliptical: return "elliptical"
        case .functionalStrengthTraining: return "functionalStrengthTraining"
        case .hiking: return "hiking"
        case .highIntensityIntervalTraining: return "highIntensityIntervalTraining"
        case .mixedCardio: return "mixedCardio"
        case .pilates: return "pilates"
        case .rowing: return "rowing"
        case .running: return "running"
        case .stairClimbing: return "stairClimbing"
        case .swimming: return "swimming"
        case .traditionalStrengthTraining: return "traditionalStrengthTraining"
        case .walking: return "walking"
        case .yoga: return "yoga"
        default:
            // HKWorkoutActivityType.dance is raw value 14. It is deprecated, and older workouts still use it.
            if type.rawValue == 14 { return "dance" }
            return "other"
        }
    }
}



/// Builds HealthKit ingest payloads using the server contract field names and ranges.
enum HealthIngestHealthMapping {
    static let source = "healthkit"

    enum SampleEnd: Equatable {
        case drop
        case value(Date?)
    }

    static func quantityPayload(recordType: String, value: Double) -> HealthIngestJSON? {
        guard value.isFinite else { return nil }
        let key: String
        let valid: Bool
        switch recordType {
        case HealthIngestType.heartRate:
            key = "bpm"
            valid = value >= 1 && value <= 350
        case HealthIngestType.restingHR:
            key = "bpm"
            valid = value >= 1 && value <= 250
        case HealthIngestType.hrv:
            key = "sdnnMs"
            valid = value > 0 && value <= 500
        case HealthIngestType.activeEnergy:
            key = "kcal"
            valid = value >= 0 && value <= 20_000
        case HealthIngestType.exerciseMinutes:
            key = "minutes"
            valid = value >= 0 && value <= 1_440
        default:
            return nil
        }
        guard valid else { return nil }
        return .object([
            key: .number(value),
            "source": .string(source)
        ])
    }

    static func workoutPayload(
        activity: String,
        durationSeconds: TimeInterval,
        energyKcal: Double?,
        distanceMeters: Double?,
        avgHeartRate: Double?
    ) -> HealthIngestJSON? {
        let name = activity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 128 else { return nil }
        guard durationSeconds.isFinite, durationSeconds >= 0, durationSeconds <= 172_800 else { return nil }
        let energy = ranged(energyKcal, min: 0, max: 20_000)
        if let energyKcal, energy == nil { return nil }
        let distance = ranged(distanceMeters, min: 0, max: 1_000_000)
        if let distanceMeters, distance == nil { return nil }
        return .object([
            "activity": .string(name),
            "durationSeconds": .number(durationSeconds),
            "energyKcal": energy.map { .number($0) },
            "distanceMeters": distance.map { .number($0) },
            "avgHeartRate": ranged(avgHeartRate, min: 1, max: 350).map { .number($0) },
            "source": .string(source)
        ])
    }

    static func sleepPayload(hkValue: Int) -> HealthIngestJSON {
        .object([
            "stage": .string(HealthIngestSleep.stage(hkValue: hkValue)),
            "source": .string(source)
        ])
    }

    /// Interval types require `end`. A sample with end before start is dropped.
    /// Instantaneous samples omit `end` when it equals `start`.
    static func sampleEnd(recordType: String, start: Date, end: Date) -> SampleEnd {
        if end < start { return .drop }
        let interval = recordType == HealthIngestType.activeEnergy
            || recordType == HealthIngestType.exerciseMinutes
            || recordType == HealthIngestType.sleepStage
            || recordType == HealthIngestType.workout
        if interval { return .value(end) }
        return .value(end == start ? nil : end)
    }

    private static func ranged(_ value: Double?, min: Double, max: Double) -> Double? {
        guard let value, value.isFinite, value >= min, value <= max else { return nil }
        return value
    }
}

/// Times out and cancels a HealthKit query without resuming its continuation twice.
/// A TaskGroup around the query would still wait for the query task on exit, so
/// the timeout lives here and `store.stop` plus a one-shot resume unblock the caller.
private struct HealthKitQueryTimeout: Error {}

private final class HealthKitQueryGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let store: HKHealthStore
    private var continuation: CheckedContinuation<Value, Error>?
    private var query: HKQuery?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false

    init(store: HKHealthStore) {
        self.store = store
    }

    func setContinuation(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func attach(_ query: HKQuery) {
        lock.lock()
        if finished {
            lock.unlock()
            store.stop(query)
            return
        }
        self.query = query
        lock.unlock()
        store.execute(query)
    }

    func startTimeout(seconds: TimeInterval) {
        let task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            } catch {
                return
            }
            self?.finish(.failure(HealthKitQueryTimeout()))
        }
        lock.lock()
        if finished {
            lock.unlock()
            task.cancel()
            return
        }
        timeoutTask = task
        lock.unlock()
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let query = self.query
        self.query = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()
        timeoutTask?.cancel()
        if let query {
            store.stop(query)
        }
        switch result {
        case .success(let value):
            continuation?.resume(returning: value)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }
}
