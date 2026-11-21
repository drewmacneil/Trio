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
        try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: type,
                predicate: predicate,
                anchor: anchor,
                limit: HKObjectQueryNoLimit
            ) { _, samples, _, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (samples ?? [], newAnchor))
                }
            }
            store.execute(query)
        }
    }

    private func sampleQuery(type: HKSampleType, predicate: NSPredicate, limit: Int) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: limit, sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            store.execute(query)
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

    private static func mapWorkout(_ workout: HKWorkout) -> HealthIngestRecord {
        let sourceID = workout.uuid.uuidString
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
        let payload = HealthIngestJSON.object([
            "activityType": .string(activityName(workout.workoutActivityType)),
            "activityTypeRaw": .number(Double(workout.workoutActivityType.rawValue)),
            "energyKilocalories": energy.map { .number($0) },
            "distanceMeters": workout.totalDistance.map { .number($0.doubleValue(for: .meter())) },
            "averageHeartRateBpm": heartRate.map { .number($0) },
            "durationSeconds": .number(workout.duration),
            "sourceBundle": .string(workout.sourceRevision.source.bundleIdentifier),
            "sourceId": .string(sourceID)
        ])
        return HealthIngestRecord(
            type: HealthIngestType.workout,
            id: sourceID,
            start: workout.startDate,
            end: workout.endDate,
            tz: HealthIngestTime.zoneIdentifier,
            payload: payload
        )
    }

    private static func mapQuantity(_ sample: HKQuantitySample, recordType: String) -> HealthIngestRecord {
        let value: Double
        let key: String
        switch recordType {
        case HealthIngestType.heartRate,
             HealthIngestType.restingHR:
            key = "bpm"
            value = sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        case HealthIngestType.hrv:
            key = "sdnnMilliseconds"
            value = sample.quantity.doubleValue(for: HKUnit.secondUnit(with: .milli))
        case HealthIngestType.activeEnergy:
            key = "kilocalories"
            value = sample.quantity.doubleValue(for: .kilocalorie())
        case HealthIngestType.exerciseMinutes:
            key = "minutes"
            value = sample.quantity.doubleValue(for: .minute())
        default:
            key = "value"
            value = sample.quantity.doubleValue(for: .count())
        }
        let sourceID = sample.uuid.uuidString
        let requiresEnd = recordType == HealthIngestType.activeEnergy || recordType == HealthIngestType.exerciseMinutes
        let end: Date? = requiresEnd ? sample.endDate : (sample.endDate == sample.startDate ? nil : sample.endDate)
        let payload = HealthIngestJSON.object([
            key: .number(value),
            "sourceBundle": .string(sample.sourceRevision.source.bundleIdentifier),
            "sourceId": .string(sourceID)
        ])
        return HealthIngestRecord(
            type: recordType,
            id: sourceID,
            start: sample.startDate,
            end: end,
            tz: HealthIngestTime.zoneIdentifier,
            payload: payload
        )
    }

    private static func mapSleep(_ sample: HKCategorySample) -> HealthIngestRecord {
        let sourceID = sample.uuid.uuidString
        let payload = HealthIngestJSON.object([
            "stage": .string(HealthIngestSleep.stage(hkValue: sample.value)),
            "hkValue": .number(Double(sample.value)),
            "sourceBundle": .string(sample.sourceRevision.source.bundleIdentifier),
            "sourceId": .string(sourceID)
        ])
        return HealthIngestRecord(
            type: HealthIngestType.sleepStage,
            id: sourceID,
            start: sample.startDate,
            end: sample.endDate,
            tz: HealthIngestTime.zoneIdentifier,
            payload: payload
        )
    }

    private static func activityName(_ type: HKWorkoutActivityType) -> String {
        let names: [HKWorkoutActivityType: String] = [
            .cycling: "cycling",
            .dance: "dance",
            .elliptical: "elliptical",
            .functionalStrengthTraining: "functionalStrengthTraining",
            .hiking: "hiking",
            .highIntensityIntervalTraining: "highIntensityIntervalTraining",
            .mixedCardio: "mixedCardio",
            .other: "other",
            .pilates: "pilates",
            .rowing: "rowing",
            .running: "running",
            .stairClimbing: "stairClimbing",
            .swimming: "swimming",
            .traditionalStrengthTraining: "traditionalStrengthTraining",
            .walking: "walking",
            .yoga: "yoga"
        ]
        return names[type] ?? "other"
    }
}
