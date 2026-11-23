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
    /// Workouts are larger samples and were hitting the 30s limit.
    static let workoutQueryTimeout: TimeInterval = 90

    static func timeout(for recordType: String) -> TimeInterval {
        recordType == HealthIngestType.workout ? workoutQueryTimeout : queryTimeout
    }

    /// The underlying error text, not a generic "could not backfill" line.
    static func failureText(recordType: String, error: Error) -> String {
        if error is HealthKitQueryTimeout {
            return "\(recordType) timed out"
        }
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty { return recordType }
        return "\(recordType): \(detail)"
    }

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
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return Self.readTypes().contains { preferences.isOn($0.category) && cursors[$0.recordType] != nil }
    }

    /// Receives one page of mapped records. The reader never accumulates pages, so at most
    /// one page of `HKSample`s and records is alive at a time.
    typealias PageSink = ([HealthIngestRecord]) async -> Void

    /// Anchored reads, `pageLimit` samples per query and at most `maxPagesPerKind` queries per
    /// type per call. Remaining samples are picked up by the next call because the anchor only
    /// advances past samples that were handed to `sink`. Returns user-visible errors.
    func incremental(
        preferences: HealthIngestPreferences,
        pageLimit: Int,
        maxPagesPerKind: Int,
        sink: PageSink
    ) async -> [String] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        loadIfNeeded()
        var errors: [String] = []
        for kind in Self.readTypes() where preferences.isOn(kind.category) {
            if Task.isCancelled { break }
            errors.append(contentsOf: await anchoredPages(kind: kind, limit: pageLimit, maxPages: maxPagesPerKind, sink: sink))
        }
        return errors
    }

    /// Backfill reads round-robin across types, one `pageLimit` page at a time, `maxPages` pages
    /// in total per call. The cursor for a type only advances after its page went to `sink`.
    func backfill(
        preferences: HealthIngestPreferences,
        pageLimit: Int,
        maxPages: Int,
        sink: PageSink
    ) async -> [String] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        loadIfNeeded()
        var errors: [String] = []
        var skipped: Set<String> = []
        var pages = 0
        while pages < maxPages, !Task.isCancelled {
            var progressed = false
            for kind in Self.readTypes() where preferences.isOn(kind.category) {
                if pages >= maxPages || Task.isCancelled { break }
                if skipped.contains(kind.recordType) { continue }
                guard cursor(for: kind.recordType) != nil else { continue }
                progressed = true
                pages += 1
                if let message = await backfillOnePage(kind: kind, limit: pageLimit, sink: sink) {
                    errors.append(message)
                    skipped.insert(kind.recordType)
                }
            }
            if !progressed { break }
        }
        return errors
    }

    private func anchoredPages(kind: SampleKind, limit: Int, maxPages: Int, sink: PageSink) async -> [String] {
        var pages = 0
        while pages < maxPages, !Task.isCancelled {
            let existing = anchor(for: kind.recordType)
            let predicate: NSPredicate? = existing == nil
                ? HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-24 * 3600), end: nil, options: .strictStartDate)
                : nil
            do {
                let page = try await anchoredQuery(
                    type: kind.sampleType,
                    predicate: predicate,
                    anchor: existing,
                    limit: limit,
                    timeout: Self.timeout(for: kind.recordType)
                )
                let count = page.samples.count
                let records = autoreleasepool { page.samples.compactMap { Self.map($0, kind: kind) } }
                if !records.isEmpty { await sink(records) }
                setAnchor(page.anchor, for: kind.recordType)
                persist()
                pages += 1
                if count < limit { break }
            } catch {
                if error is CancellationError || Task.isCancelled { return [] }
                warning(.healthKit, "Health Ingest \(kind.recordType) query failed", error: error)
                return [Self.failureText(recordType: kind.recordType, error: error)]
            }
        }
        return []
    }

    /// Returns an error message, or nil when the page was read (or the type had nothing left).
    private func backfillOnePage(kind: SampleKind, limit: Int, sink: PageSink) async -> String? {
        guard let cursor = cursor(for: kind.recordType) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: cursor, end: nil, options: .strictStartDate)
        do {
            let samples = try await sampleQuery(
                type: kind.sampleType,
                predicate: predicate,
                limit: limit,
                timeout: Self.timeout(for: kind.recordType)
            )
            guard let last = samples.last else {
                setCursor(nil, for: kind.recordType)
                persist()
                return nil
            }
            let records = autoreleasepool { samples.compactMap { Self.map($0, kind: kind) } }
            if !records.isEmpty { await sink(records) }
            if samples.count < limit {
                setCursor(nil, for: kind.recordType)
            } else if last.startDate > cursor {
                setCursor(last.startDate, for: kind.recordType)
            } else {
                setCursor(last.startDate.addingTimeInterval(1), for: kind.recordType)
            }
            persist()
            return nil
        } catch {
            if error is CancellationError || Task.isCancelled { return nil }
            warning(.healthKit, "Health Ingest \(kind.recordType) backfill failed", error: error)
            return Self.failureText(recordType: kind.recordType, error: error)
        }
    }

    private func cursor(for recordType: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return cursors[recordType]
    }

    private func setCursor(_ date: Date?, for recordType: String) {
        lock.lock()
        cursors[recordType] = date
        lock.unlock()
    }

    private func anchoredQuery(
        type: HKSampleType,
        predicate: NSPredicate?,
        anchor: HKQueryAnchor?,
        limit: Int,
        timeout: TimeInterval
    ) async throws -> (samples: [HKSample], anchor: HKQueryAnchor?) {
        let gate = HealthKitQueryGate<(samples: [HKSample], anchor: HKQueryAnchor?)>(store: store)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.setContinuation(continuation)
                let query = HKAnchoredObjectQuery(
                    type: type,
                    predicate: predicate,
                    anchor: anchor,
                    limit: max(limit, 1)
                ) { _, samples, _, newAnchor, error in
                    if let error {
                        gate.finish(.failure(error))
                    } else {
                        gate.finish(.success((samples ?? [], newAnchor)))
                    }
                }
                gate.attach(query)
                gate.startTimeout(seconds: timeout)
            }
        } onCancel: {
            gate.cancel()
        }
    }

    private func sampleQuery(
        type: HKSampleType,
        predicate: NSPredicate,
        limit: Int,
        timeout: TimeInterval
    ) async throws -> [HKSample] {
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
                gate.startTimeout(seconds: timeout)
            }
        } onCancel: {
            gate.cancel()
        }
    }

    func oldestPendingCursor(preferences: HealthIngestPreferences) -> Date? {
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        let dates = Self.readTypes().compactMap { kind -> Date? in
            guard preferences.isOn(kind.category) else { return nil }
            return cursors[kind.recordType]
        }
        return dates.min()
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
            id: workout.uuid.uuidString,
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
            id: sample.uuid.uuidString,
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
            id: sample.uuid.uuidString,
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
            return "hkWorkoutActivityType.\(type.rawValue)"
        }
    }
}



/// Builds HealthKit ingest payloads using the server contract field names.
/// Values are sent as stored; only non-finite numbers are dropped, because JSON cannot represent them.
enum HealthIngestHealthMapping {
    static let source = "healthkit"

    enum SampleEnd: Equatable {
        case drop
        case value(Date?)
    }

    static func quantityPayload(recordType: String, value: Double) -> HealthIngestJSON? {
        guard value.isFinite else { return nil }
        let key: String
        switch recordType {
        case HealthIngestType.heartRate, HealthIngestType.restingHR:
            key = "bpm"
        case HealthIngestType.hrv:
            key = "sdnnMs"
        case HealthIngestType.activeEnergy:
            key = "kcal"
        case HealthIngestType.exerciseMinutes:
            key = "minutes"
        default:
            return nil
        }
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
        guard !name.isEmpty else { return nil }
        guard durationSeconds.isFinite else { return nil }
        return .object([
            "activity": .string(name),
            "durationSeconds": .number(durationSeconds),
            "energyKcal": energyKcal.flatMap(HealthIngestPayload.finiteNumber),
            "distanceMeters": distanceMeters.flatMap(HealthIngestPayload.finiteNumber),
            "avgHeartRate": avgHeartRate.flatMap(HealthIngestPayload.finiteNumber),
            "source": .string(source)
        ])
    }

    static func sleepPayload(hkValue: Int) -> HealthIngestJSON {
        .object([
            "stage": .string(HealthIngestSleep.stage(hkValue: hkValue)),
            "source": .string(source)
        ])
    }

    /// Send the sample's own start and end. Interval types still include `end`
    /// when it equals or precedes `start`; the server should accept those timestamps.
    static func sampleEnd(recordType: String, start: Date, end: Date) -> SampleEnd {
        let interval = recordType == HealthIngestType.activeEnergy
            || recordType == HealthIngestType.exerciseMinutes
            || recordType == HealthIngestType.sleepStage
            || recordType == HealthIngestType.workout
        if interval { return .value(end) }
        return .value(end == start ? nil : end)
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
