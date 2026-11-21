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
    private let client = HealthIngestClient()
    private let wake = HealthIngestWake()
    private var loopTask: Task<Void, Never>?
    private var contentCancellable: AnyCancellable?
    private var started = false
    private let adapter = HealthIngestDiabetesAdapter()

    init(resolver: Resolver) {
        injectServices(resolver)
        settingsStore = HealthIngestSettingsStore(keychain: keychain)
        let loaded = settingsStore.load()
        storedPreferences = loaded
        preferences = loaded
        status.hasToken = settingsStore.hasToken()
        if loaded.enabled {
            start()
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

    private func commit(_ incoming: HealthIngestPreferences) {
        var prefs = incoming
        prefs.deviceID = prefs.normalizedDeviceID
        stateLock.lock()
        storedPreferences = prefs
        stateLock.unlock()
        settingsStore.save(prefs)
        preferences = prefs
        if prefs.enabled {
            start()
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

    private func start() {
        if started {
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
        stateLock.unlock()
        return queue
    }

    private func run() async {
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
        if pendingBackfill || ready { return 5 }
        return 90
    }

    private func collectAndSend() async {
        guard let queue = try? prepare(), let disk, let health else { return }
        let prefs = currentPreferences()
        guard let origin = HealthIngestOrigin.parse(prefs.baseURL), let token = settingsStore.token() else { return }

        let since = takeSince()
        let diabetes = await adapter.records(
            since: since.date,
            preferences: prefs,
            settings: settingsManager,
            profiles: profiles
        )
        if since.backfill {
            health.beginBackfill(since: since.date, preferences: prefs)
        }
        var healthResult = HealthIngestReadResult()
        if health.hasPendingBackfill(preferences: prefs) {
            healthResult = await health.backfill(preferences: prefs)
        }
        let incremental = await health.incremental(preferences: prefs)
        let added = await queue.enqueue(diabetes.records + healthResult.records + incremental.records)
        if added.queued > 0 {
            debug(.healthKit, "Health Ingest queued \(added.queued) records")
        }
        if let message = (diabetes.errors + healthResult.errors + incremental.errors).first {
            setLastError(message)
        }

        var sentAny = false
        var failed = false
        var batches = 0
        while batches < 4, !Task.isCancelled {
            let batch = await queue.nextBatch(
                limit: HealthIngestWire.maxBatchRecords,
                maxBytes: HealthIngestWire.maxBatchBytes
            )
            if batch.isEmpty { break }
            let outcome = await send(batch, origin: origin, token: token, queue: queue, deviceID: prefs.normalizedDeviceID)
            batches += 1
            if outcome {
                failed = true
                break
            }
            sentAny = true
        }
        if sentAny {
            setLastSuccess(Date())
        }
        if !failed {
            consecutiveFailures = 0
        }
        if added.oversized > 0 {
            let message = "A record payload was over 128 KiB and was dropped."
            setLastError(message)
            warning(.healthKit, "Health Ingest \(message)")
        }
        stateLock.lock()
        backfillRunning = health.hasPendingBackfill(preferences: prefs)
        stateLock.unlock()
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
        guard let raw = try? HealthIngestWire.encodeEnvelope(envelope) else {
            setLastError("Could not encode a batch.")
            return true
        }
        let compressed = HealthIngestWire.gzipIfWorthwhile(raw)
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
            return (requested, true)
        }
        // 36 hours covers a normal gap. If the last success is older, catch up from there.
        // Trio deletes most history after 90 days, so there is nothing useful past that.
        let regular = Date().addingTimeInterval(-36 * 3600)
        let catchUp = lastSuccess?.addingTimeInterval(-6 * 3600) ?? regular
        let oldest = Date().addingTimeInterval(-90 * 24 * 3600)
        return (max(oldest, min(regular, catchUp)), false)
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

    private func poke() {
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
