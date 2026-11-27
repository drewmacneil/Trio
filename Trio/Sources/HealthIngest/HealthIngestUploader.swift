import Combine
import Foundation
import G7SensorKit
import HealthKit
import LoopKitUI
import Swinject
import UIKit

/// What a mapping-version bump re-sends.
///
/// Going from stored version N to current version M applies every registered step
/// from N+1 through M. HealthKit is reset if any of those steps resets it, and the
/// Core Data rewind is the longest any of them asks for. A step that is not
/// registered falls back to a full reset, so a version bump with no rule cannot
/// leave HealthKit cursors in place while the new fields stay unsent.
/// A downgrade (stored version already at or above the running build) changes nothing:
/// cursors, anchors, and the stored version stay as they are.
enum HealthIngestMappingUpgrade {
    struct Step: Equatable {
        var resetHealthKit: Bool
        var rewindCoreDataDays: Int
    }

    struct Plan: Equatable {
        var resetHealthKit: Bool
        var rewindCoreDataDays: Int
    }

    /// The version being entered, and what that step needs re-sent.
    /// Versions 1 through 6 are the historical full reset. Versions 7 and 8 only
    /// rewind Core Data: `persistCoreDataRewind` writes the historical resume and
    /// does not call `beginBackfill`. Version 8 resends glucose with `trend`.
    /// Version 9 resends glucose with `source` in the payload.
    static let steps: [Int: Step] = [
        1: Step(resetHealthKit: true, rewindCoreDataDays: 90),
        2: Step(resetHealthKit: true, rewindCoreDataDays: 90),
        3: Step(resetHealthKit: true, rewindCoreDataDays: 90),
        4: Step(resetHealthKit: true, rewindCoreDataDays: 90),
        5: Step(resetHealthKit: true, rewindCoreDataDays: 90),
        6: Step(resetHealthKit: true, rewindCoreDataDays: 90),
        7: Step(resetHealthKit: false, rewindCoreDataDays: 90),
        8: Step(resetHealthKit: false, rewindCoreDataDays: 90),
        9: Step(resetHealthKit: false, rewindCoreDataDays: 90)
    ]

    /// Used when the range N+1...M contains a version with no step.
    static let fullReset = Plan(resetHealthKit: true, rewindCoreDataDays: 90)

    static func plan(storedVersion: Int, currentVersion: Int) -> Plan? {
        guard storedVersion < currentVersion else { return nil }
        var resetHealthKit = false
        var rewindDays = 0
        for version in (storedVersion + 1) ... currentVersion {
            guard let step = steps[version] else { return fullReset }
            resetHealthKit = resetHealthKit || step.resetHealthKit
            rewindDays = max(rewindDays, step.rewindCoreDataDays)
        }
        return Plan(resetHealthKit: resetHealthKit, rewindCoreDataDays: rewindDays)
    }
}

/// Which Core Data windows one pass reads, in order.
///
/// A HealthKit backfill still uses one cursor and is the only read that starts
/// `beginBackfill`. A Core Data rewind keeps a separate cursor: every pass reads
/// the live window first, then one historical chunk. That chunk never starts a
/// HealthKit backfill and never moves the backfill window.
enum HealthIngestDiabetesSchedule {
    struct Read: Equatable {
        enum Role: Equatable {
            case live
            case historical
            /// The Core Data window that belongs to an explicit HealthKit backfill.
            case healthKitBackfill
        }

        var role: Role
        var since: Date
        var until: Date?
    }

    struct Plan: Equatable {
        var reads: [Read]
        /// When true, write `historicalResume` (nil clears a finished rewind).
        var persistHistorical: Bool
        var historicalResume: Date?
        var persistDiabetesResume: Bool
        var diabetesResume: Date?
        /// Set when a HealthKit backfill was requested during a Core Data rewind.
        /// The live window stays the first read. Nil for every other plan.
        var healthKitBackfillSince: Date?
    }

    static let liveLookback: TimeInterval = 36 * 3600
    static let liveOverlap: TimeInterval = 6 * 3600
    static let maxLookback: TimeInterval = 90 * 24 * 3600
    static let caughtUpSlack: TimeInterval = 60

    /// The earlier of "the last 36 hours" and "since the last live success",
    /// not older than 90 days. Trio does not keep treatment history past that.
    static func liveSince(now: Date, lastLiveSuccess: Date?) -> Date {
        let regular = now.addingTimeInterval(-liveLookback)
        let catchUp = lastLiveSuccess?.addingTimeInterval(-liveOverlap) ?? regular
        let oldest = now.addingTimeInterval(-maxLookback)
        return max(oldest, min(regular, catchUp))
    }

    static func windowEnd(from start: Date, chunk: TimeInterval, now: Date) -> Date? {
        let end = start.addingTimeInterval(chunk)
        return end < now.addingTimeInterval(-caughtUpSlack) ? end : nil
    }

    static func plan(
        now: Date,
        chunk: TimeInterval,
        lastLiveSuccess: Date?,
        backfillRequest: Date?,
        diabetesResume: Date?,
        historicalResume: Date?
    ) -> Plan {
        if let historical = historicalResume {
            return historicalPlan(
                now: now,
                chunk: chunk,
                lastLiveSuccess: lastLiveSuccess,
                historical: historical,
                backfillRequest: backfillRequest
            )
        }
        if let requested = backfillRequest {
            let until = windowEnd(from: requested, chunk: chunk, now: now)
            return Plan(
                reads: [Read(role: .healthKitBackfill, since: requested, until: until)],
                persistHistorical: false,
                historicalResume: nil,
                persistDiabetesResume: true,
                diabetesResume: until,
                healthKitBackfillSince: nil
            )
        }
        if let resume = diabetesResume {
            let until = windowEnd(from: resume, chunk: chunk, now: now)
            return Plan(
                reads: [Read(role: .live, since: resume, until: until)],
                persistHistorical: false,
                historicalResume: nil,
                persistDiabetesResume: true,
                diabetesResume: until,
                healthKitBackfillSince: nil
            )
        }
        let since = liveSince(now: now, lastLiveSuccess: lastLiveSuccess)
        let until = windowEnd(from: since, chunk: chunk, now: now)
        return Plan(
            reads: [Read(role: .live, since: since, until: until)],
            persistHistorical: false,
            historicalResume: nil,
            persistDiabetesResume: true,
            diabetesResume: until,
            healthKitBackfillSince: nil
        )
    }

    private static func historicalPlan(
        now: Date,
        chunk: TimeInterval,
        lastLiveSuccess: Date?,
        historical: Date,
        backfillRequest: Date?
    ) -> Plan {
        let live = liveSince(now: now, lastLiveSuccess: lastLiveSuccess)
        var reads = [Read(role: .live, since: live, until: nil)]
        var next: Date? = historical
        if historical >= now.addingTimeInterval(-caughtUpSlack) {
            next = nil
        } else {
            let end = historical.addingTimeInterval(chunk)
            if end >= now.addingTimeInterval(-caughtUpSlack) {
                reads.append(Read(role: .historical, since: historical, until: nil))
                next = nil
            } else {
                reads.append(Read(role: .historical, since: historical, until: end))
                next = end
            }
        }
        return Plan(
            reads: reads,
            persistHistorical: true,
            historicalResume: next,
            persistDiabetesResume: false,
            diabetesResume: nil,
            healthKitBackfillSince: backfillRequest
        )
    }
}

/// Uploads Trio and HealthKit data to a private ingest server. The loop never waits on this.
/// Work runs on a utility task, batches, and backs off. The queue is on disk.
final class HealthIngestUploader: ObservableObject, Injectable {
    @Injected() private var keychain: Keychain!
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var profiles: TherapyProfileStorage!
    @Injected() private var healthStore: HKHealthStore!
    @Injected() private var broadcaster: Broadcaster!

    @Published private(set) var preferences = HealthIngestPreferences.initial
    @Published private(set) var status = HealthIngestStatus()
    /// Picker value when no backfill is running. A running pass shows its own day count.
    @Published private(set) var backfillDayChoice = 7

    private var settingsStore: HealthIngestSettingsStore!
    private let stateLock = NSLock()
    private var storedPreferences = HealthIngestPreferences.initial
    private var lastSuccess: Date?
    private var lastError: String?
    private var backfillSince: Date?
    private var backfillRunning = false
    private var consecutiveFailures = 0

    private var disk: HealthIngestDisk?
    private var queue: HealthIngestQueue?
    private var health: HealthIngestHealthKitReader?
    private let container: Resolver
    private let client = HealthIngestClient()
    private let wake = HealthIngestWake()
    private var loopTask: Task<Void, Never>?
    private var contentCancellable: AnyCancellable?
    private var started = false
    private let adapter = HealthIngestDiabetesAdapter()
    /// Guarded by `stateLock`. False until the app says otherwise, so a launch caused by
    /// HealthKit background delivery starts with the small background budget.
    private var appActive = false
    private var diabetesResume: Date?
    /// Core Data rewind cursor. Independent of `diabetesResume` and of the HealthKit backfill.
    private var historicalResume: Date?
    /// Accepted rows since this rewrite started. Shown on the same card as a HealthKit backfill.
    private var rewriteRowsSent = 0
    private var rewriteRowsSavedAt: Date?
    private var lastDiabetesRead: Date?
    /// Test seam. A Core Data rewind is already on disk; return before the mapping
    /// version is saved, as if the process was killed between the two writes.
    var stopAfterPersistingCoreDataRewind = false
    private var backfillDayCount = 0
    private var backfillWindowStart: Date?
    private var backfillRowsSent = 0
    private var backfillChosenDays = 7
    private var backfillProgressSavedAt: Date?
    private var lifecycle = Set<AnyCancellable>()

    /// How much one pass may read, hold, and send. Backgrounded work is kept small because
    /// iOS gives a background process far less memory before it jetsams it.
    private struct Budget {
        var hkPageLimit: Int
        var backfillPages: Int
        var incrementalPages: Int
        var flushBatches: Int
        var backlogHighWater: Int
        var diabetesChunk: TimeInterval
        var minDiabetesInterval: TimeInterval

        static let foreground = Budget(
            hkPageLimit: 500,
            backfillPages: 4,
            incrementalPages: 2,
            flushBatches: 8,
            backlogHighWater: 6000,
            diabetesChunk: 2 * 24 * 3600,
            minDiabetesInterval: 0
        )
        static let background = Budget(
            hkPageLimit: 250,
            backfillPages: 1,
            incrementalPages: 1,
            flushBatches: 2,
            backlogHighWater: 1500,
            diabetesChunk: 24 * 3600,
            minDiabetesInterval: 600
        )
    }

    init(resolver: Resolver) {
        container = resolver
        injectServices(resolver)
        settingsStore = HealthIngestSettingsStore(keychain: keychain)
        let stored = settingsStore.load()
        let loaded = stored.withAllCategoriesOn()
        if loaded != stored {
            settingsStore.save(loaded)
        }
        storedPreferences = loaded
        preferences = loaded
        status.hasToken = settingsStore.hasToken()
        observeLifecycle()
        if loaded.enabled {
            // Never decode the on-disk queue or start HealthKit on the
            // main actor. loadServices() resolves this type on MainActor
            // before first UI.
            scheduleStart()
        }
    }

    /// A relaunch over an existing directory. The reader is created and not loaded;
    /// the status is the one `prepare()` publishes. Tests use this to catch a restore
    /// that reads cursors before they are loaded from disk.
    init(relaunchFrom disk: HealthIngestDisk, preferences: HealthIngestPreferences) {
        container = Assembler().resolver
        let defaults = UserDefaults(suiteName: "health-ingest-relaunch-\(UUID().uuidString)") ?? .standard
        settingsStore = HealthIngestSettingsStore(
            defaults: defaults,
            keychain: BaseKeychain(serviceName: "trio.health-ingest.relaunch.\(UUID().uuidString)", synchronizable: false)
        )
        let normalized = preferences.withAllCategoriesOn()
        storedPreferences = normalized
        self.preferences = normalized
        self.disk = disk
        health = HealthIngestHealthKitReader(store: HKHealthStore(), disk: disk)
        historicalResume = disk.loadHistoricalResume()
        rewriteRowsSent = disk.loadRewriteRowsSent()
    }

    /// Restores backfill progress the way a launch does, then returns the status snapshot
    /// that launch publishes. The reader must still be unloaded.
    func publishRelaunchStatus() -> HealthIngestStatus {
        restoreBackfillProgress()
        let snapshot = makeSnapshot(depth: 0, priorityDepth: 0)
        Task { @MainActor [weak self] in
            self?.status = snapshot
        }
        return snapshot
    }

    @MainActor func setEnabled(_ enabled: Bool, baseURL: String, deviceID: String) {
        var prefs = currentPreferences()
        prefs.enabled = enabled
        prefs.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        prefs.deviceID = deviceID
        commit(prefs)
    }

    @MainActor func setServer(baseURL: String, deviceID: String) {
        var prefs = currentPreferences()
        prefs.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        prefs.deviceID = deviceID
        commit(prefs)
    }

    /// Turning a category off stops new collection for that category. Records of
    /// that type already on the on-device queue are left there until they are
    /// accepted, dropped after repeated rejects, or the queue file is cleared.
    @MainActor func setCategory(_ category: HealthIngestCategory, enabled: Bool) {
        var prefs = currentPreferences()
        prefs.categories[category.rawValue] = enabled
        commit(prefs)
        if prefs.enabled, enabled, category.readsHealthKit {
            Task.detached(priority: .utility) { [weak self] in
                await self?.health?.requestAuthorization()
            }
        }
    }

    @MainActor func setToken(_ raw: String) {
        settingsStore.setToken(raw)
        settingsStore.bumpTokenRevision()
        status.hasToken = settingsStore.hasToken()
        poke()
    }

    @MainActor func clearToken() {
        settingsStore.setToken("")
        settingsStore.bumpTokenRevision()
        status.hasToken = false
    }

    func tokenRevision() -> Int { settingsStore.tokenRevision() }

    func connectionCheck() -> HealthIngestConnectionCheck? { settingsStore.loadConnection() }

    @MainActor func rememberConnection(_ check: HealthIngestConnectionCheck) {
        settingsStore.saveConnection(check)
    }

    @MainActor func clearConnectionCheck() {
        settingsStore.saveConnection(nil)
    }

    @MainActor func testConnection(baseURL: String, deviceID: String) async -> HealthIngestProbe {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var prefs = currentPreferences()
        prefs.baseURL = trimmed
        prefs.deviceID = deviceID
        commit(prefs)
        guard let origin = HealthIngestOrigin.parse(trimmed) else {
            return .badURL
        }
        guard let token = settingsStore.token() else {
            return .missingToken
        }
        let started = Date()
        do {
            let code = try await client.status(origin: origin, token: token)
            if (200 ... 299).contains(code) {
                let milliseconds = max(0, Int(Date().timeIntervalSince(started) * 1000))
                return .connected(milliseconds: milliseconds)
            }
            if code == 401 { return .tokenRejected }
            return .http(code)
        } catch let error as URLError where error.code == .timedOut {
            return .timedOut
        } catch {
            return .unreachable
        }
    }

    @MainActor func backfill(days: Int) {
        guard currentPreferences().enabled else { return }
        let bounded = min(max(days, 1), 90)
        let since = Date().addingTimeInterval(-Double(bounded) * 24 * 3600)
        stateLock.lock()
        backfillSince = min(backfillSince ?? since, since)
        backfillRunning = true
        backfillDayCount = bounded
        backfillWindowStart = since
        backfillRowsSent = 0
        stateLock.unlock()
        poke()
        publishSnapshot(depth: status.queueDepth, priorityDepth: status.priorityDepth, backfillDepth: status.backfillDepth)
        Task.detached(priority: .utility) { [weak self] in
            guard let self, (try? self.prepare()) != nil else { return }
            self.saveActiveBackfill()
        }
    }

    @MainActor func rememberBackfillDays(_ days: Int) {
        let bounded = min(max(days, 1), 90)
        backfillDayChoice = bounded
        stateLock.lock()
        backfillChosenDays = bounded
        stateLock.unlock()
        Task.detached(priority: .utility) { [weak self] in
            guard let self, (try? self.prepare()) != nil else { return }
            self.saveBackfillChoice()
        }
    }

    @MainActor func clearRejections() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            if let queue = try? self.prepare() {
                await queue.clearRejections()
                let depth = await queue.depth()
                let priorityDepth = await queue.priorityDepth()
                let backfillDepth = await queue.backfillDepth()
                self.publishSnapshot(depth: depth, priorityDepth: priorityDepth, backfillDepth: backfillDepth)
            }
        }
    }

    /// Clears HealthKit backfill cursors and rejected receipts, drops queued
    /// HealthKit records from an older mapping, and starts a fresh backfill.
    @MainActor func resetBackfill(days: Int) {
        guard currentPreferences().enabled else { return }
        Task.detached(priority: .utility) { [weak self] in
            await self?.performResetBackfill(days: days)
        }
    }

    private func performResetBackfill(days: Int) async {
        guard let queue = try? prepare(), let health, let disk else { return }
        await queue.forgetRejectedReceipts()
        await queue.dropTypes(HealthIngestType.contractResendTypes)
        health.resetBackfillCursors()
        HealthIngestLoopCapture.requeueStoredProfiles()
        disk.saveMappingVersion(HealthIngestWire.mappingVersion)
        let depth = await queue.depth()
        let priorityDepth = await queue.priorityDepth()
        let backfillDepth = await queue.backfillDepth()
        await MainActor.run { [weak self] in
            guard let self else { return }
            self.publishSnapshot(depth: depth, priorityDepth: priorityDepth, backfillDepth: backfillDepth)
            self.backfill(days: days)
        }
    }

    func applyMappingUpgradeIfNeeded() async {
        if disk == nil || health == nil {
            guard (try? prepare()) != nil else { return }
        }
        guard let disk, let health else { return }
        let stored = disk.loadMappingVersion()
        guard let plan = HealthIngestMappingUpgrade.plan(
            storedVersion: stored,
            currentVersion: HealthIngestWire.mappingVersion
        ) else { return }
        if plan.resetHealthKit {
            let queue = self.queue ?? HealthIngestQueue(disk: disk)
            await queue.forgetRejectedReceipts()
            await queue.clearRejections()
            await queue.dropTypes(HealthIngestType.contractResendTypes)
            health.resetBackfillCursors()
            HealthIngestLoopCapture.requeueStoredProfiles()
            if plan.rewindCoreDataDays > 0 {
                rewindCoreDataRead(days: plan.rewindCoreDataDays)
            }
        } else if plan.rewindCoreDataDays > 0 {
            // The rewind is on disk before the version. A kill between the two
            // leaves the old version, so the next launch retries and keeps this cursor.
            persistCoreDataRewind(days: plan.rewindCoreDataDays)
            if stopAfterPersistingCoreDataRewind { return }
        }
        disk.saveMappingVersion(HealthIngestWire.mappingVersion)
        let depth = await queue?.depth() ?? 0
        let priorityDepth = await queue?.priorityDepth() ?? 0
        let backfillDepth = await queue?.backfillDepth() ?? 0
        publishSnapshot(depth: depth, priorityDepth: priorityDepth, backfillDepth: backfillDepth)
    }

    /// Writes the Core Data rewind cursor. A cursor already on disk is kept, so a
    /// retry after a kill does not move it. Does not call `beginBackfill` and does
    /// not write the HealthKit backfill window.
    private func persistCoreDataRewind(days: Int) {
        guard let disk else { return }
        let existing = disk.loadHistoricalResume()
        let since: Date
        if let existing {
            since = existing
        } else {
            let bounded = min(max(days, 1), 90)
            since = Date().addingTimeInterval(-Double(bounded) * 24 * 3600)
            disk.saveHistoricalResume(since)
            disk.saveDiabetesResume(nil)
            disk.saveRewriteRowsSent(0)
        }
        stateLock.lock()
        historicalResume = since
        if existing == nil {
            diabetesResume = nil
            backfillSince = nil
            rewriteRowsSent = 0
            rewriteRowsSavedAt = nil
        }
        stateLock.unlock()
    }

    /// HealthKit-resetting steps only. The next diabetes read starts here and calls
    /// `beginBackfill`. A Core Data-only step uses `persistCoreDataRewind` instead.
    private func rewindCoreDataRead(days: Int) {
        let bounded = min(max(days, 1), 90)
        let since = Date().addingTimeInterval(-Double(bounded) * 24 * 3600)
        stateLock.lock()
        backfillSince = min(backfillSince ?? since, since)
        backfillRunning = true
        backfillDayCount = bounded
        backfillWindowStart = since
        backfillRowsSent = 0
        stateLock.unlock()
        saveActiveBackfill()
    }

    private func commit(_ incoming: HealthIngestPreferences) {
        var prefs = incoming
        prefs.deviceID = prefs.normalizedDeviceID
        stateLock.lock()
        storedPreferences = prefs
        stateLock.unlock()
        settingsStore.save(prefs)
        preferences = prefs
        if prefs.enabled {
            scheduleStart()
        } else {
            stop()
        }
        poke()
    }

    private func currentPreferences() -> HealthIngestPreferences {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedPreferences
    }

    private func observeLifecycle() {
        // The app's NotificationCenter protocol hides Foundation.NotificationCenter.
        Foundation.NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.setActive(false) }
            .store(in: &lifecycle)
        Foundation.NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.setActive(true)
                self?.poke()
            }
            .store(in: &lifecycle)
        // HealthKit reads fail while the phone is locked. Retry as soon as the data is readable
        // instead of waiting out the idle delay.
        Foundation.NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)
            .sink { [weak self] _ in self?.poke() }
            .store(in: &lifecycle)
        Task { @MainActor [weak self] in
            self?.setActive(UIApplication.shared.applicationState == .active)
        }
    }

    private func setActive(_ active: Bool) {
        stateLock.lock()
        appActive = active
        stateLock.unlock()
    }

    private func currentBudget() -> Budget {
        stateLock.lock()
        defer { stateLock.unlock() }
        return appActive ? .foreground : .background
    }

    /// Starts the upload loop on a utility thread. Must not be called on the
    /// main actor: `prepare()` JSON-decodes the on-disk queue and receipts.
    private func scheduleStart() {
        Task.detached(priority: .utility) { [weak self] in
            self?.start()
        }
    }

    private func start() {
        if started {
            ensureLoopRunning()
            refreshObservers()
            return
        }
        let queue: HealthIngestQueue
        do {
            queue = try prepare()
        } catch {
            stateLock.lock()
            lastError = "Could not open the on-device queue."
            stateLock.unlock()
            publishSnapshot(depth: 0, priorityDepth: 0)
            warning(.healthKit, "Health Ingest queue failed to open", error: error)
            return
        }
        broadcaster.register(SettingsObserver.self, observer: self)
        broadcaster.register(PreferencesObserver.self, observer: self)
        contentCancellable = CoreDataStack.shared.contentChangePublisher
            .debounce(for: .seconds(20), scheduler: DispatchQueue.global(qos: .utility))
            .sink { [weak self] _ in self?.poke() }
        refreshObservers()
        loopTask = Task.detached(priority: .utility) { [weak self] in
            await self?.run()
        }
        started = true
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let depth = await queue.depth()
            let priorityDepth = await queue.priorityDepth()
            let backfillDepth = await queue.backfillDepth()
            self.publishSnapshot(depth: depth, priorityDepth: priorityDepth, backfillDepth: backfillDepth)
        }
    }

    private func stop() {
        guard started else { return }
        started = false
        loopTask?.cancel()
        loopTask = nil
        contentCancellable?.cancel()
        contentCancellable = nil
        health?.stopObservers()
        broadcaster.unregister(SettingsObserver.self, observer: self)
        broadcaster.unregister(PreferencesObserver.self, observer: self)
    }

    private func refreshObservers() {
        guard let health else { return }
        let prefs = currentPreferences()
        if prefs.enabled, prefs.requestsHealthData {
            health.startObservers { [weak self] in self?.poke() }
            Task.detached(priority: .utility) { [weak self] in
                await self?.health?.requestAuthorization()
            }
        } else {
            health.stopObservers()
        }
    }

    private func prepare() throws -> HealthIngestQueue {
        if let queue { return queue }
        let disk = try HealthIngestDisk.makeDefault()
        let queue = HealthIngestQueue(disk: disk)
        let health = HealthIngestHealthKitReader(store: healthStore, disk: disk)
        self.disk = disk
        self.queue = queue
        self.health = health
        let persisted = disk.loadStatus()
        stateLock.lock()
        lastSuccess = persisted.lastSuccess
        lastError = persisted.lastError
        diabetesResume = disk.loadDiabetesResume()
        historicalResume = disk.loadHistoricalResume()
        rewriteRowsSent = disk.loadRewriteRowsSent()
        stateLock.unlock()
        restoreBackfillProgress()
        return queue
    }

    private func run() async {
        if let queue {
            await queue.reconcileRejectedCount()
        }
        await applyMappingUpgradeIfNeeded()
        while !Task.isCancelled {
            let prefs = currentPreferences()
            let configured = HealthIngestOrigin.parse(prefs.baseURL) != nil && settingsStore.hasToken()
            guard prefs.enabled, configured else {
                await wake.wait(seconds: 30)
                continue
            }
            let seen = await wake.current()
            await collectAndSend()
            if Task.isCancelled { return }
            if await wake.current() != seen { continue }
            let failures = consecutiveFailures
            let wait = failures > 0 ? HealthIngestBackoff.delay(afterFailures: failures) : await idleDelay()
            await wake.wait(seconds: wait)
        }
    }

    private func idleDelay() async -> TimeInterval {
        let prefs = currentPreferences()
        let pendingBackfill = health?.hasPendingBackfill(preferences: prefs) ?? false
        let ready: Bool
        if let queue {
            ready = await queue.hasReady()
        } else {
            ready = false
        }
        let activity = lockedActivity()
        if pendingBackfill || ready || activity.catchingUp { return activity.active ? 5 : 30 }
        return 90
    }

    struct FlushOutcome {
        var sentAny: Bool
        var failed: Bool
        /// Trio rows are still queued and were not sendable on this pass.
        var priorityRemaining = false
    }

    /// Shared by the upload pass and tests. A closure that returns true stops the drain.
    private final class FlushMark {
        var sentAny: Bool
        var failed: Bool
        var blocked: Bool

        init(sentAny: Bool, failed: Bool) {
            self.sentAny = sentAny
            self.failed = failed
            blocked = false
        }
    }

    /// Sends already-ready queue items. Must not await HealthKit or a Core Data reread.
    private func flushReadyBatches(
        queue: HealthIngestQueue,
        origin: URL,
        token: String,
        deviceID: String,
        maxBatches: Int
    ) async -> FlushOutcome {
        var sentAny = false
        var failed = false
        var batches = 0
        while batches < maxBatches, !Task.isCancelled {
            let batch = await queue.nextBatch(
                limit: HealthIngestWire.maxBatchRecords,
                maxBytes: HealthIngestWire.maxBatchBytes
            )
            if batch.isEmpty { break }
            let outcome = await send(batch, origin: origin, token: token, queue: queue, deviceID: deviceID)
            batches += 1
            if outcome {
                failed = true
                break
            }
            sentAny = true
        }
        return FlushOutcome(sentAny: sentAny, failed: failed)
    }

    /// Sends ready batches until the Trio lane is empty, a send fails, or the
    /// next ready batch has no Trio row (the rest are waiting out a backoff).
    /// Does not stop at the pass's batch budget. A batch may also carry Health
    /// rows that filled the remainder. Must not await HealthKit or Core Data.
    func flushPriorityUntilDrained(
        queue: HealthIngestQueue,
        sendBatch: ([HealthIngestRecord]) async -> Bool
    ) async -> FlushOutcome {
        var sentAny = false
        var failed = false
        var priorityRemaining = false
        while !Task.isCancelled {
            let depth = await queue.priorityDepth()
            if depth == 0 { break }
            let batch = await queue.nextBatch(
                limit: HealthIngestWire.maxBatchRecords,
                maxBytes: HealthIngestWire.maxBatchBytes
            )
            guard batch.contains(where: { HealthIngestType.isPriorityLane($0.type) }) else {
                priorityRemaining = true
                break
            }
            if await sendBatch(batch) {
                failed = true
                priorityRemaining = await queue.priorityDepth() > 0
                break
            }
            sentAny = true
            let after = await queue.priorityDepth()
            if after >= depth {
                priorityRemaining = after > 0
                break
            }
        }
        return FlushOutcome(sentAny: sentAny, failed: failed, priorityRemaining: priorityRemaining)
    }

    /// Records the latest live G7 snapshot, then drains the Trio lane.
    private func drainPriorityBeforeSlowRead(
        queue: HealthIngestQueue,
        origin: URL,
        token: String,
        deviceID: String,
        enqueue: ([HealthIngestRecord]) async -> Void
    ) async -> FlushOutcome {
        let events = liveCGMRecords()
        if !events.isEmpty {
            await enqueue(events)
        }
        return await flushPriorityUntilDrained(queue: queue) { batch in
            await self.send(batch, origin: origin, token: token, queue: queue, deviceID: deviceID)
        }
    }

    private func collectAndSend() async {
        guard let queue = try? prepare(), let disk, let health else { return }
        let prefs = currentPreferences()
        guard let origin = HealthIngestOrigin.parse(prefs.baseURL), let token = settingsStore.token() else { return }

        // Drain the existing queue first. A hung HealthKit incremental or backfill
        // used to run before any send, so lastSuccess and queue depth could freeze
        // after the first 4-batch flush.
        var sentAny = false
        var failed = false
        let firstFlush = await flushReadyBatches(
            queue: queue,
            origin: origin,
            token: token,
            deviceID: prefs.normalizedDeviceID,
            maxBatches: currentBudget().flushBatches
        )
        sentAny = firstFlush.sentAny
        failed = firstFlush.failed

        let budget = currentBudget()
        var oversized = 0
        var errors: [String] = []

        func enqueuePage(_ records: [HealthIngestRecord], fromBackfill: Bool = false) async {
            let added = await queue.enqueue(records, fromBackfill: fromBackfill)
            oversized += added.oversized
            if added.queued > 0 {
                debug(.healthKit, "Health Ingest queued \(added.queued) records")
            }
        }

        let mark = FlushMark(sentAny: sentAny, failed: failed)
        if !failed, !Task.isCancelled {
            // Live G7 fields are logging only. This does not read or write the
            // Core Data rewind cursor. Snapshot before the live window so those
            // glucose rows can pick up the current trend rate.
            let liveEvents = liveCGMRecords()
            if !liveEvents.isEmpty {
                await enqueuePage(liveEvents)
            }
            let now = Date()
            let throttled = budget.minDiabetesInterval > 0
                && (lockedLastDiabetesRead().map { now.timeIntervalSince($0) < budget.minDiabetesInterval } ?? false)
            // HealthKit depth used to skip this read while catching up, so recent glucose
            // and treatments waited behind a backfill. Only this lane's own cap applies.
            let gate = HealthIngestReadGate.decide(
                healthKitDepth: await queue.regularDepth(),
                priorityDepth: await queue.priorityDepth(),
                highWater: budget.backlogHighWater,
                throttled: throttled
            )
            if gate.readDiabetes {
                let devices = resolverDevices()
                let readErrors = await runScheduledDiabetesPass(
                    now: now,
                    chunk: budget.diabetesChunk,
                    read: { spec in
                        let diabetes = await adapter.records(
                            since: spec.since,
                            until: spec.until,
                            preferences: prefs,
                            settings: settingsManager,
                            profiles: profiles,
                            pumpModel: devices.model,
                            supportedBasalRates: devices.rates,
                            liveProfile: self.liveTherapyProfile()
                        )
                        var batch = diabetes.records
                        let batchErrors = diabetes.errors
                        if spec.role != .historical {
                            if prefs.isOn(.loopCycles) {
                                batch.append(contentsOf: timeZoneChange(disk: disk))
                                batch.append(contentsOf: HealthIngestLoopCapture.drainStats())
                                batch.append(contentsOf: HealthIngestLoopCapture.drainProfiles())
                            }
                            batch.append(contentsOf: deletions(live: diabetes.liveIDs, disk: disk))
                            batch.append(contentsOf: HealthIngestTherapy.drain(preferences: prefs))
                        }
                        return (batch, batchErrors)
                    },
                    onHealthKitBackfill: { since in
                        health.beginBackfill(since: since, preferences: prefs)
                    },
                    enqueue: { records in
                        await enqueuePage(records)
                    },
                    beforeStoredHistory: { _ in
                        let outcome = await self.drainPriorityBeforeSlowRead(
                            queue: queue,
                            origin: origin,
                            token: token,
                            deviceID: prefs.normalizedDeviceID,
                            enqueue: { records in
                                await enqueuePage(records)
                            }
                        )
                        mark.sentAny = mark.sentAny || outcome.sentAny
                        if outcome.failed { mark.failed = true }
                        return outcome.failed || outcome.priorityRemaining
                    }
                )
                errors.append(contentsOf: readErrors)
                setLastDiabetesRead(now)
            }
            sentAny = mark.sentAny
            failed = mark.failed
            if !failed, !Task.isCancelled {
                // The historical chunk may have queued more Trio rows. Drain them
                // before any HealthKit page.
                let flush = await drainPriorityBeforeSlowRead(
                    queue: queue,
                    origin: origin,
                    token: token,
                    deviceID: prefs.normalizedDeviceID,
                    enqueue: { records in
                        await enqueuePage(records)
                    }
                )
                sentAny = sentAny || flush.sentAny
                failed = failed || flush.failed
                mark.blocked = flush.failed || flush.priorityRemaining
            }
        }
        var attemptedHealthRead = false
        var healthReadMessages: [String] = []
        if !failed, !mark.blocked, !Task.isCancelled {
            // Health reads stream page by page into their own lane. They pause while that
            // lane is backed up. Trio rows do not count toward this and are not paused by it.
            let healthGate = HealthIngestReadGate.decide(
                healthKitDepth: await queue.regularDepth(),
                priorityDepth: await queue.priorityDepth(),
                highWater: budget.backlogHighWater,
                throttled: false
            )
            if healthGate.readHealthKit {
                attemptedHealthRead = true
                if health.hasPendingBackfill(preferences: prefs) {
                    healthReadMessages.append(
                        contentsOf: await health.backfill(
                            preferences: prefs,
                            pageLimit: budget.hkPageLimit,
                            maxPages: budget.backfillPages,
                            sink: { records in
                                await enqueuePage(records, fromBackfill: true)
                            }
                        )
                    )
                }
                let locked = healthReadMessages.contains(where: HealthIngestStatus.isPausedUntilUnlock)
                if !Task.isCancelled, !locked {
                    healthReadMessages.append(
                        contentsOf: await health.incremental(
                            preferences: prefs,
                            pageLimit: budget.hkPageLimit,
                            maxPagesPerKind: budget.incrementalPages,
                            sink: { records in
                                await enqueuePage(records)
                            }
                        )
                    )
                }
            }
            if !Task.isCancelled {
                let flush = await flushReadyBatches(
                    queue: queue,
                    origin: origin,
                    token: token,
                    deviceID: prefs.normalizedDeviceID,
                    maxBatches: max(budget.flushBatches / 2, 1)
                )
                sentAny = sentAny || flush.sentAny
                failed = failed || flush.failed
            }
        }
        applyHealthReadResult(attempted: attemptedHealthRead, messages: healthReadMessages)
        if let message = errors.first {
            setLastError(message)
        }
        if sentAny {
            setLastSuccess(Date())
        }
        if !failed {
            consecutiveFailures = 0
        }
        if oversized > 0 {
            let message = "A record payload was over 128 KiB and was dropped."
            setLastError(message)
            warning(.healthKit, "Health Ingest \(message)")
        }
        storeBackfillRunning(health.hasPendingBackfill(preferences: prefs))
        let depth = await queue.depth()
        let priorityDepth = await queue.priorityDepth()
        let backfillDepth = await queue.backfillDepth()
        publishSnapshot(depth: depth, priorityDepth: priorityDepth, backfillDepth: backfillDepth)
        disk.saveStatus(HealthIngestPersistedStatus(lastSuccess: lockedSuccess(), lastError: lockedError()))
    }

    /// Returns true when the batch should stop the send loop and back off.
    private func send(
        _ batch: [HealthIngestRecord],
        origin: URL,
        token: String,
        queue: HealthIngestQueue,
        deviceID: String
    ) async -> Bool {
        let envelope = HealthIngestEnvelope(
            schemaVersion: HealthIngestWire.schemaVersion,
            device: HealthIngestDevice(
                id: deviceID,
                app: HealthIngestWire.appName,
                appVersion: HealthIngestAppVersion.current()
            ),
            records: batch
        )
        // Serialization and gzip make many temporary strings and buffers. Drain them
        // before the network wait so only the request body stays alive.
        var encoded: Data?
        var compressed: Data?
        autoreleasepool {
            encoded = try? HealthIngestWire.encodeEnvelope(envelope)
            if let encoded { compressed = HealthIngestWire.gzipIfWorthwhile(encoded) }
        }
        guard let raw = encoded else {
            setLastError("Could not encode a batch.")
            return true
        }
        let background = HealthIngestBackgroundTask()
        await background.begin()
        defer { Task { await background.end() } }

        do {
            let (code, data) = try await client.post(
                origin: origin,
                token: token,
                body: compressed ?? raw,
                gzip: compressed != nil
            )
            if code == 403 {
                noteUpload(.http(code: code, at: Date()))
                setLastError(HealthIngestStatus.deviceIdRejectedError)
                _ = await queue.resolve(batch: batch, acks: [], transportFailed: true)
                consecutiveFailures += 1
                return true
            }
            if code == 401 {
                noteUpload(.tokenRejected(at: Date()))
                setLastError(HealthIngestStatus.tokenRejectedError)
                _ = await queue.resolve(batch: batch, acks: [], transportFailed: true)
                consecutiveFailures += 1
                return true
            }
            guard code == 200 else {
                noteUpload(.http(code: code, at: Date()))
                setLastError("The server returned HTTP \(code).")
                _ = await queue.resolve(batch: batch, acks: [], transportFailed: true)
                consecutiveFailures += 1
                return true
            }
            let acks = try HealthIngestWire.parseAcks(data)
            noteUpload(.succeeded(at: Date()))
            noteAcceptedRows(HealthIngestAck.acceptedRowCount(acks))
            if let reject = await queue.resolve(batch: batch, acks: acks, transportFailed: false) {
                let message = "A record was rejected: \(String(reject.prefix(180)))"
                setLastError(message)
                warning(.healthKit, "Health Ingest \(message)")
            } else {
                setLastError(nil)
            }
            return false
        } catch let error as HealthIngestWireError where error == .unrecognizedResponse {
            setLastError("The server response was not a per-record result.")
            _ = await queue.resolve(batch: batch, acks: [], transportFailed: true)
            consecutiveFailures += 1
            return true
        } catch let error as URLError where error.code == .timedOut {
            noteUpload(.timedOut(at: Date()))
            setLastError(Self.networkMessage(error))
            _ = await queue.resolve(batch: batch, acks: [], transportFailed: true)
            consecutiveFailures += 1
            warning(.healthKit, "Health Ingest upload failed: \(Self.networkMessage(error))")
            return true
        } catch {
            noteUpload(.unreachable(at: Date()))
            setLastError(Self.networkMessage(error))
            _ = await queue.resolve(batch: batch, acks: [], transportFailed: true)
            consecutiveFailures += 1
            warning(.healthKit, "Health Ingest upload failed: \(Self.networkMessage(error))")
            return true
        }
    }

    /// Reads the live window, then one historical chunk when a Core Data rewind is
    /// in progress, and enqueues each before the next read starts. Returns read errors.
    /// `beginBackfill` runs only from `onHealthKitBackfill`.
    /// `beforeStoredHistory` runs before a historical or HealthKit-window read,
    /// after the live window is already enqueued. Return true to skip that read
    /// and leave the historical cursor where it is.
    func runScheduledDiabetesPass(
        now: Date,
        chunk: TimeInterval,
        read: (HealthIngestDiabetesSchedule.Read) async -> (records: [HealthIngestRecord], errors: [String]),
        onHealthKitBackfill: (Date) -> Void,
        enqueue: ([HealthIngestRecord]) async -> Void,
        beforeStoredHistory: ((HealthIngestDiabetesSchedule.Read) async -> Bool)? = nil
    ) async -> [String] {
        let plan = takeDiabetesPlan(now: now, chunk: chunk)
        var errors: [String] = []
        var completed = true
        var didReadHealthKitBackfill = false
        for (index, spec) in plan.reads.enumerated() {
            if spec.role != .live, let beforeStoredHistory, await beforeStoredHistory(spec) {
                completed = false
                break
            }
            let batch = await read(spec)
            errors.append(contentsOf: batch.errors)
            if spec.role == .healthKitBackfill {
                didReadHealthKitBackfill = true
                onHealthKitBackfill(spec.since)
            }
            await enqueue(batch.records)
            if index == 0, spec.role != .healthKitBackfill, let since = plan.healthKitBackfillSince {
                onHealthKitBackfill(since)
            }
        }
        if completed {
            commitDiabetesPlan(plan)
        } else if !didReadHealthKitBackfill, let spec = plan.reads.first(where: { $0.role == .healthKitBackfill }) {
            restoreBackfillRequest(spec.since)
        }
        return errors
    }

    func currentSnapshot() -> HealthIngestStatus {
        makeSnapshot(depth: 0, priorityDepth: 0)
    }

    private func takeDiabetesPlan(now: Date, chunk: TimeInterval) -> HealthIngestDiabetesSchedule.Plan {
        stateLock.lock()
        let requested = backfillSince
        let resume = diabetesResume
        let historical = historicalResume
        let success = lastSuccess
        if requested != nil { backfillSince = nil }
        stateLock.unlock()
        var plan = HealthIngestDiabetesSchedule.plan(
            now: now,
            chunk: chunk,
            lastLiveSuccess: success,
            backfillRequest: requested,
            diabetesResume: resume,
            historicalResume: historical
        )
        // A leftover single cursor would hide the live window for the rest of the rewind.
        if historical != nil, resume != nil {
            plan.persistDiabetesResume = true
            plan.diabetesResume = nil
        }
        return plan
    }

    /// `takeDiabetesPlan` consumes a backfill request. Put it back when that
    /// Core Data window was not read.
    private func restoreBackfillRequest(_ since: Date) {
        stateLock.lock()
        if backfillSince == nil {
            backfillSince = since
        }
        stateLock.unlock()
    }

    private func commitDiabetesPlan(_ plan: HealthIngestDiabetesSchedule.Plan) {
        if plan.persistDiabetesResume {
            setDiabetesResume(plan.diabetesResume)
        }
        if plan.persistHistorical {
            setHistoricalResume(plan.historicalResume)
        }
    }

    private func lockedDiabetesResume() -> Date? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return diabetesResume
    }

    private func setDiabetesResume(_ date: Date?) {
        stateLock.lock()
        diabetesResume = date
        stateLock.unlock()
        disk?.saveDiabetesResume(date)
    }

    private func setHistoricalResume(_ date: Date?) {
        stateLock.lock()
        historicalResume = date
        if date == nil {
            rewriteRowsSent = 0
            rewriteRowsSavedAt = nil
        }
        stateLock.unlock()
        disk?.saveHistoricalResume(date)
        if date == nil {
            disk?.saveRewriteRowsSent(0)
        }
    }

    private func lockedHistoricalResume() -> Date? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return historicalResume
    }

    /// NSLock is unavailable directly inside an async function.
    private func lockedActivity() -> (active: Bool, catchingUp: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (appActive, diabetesResume != nil || historicalResume != nil)
    }

    private func lockedLastDiabetesRead() -> Date? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastDiabetesRead
    }

    private func setLastDiabetesRead(_ date: Date) {
        stateLock.lock()
        lastDiabetesRead = date
        stateLock.unlock()
    }

    private func setLastError(_ message: String?) {
        stateLock.lock()
        lastError = message
        stateLock.unlock()
    }

    /// A locked-device HealthKit failure is the pause line, not a red error.
    /// A later read that is not locked clears that line. Other errors stay.
    func applyHealthReadResult(attempted: Bool, messages: [String]) {
        let real = messages.filter { !HealthIngestStatus.isPausedUntilUnlock($0) }
        let paused = messages.contains(where: HealthIngestStatus.isPausedUntilUnlock)
        stateLock.lock()
        if let message = real.first {
            lastError = message
        } else if paused {
            if lastError == nil || HealthIngestStatus.isPausedUntilUnlock(lastError) {
                lastError = HealthIngestStatus.pausedUntilUnlock
            }
        } else if attempted, HealthIngestStatus.isPausedUntilUnlock(lastError) {
            lastError = nil
        }
        stateLock.unlock()
    }

    private func setLastSuccess(_ date: Date) {
        stateLock.lock()
        lastSuccess = date
        stateLock.unlock()
        guard var check = settingsStore.loadConnection(), check.kind == .connected else { return }
        let prefs = currentPreferences()
        let url = prefs.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard check.url == url, check.deviceID == prefs.normalizedDeviceID, check.tokenRevision == settingsStore.tokenRevision() else {
            return
        }
        check.testedAt = date
        settingsStore.saveConnection(check)
    }

    /// Records the transport result for the current address and token. A later failure
    /// replaces Connected. Latency is left to `afterUpload`, which keeps it only when known.
    private func noteUpload(_ outcome: HealthIngestUploadOutcome) {
        let prefs = currentPreferences()
        let check = HealthIngestConnectionCheck.afterUpload(
            previous: settingsStore.loadConnection(),
            outcome: outcome,
            url: prefs.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            deviceID: prefs.normalizedDeviceID,
            tokenRevision: settingsStore.tokenRevision()
        )
        settingsStore.saveConnection(check)
    }

    private func storeBackfillRunning(_ running: Bool) {
        stateLock.lock()
        let startQueued = backfillSince != nil
        let hadWindow = backfillWindowStart != nil
        backfillRunning = running || startQueued
        stateLock.unlock()
        if running {
            recoverMissingBackfillWindow()
            saveActiveBackfill()
        } else if !startQueued, hadWindow {
            clearActiveBackfill()
        }
    }

    private func lockedSuccess() -> Date? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastSuccess
    }

    private func lockedError() -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastError
    }

    /// Server-accepted rows for the pass that is running now. Queued and duplicate rows are not included.
    /// The count is written at most every 30 seconds; the end of the pass flushes it as well.
    /// A Core Data rewrite keeps its own count for the same card.
    private func noteAcceptedRows(_ count: Int) {
        guard count > 0 else { return }
        stateLock.lock()
        var saveBackfill = false
        var saveRewrite = false
        let now = Date()
        if backfillRunning {
            backfillRowsSent += count
            if backfillProgressSavedAt.map({ now.timeIntervalSince($0) >= 30 }) ?? true {
                backfillProgressSavedAt = now
                saveBackfill = true
            }
        }
        if historicalResume != nil {
            rewriteRowsSent += count
            if rewriteRowsSavedAt.map({ now.timeIntervalSince($0) >= 30 }) ?? true {
                rewriteRowsSavedAt = now
                saveRewrite = true
            }
        }
        stateLock.unlock()
        if saveBackfill { saveActiveBackfill() }
        if saveRewrite { saveRewriteRows() }
    }

    private func saveRewriteRows() {
        let count = lockedRewriteRowsSent()
        disk?.saveRewriteRowsSent(count)
    }

    private func lockedRewriteRowsSent() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return rewriteRowsSent
    }

    private func restoreBackfillProgress() {
        guard let health, let disk else { return }
        let stored = disk.loadBackfillProgress()
        let prefs = currentPreferences()
        let resolved = HealthIngestBackfillRestore.resolve(
            stored: stored,
            pending: health.hasPendingBackfill(preferences: prefs),
            earliestCursor: health.oldestPendingCursor(preferences: prefs),
            now: Date()
        )
        stateLock.lock()
        backfillChosenDays = resolved.chosenDays
        backfillDayCount = resolved.active ? resolved.days : 0
        backfillWindowStart = resolved.active ? resolved.windowStart : nil
        backfillRowsSent = resolved.active ? resolved.rowsSent : 0
        if resolved.active { backfillRunning = true }
        stateLock.unlock()
        let choice = resolved.chosenDays
        Task { @MainActor [weak self] in
            self?.backfillDayChoice = choice
        }
        let record = HealthIngestPersistedBackfill(
            days: resolved.days,
            windowStart: resolved.windowStart,
            rowsSent: resolved.rowsSent,
            chosenDays: resolved.chosenDays,
            active: resolved.active
        )
        if resolved.active || stored != nil, stored != record {
            disk.saveBackfillProgress(record)
        }
    }

    private func saveActiveBackfill() {
        guard let disk else { return }
        stateLock.lock()
        let record = HealthIngestPersistedBackfill(
            days: backfillDayCount,
            windowStart: backfillWindowStart ?? Date(),
            rowsSent: backfillRowsSent,
            chosenDays: backfillChosenDays,
            active: true
        )
        backfillProgressSavedAt = Date()
        stateLock.unlock()
        disk.saveBackfillProgress(record)
    }

    private func saveBackfillChoice() {
        guard let disk else { return }
        stateLock.lock()
        let active = backfillWindowStart != nil && backfillRunning
        let record = HealthIngestPersistedBackfill(
            days: active ? backfillDayCount : 0,
            windowStart: backfillWindowStart ?? Date(timeIntervalSince1970: 0),
            rowsSent: active ? backfillRowsSent : 0,
            chosenDays: backfillChosenDays,
            active: active
        )
        stateLock.unlock()
        disk.saveBackfillProgress(record)
    }

    private func clearActiveBackfill() {
        guard let disk else { return }
        stateLock.lock()
        backfillDayCount = 0
        backfillWindowStart = nil
        backfillRowsSent = 0
        let chosen = backfillChosenDays
        stateLock.unlock()
        disk.saveBackfillProgress(
            HealthIngestPersistedBackfill(
                days: 0,
                windowStart: Date(timeIntervalSince1970: 0),
                rowsSent: 0,
                chosenDays: chosen,
                active: false
            )
        )
    }

    /// A pass can be marked running before `backfill(days:)` writes a window: cursors were
    /// restored, or a diabetes catch-up called `beginBackfill`. The earliest cursor is the
    /// same window `HealthIngestBackfillRestore` uses, not the picker's default of 7 days.
    private func recoverMissingBackfillWindow() {
        stateLock.lock()
        let running = backfillRunning
        let missing = backfillDayCount == 0 || backfillWindowStart == nil
        stateLock.unlock()
        guard running, missing, let health else { return }
        let cursor = health.oldestPendingCursor(preferences: currentPreferences())
        guard let cursor else { return }
        let recovered = HealthIngestBackfillProgress.recover(earliestCursor: cursor, now: Date())
        stateLock.lock()
        let stillMissing = backfillDayCount == 0 || backfillWindowStart == nil
        if stillMissing {
            backfillDayCount = recovered.days
            backfillWindowStart = recovered.windowStart
            backfillChosenDays = recovered.days
        }
        stateLock.unlock()
        guard stillMissing else { return }
        saveActiveBackfill()
        let choice = recovered.days
        Task { @MainActor [weak self] in
            self?.backfillDayChoice = choice
        }
    }

    private func backfillProgress(preferences: HealthIngestPreferences) -> HealthIngestBackfillProgress? {
        recoverMissingBackfillWindow()
        stateLock.lock()
        let running = backfillRunning
        let days = backfillDayCount
        let start = backfillWindowStart
        let rows = backfillRowsSent
        let resume = diabetesResume
        stateLock.unlock()
        guard running, days > 0, let start else { return nil }
        let cursor = health?.oldestPendingCursor(preferences: preferences)
        let frontier = HealthIngestBackfillProgress.frontier(start: start, cursor: cursor, resume: resume)
        return HealthIngestBackfillProgress.measure(
            start: start,
            frontier: frontier,
            days: days,
            rowsSent: rows,
            phase: "Reading Health samples"
        )
    }

    private func publishSnapshot(depth: Int, priorityDepth: Int, backfillDepth: Int = 0) {
        let snapshot = makeSnapshot(depth: depth, priorityDepth: priorityDepth, backfillDepth: backfillDepth)
        Task { @MainActor [weak self] in
            self?.status = snapshot
        }
    }

    private func makeSnapshot(depth: Int, priorityDepth: Int, backfillDepth: Int = 0) -> HealthIngestStatus {
        let prefs = currentPreferences()
        let log = disk?.loadRejectLog() ?? HealthIngestRejectLog()
        let running = lockedBackfillRunning()
        let frontier = lockedHistoricalResume()
        return HealthIngestStatus(
            lastSuccess: lockedSuccess(),
            lastError: lockedError(),
            queueDepth: depth,
            priorityDepth: priorityDepth,
            backfillDepth: backfillDepth,
            rejectedCount: log.total,
            hasToken: settingsStore.hasToken(),
            backfillRunning: running,
            latestRejectReason: log.latestReason,
            rejectGroups: log.groups(),
            backfill: running ? backfillProgress(preferences: prefs) : nil,
            rewrite: frontier.map { rewriteProgress(frontier: $0) }
        )
    }

    /// Day N of the 90-day Core Data window. The cursor is the frontier; the window is the last 90 days.
    private func rewriteProgress(frontier: Date) -> HealthIngestBackfillProgress {
        let days = HealthIngestMappingUpgrade.steps[HealthIngestWire.mappingVersion]?.rewindCoreDataDays ?? 90
        let start = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        return HealthIngestBackfillProgress.measure(
            start: start,
            frontier: frontier,
            days: days,
            rowsSent: lockedRewriteRowsSent(),
            phase: HealthIngestStatus.rewritingPhase
        )
    }

    private func lockedBackfillRunning() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return backfillRunning
    }

    /// Reads the current G7 manager, if this process has one. Pairing codes,
    /// shared keys, and Share credentials are not copied.
    private func liveCGMRecords() -> [HealthIngestRecord] {
        guard let glucose = container.resolve(FetchGlucoseManager.self),
              let manager = glucose.cgmManager as? G7CGMManager
        else { return [] }
        return HealthIngestLiveCGM.observe(HealthIngestLiveCGM.snapshot(from: manager))
    }

    /// Read-only. These are the files the loop already passes to oref.
    private func liveTherapyProfile() -> TrioTherapyProfile? {
        guard let storage = container.resolve(FileStorage.self) else { return nil }
        return HealthIngestLiveProfile.read(storage)
    }

    private func resolverDevices() -> (model: String?, rates: [Double]) {
        guard let devices = container.resolve(DeviceDataManager.self) else { return (nil, []) }
        let model = devices.pumpName.value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (model.isEmpty ? nil : model, devices.pumpManager?.supportedBasalRates ?? [])
    }

    private func timeZoneChange(disk: HealthIngestDisk) -> [HealthIngestRecord] {
        let current = TimeZone.current.identifier
        let previous = disk.loadTimeZone()
        disk.saveTimeZone(current)
        guard let previous, previous != current else { return [] }
        let now = Date()
        return [
            HealthIngestRecord(
                type: HealthIngestType.tzChange,
                id: "tz:\(HealthIngestTime.string(from: now))",
                start: now,
                end: nil,
                tz: current,
                payload: .object([
                    "from": .string(previous),
                    "to": .string(current),
                    "at": .string(HealthIngestTime.string(from: now))
                ])
            )
        ]
    }

    private func deletions(live: [String: Set<String>], disk: HealthIngestDisk) -> [HealthIngestRecord] {
        var uploaded = disk.loadUploadedIDs()
        var records: [HealthIngestRecord] = []
        let now = Date()
        for (type, current) in live {
            let known = Set(uploaded[type] ?? [])
            for id in known.subtracting(current).sorted() {
                records.append(
                    HealthIngestRecord(
                        type: HealthIngestType.deletion,
                        id: "deletion:\(type):\(id)",
                        start: now,
                        end: nil,
                        tz: HealthIngestTime.zoneIdentifier,
                        payload: .object([
                            "targetType": .string(type),
                            "targetId": .string(id),
                            "detectedAt": .string(HealthIngestTime.string(from: now)),
                            "reason": .string("removed")
                        ])
                    )
                )
            }
            uploaded[type] = Array(known.intersection(current))
        }
        disk.saveUploadedIDs(uploaded)
        return records
    }

    /// Restarts the upload loop if it exited while the service was still enabled.
    private func ensureLoopRunning() {
        if let loopTask, !loopTask.isCancelled { return }
        loopTask = Task.detached(priority: .utility) { [weak self] in
            await self?.run()
        }
    }

    private func poke() {
        if started {
            ensureLoopRunning()
        }
        Task { await wake.signal() }
    }

    private static func networkMessage(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return "Could not reach the server (code \(urlError.code.rawValue))."
        }
        return "Could not reach the server."
    }
}

extension HealthIngestUploader: SettingsObserver {
    func settingsDidChange(_: TrioSettings) { poke() }
}

extension HealthIngestUploader: PreferencesObserver {
    func preferencesDidChange(_: Preferences) { poke() }
}

struct HealthIngestClient {
    var session: URLSession

    init(session: URLSession = HealthIngestClient.makeSession()) {
        self.session = session
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    func post(origin: URL, token: String, body: Data, gzip: Bool) async throws -> (Int, Data) {
        guard let url = HealthIngestWire.endpoint(origin, path: HealthIngestWire.ingestPath) else {
            throw HealthIngestWireError.invalidOrigin
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(HealthIngestWire.authorizationValue(token: token), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if gzip {
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        }
        request.httpBody = body
        return try await perform(request)
    }

    func status(origin: URL, token: String) async throws -> Int {
        guard let url = HealthIngestWire.endpoint(origin, path: HealthIngestWire.statusPath) else {
            throw HealthIngestWireError.invalidOrigin
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(HealthIngestWire.authorizationValue(token: token), forHTTPHeaderField: "Authorization")
        let (code, _) = try await perform(request)
        return code
    }

    private func perform(_ request: URLRequest) async throws -> (Int, Data) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (http.statusCode, data)
    }
}

private final class HealthIngestBackgroundTask {
    private var id: UIBackgroundTaskIdentifier = .invalid

    @MainActor func begin() {
        guard id == .invalid else { return }
        id = UIApplication.shared.beginBackgroundTask(withName: "HealthIngest") { [weak self] in
            Task { @MainActor in self?.end() }
        }
    }

    @MainActor func end() {
        guard id != .invalid else { return }
        let ending = id
        id = .invalid
        UIApplication.shared.endBackgroundTask(ending)
    }
}

private actor HealthIngestWake {
    private var generation = 0

    func signal() { generation += 1 }

    func current() -> Int { generation }

    func wait(seconds: TimeInterval) async {
        let start = generation
        let steps = max(Int(seconds * 2), 1)
        for _ in 0 ..< steps {
            if Task.isCancelled || generation != start { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }
}
