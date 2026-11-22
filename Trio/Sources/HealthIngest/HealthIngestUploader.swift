import Combine
import Foundation
import HealthKit
import Swinject
import UIKit

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
    private var lastDiabetesRead: Date?
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
            backlogHighWater: 6_000,
            diabetesChunk: 2 * 24 * 3600,
            minDiabetesInterval: 0
        )
        static let background = Budget(
            hkPageLimit: 250,
            backfillPages: 1,
            incrementalPages: 1,
            flushBatches: 2,
            backlogHighWater: 1_500,
            diabetesChunk: 24 * 3600,
            minDiabetesInterval: 600
        )
    }

    init(resolver: Resolver) {
        container = resolver
        injectServices(resolver)
        settingsStore = HealthIngestSettingsStore(keychain: keychain)
        let loaded = settingsStore.load()
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
        status.hasToken = settingsStore.hasToken()
        poke()
    }

    @MainActor func clearToken() {
        settingsStore.setToken("")
        status.hasToken = false
    }

    @MainActor func testConnection(baseURL: String, deviceID: String) async -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var prefs = currentPreferences()
        prefs.baseURL = trimmed
        prefs.deviceID = deviceID
        commit(prefs)
        guard let origin = HealthIngestOrigin.parse(trimmed) else {
            return "Enter an https URL, for example https://example.ts.net."
        }
        guard let token = settingsStore.token() else {
            return "Save a token first. It stays in the Keychain."
        }
        do {
            let code = try await client.status(origin: origin, token: token)
            if (200 ... 299).contains(code) {
                return "Connected (HTTP \(code))."
            }
            return "The server returned HTTP \(code)."
        } catch {
            return Self.networkMessage(error)
        }
    }

    @MainActor func backfill(days: Int) {
        guard currentPreferences().enabled else { return }
        let bounded = min(max(days, 1), 90)
        let since = Date().addingTimeInterval(-Double(bounded) * 24 * 3600)
        stateLock.lock()
        backfillSince = min(backfillSince ?? since, since)
        backfillRunning = true
        stateLock.unlock()
        poke()
        publishSnapshot(depth: status.queueDepth)
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
        await queue.dropTypes(HealthIngestType.healthKitTypes)
        health.resetBackfillCursors()
        disk.saveMappingVersion(HealthIngestWire.mappingVersion)
        let depth = await queue.depth()
        await MainActor.run { [weak self] in
            guard let self else { return }
            self.publishSnapshot(depth: depth)
            self.backfill(days: days)
        }
    }

    private func applyMappingUpgradeIfNeeded() async {
        guard let queue = try? prepare(), let health, let disk else { return }
        guard disk.loadMappingVersion() < HealthIngestWire.mappingVersion else { return }
        await queue.forgetRejectedReceipts()
        await queue.dropTypes(HealthIngestType.healthKitTypes)
        health.resetBackfillCursors()
        disk.saveMappingVersion(HealthIngestWire.mappingVersion)
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
        do {
            _ = try prepare()
        } catch {
            stateLock.lock()
            lastError = "Could not open the on-device queue."
            stateLock.unlock()
            publishSnapshot(depth: 0)
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
        stateLock.unlock()
        return queue
    }

    private func run() async {
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

    private struct FlushOutcome {
        var sentAny: Bool
        var failed: Bool
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

        func enqueuePage(_ records: [HealthIngestRecord]) async {
            let added = await queue.enqueue(records)
            oversized += added.oversized
            if added.queued > 0 {
                debug(.healthKit, "Health Ingest queued \(added.queued) records")
            }
        }

        if !failed, !Task.isCancelled {
            let backlog = await queue.depth()
            let now = Date()
            let catchingUp = lockedDiabetesResume() != nil
            let throttled = budget.minDiabetesInterval > 0
                && (lockedLastDiabetesRead().map { now.timeIntervalSince($0) < budget.minDiabetesInterval } ?? false)
            let backedUp = catchingUp && backlog >= budget.backlogHighWater
            if !throttled, !backedUp {
                let since = takeSince()
                // A long catch-up or backfill is read one window at a time, not as one fetch.
                let until = windowEnd(from: since.date, chunk: budget.diabetesChunk)
                let devices = resolverDevices()
                let diabetes = await adapter.records(
                    since: since.date,
                    until: until,
                    preferences: prefs,
                    settings: settingsManager,
                    profiles: profiles,
                    pumpModel: devices.model,
                    supportedBasalRates: devices.rates
                )
                errors.append(contentsOf: diabetes.errors)
                var extra: [HealthIngestRecord] = []
                if prefs.isOn(.loopCycles) {
                    extra.append(contentsOf: timeZoneChange(disk: disk))
                    extra.append(contentsOf: HealthIngestLoopCapture.drainStats())
                    extra.append(contentsOf: HealthIngestLoopCapture.drainProfiles())
                }
                extra.append(contentsOf: deletions(live: diabetes.liveIDs, disk: disk))
                if since.backfill {
                    health.beginBackfill(since: since.date, preferences: prefs)
                }
                await enqueuePage(diabetes.records + extra)
                setDiabetesResume(until)
                setLastDiabetesRead(now)
            }
            if !Task.isCancelled {
                let flush = await flushReadyBatches(
                    queue: queue,
                    origin: origin,
                    token: token,
                    deviceID: prefs.normalizedDeviceID,
                    maxBatches: budget.flushBatches
                )
                sentAny = sentAny || flush.sentAny
                failed = failed || flush.failed
            }
        }
        if !failed, !Task.isCancelled {
            // Health reads stream page by page into the queue. They pause while the queue is
            // backed up, so a long backfill cannot outrun the uploads.
            if await queue.depth() < budget.backlogHighWater {
                if health.hasPendingBackfill(preferences: prefs) {
                    errors.append(
                        contentsOf: await health.backfill(
                            preferences: prefs,
                            pageLimit: budget.hkPageLimit,
                            maxPages: budget.backfillPages,
                            sink: enqueuePage
                        )
                    )
                }
                if !Task.isCancelled {
                    errors.append(
                        contentsOf: await health.incremental(
                            preferences: prefs,
                            pageLimit: budget.hkPageLimit,
                            maxPagesPerKind: budget.incrementalPages,
                            sink: enqueuePage
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
        publishSnapshot(depth: depth)
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
                setLastError("The server returned 403. The device id must match the token's device id.")
                _ = await queue.resolve(batch: batch, acks: [], transportFailed: true)
                consecutiveFailures += 1
                return true
            }
            if code == 401 {
                setLastError("The server rejected the token (HTTP 401).")
                _ = await queue.resolve(batch: batch, acks: [], transportFailed: true)
                consecutiveFailures += 1
                return true
            }
            guard code == 200 else {
                setLastError("The server returned HTTP \(code).")
                _ = await queue.resolve(batch: batch, acks: [], transportFailed: true)
                consecutiveFailures += 1
                return true
            }
            let acks = try HealthIngestWire.parseAcks(data)
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
        } catch {
            setLastError(Self.networkMessage(error))
            _ = await queue.resolve(batch: batch, acks: [], transportFailed: true)
            consecutiveFailures += 1
            warning(.healthKit, "Health Ingest upload failed: \(Self.networkMessage(error))")
            return true
        }
    }

    private func takeSince() -> (date: Date, backfill: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let requested = backfillSince {
            backfillSince = nil
            diabetesResume = nil
            return (requested, true)
        }
        if let resume = diabetesResume {
            diabetesResume = nil
            return (resume, false)
        }
        // 36 hours covers a normal gap. If the last success is older, catch up from there.
        // Trio deletes most history after 90 days, so there is nothing useful past that.
        let regular = Date().addingTimeInterval(-36 * 3600)
        let catchUp = lastSuccess?.addingTimeInterval(-6 * 3600) ?? regular
        let oldest = Date().addingTimeInterval(-90 * 24 * 3600)
        return (max(oldest, min(regular, catchUp)), false)
    }

    /// End of the window to read now, or nil when the window reaches the present.
    private func windowEnd(from start: Date, chunk: TimeInterval) -> Date? {
        let end = start.addingTimeInterval(chunk)
        return end < Date().addingTimeInterval(-60) ? end : nil
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

    /// NSLock is unavailable directly inside an async function.
    private func lockedActivity() -> (active: Bool, catchingUp: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (appActive, diabetesResume != nil)
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

    private func setLastSuccess(_ date: Date) {
        stateLock.lock()
        lastSuccess = date
        stateLock.unlock()
    }

    private func storeBackfillRunning(_ running: Bool) {
        stateLock.lock()
        backfillRunning = running
        stateLock.unlock()
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

    private func publishSnapshot(depth: Int) {
        let snapshot = HealthIngestStatus(
            lastSuccess: lockedSuccess(),
            lastError: lockedError(),
            queueDepth: depth,
            rejectedCount: disk?.loadRejectedCount() ?? 0,
            hasToken: settingsStore.hasToken(),
            backfillRunning: {
                stateLock.lock()
                defer { stateLock.unlock() }
                return backfillRunning
            }()
        )
        Task { @MainActor [weak self] in
            self?.status = snapshot
        }
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
