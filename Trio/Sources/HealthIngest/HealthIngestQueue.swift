import Foundation

enum HealthIngestBackoff {
    /// 30s, 60s, 120s, 240s, 480s, then 15 minutes.
    static func delay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let shift = min(failures - 1, 5)
        return min(30 * pow(2.0, Double(shift)), 15 * 60)
    }
}

struct HealthIngestQueuedRecord: Codable, Equatable {
    var record: HealthIngestRecord
    var bytes: Int
    var hash: String
    var failures: Int
    var notBefore: Date
}

struct HealthIngestReceipt: Codable, Equatable {
    enum State: String, Codable {
        case accepted
        case rejected
    }

    var key: String
    var hash: String
    var state: State
    var at: Date
}

struct HealthIngestEnqueueResult: Equatable {
    var queued: Int
    var oversized: Int
}

struct HealthIngestPersistedStatus: Codable, Equatable {
    var lastSuccess: Date?
    var lastError: String?
}

/// On-disk queue, uploaded-id log, and HealthKit anchors. Writes are atomic and survive relaunch.
final class HealthIngestDisk {
    let directory: URL
    private let lock = NSLock()
    private let encoder = HealthIngestWire.makeEncoder()
    private let decoder = HealthIngestWire.makeDecoder()

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func makeDefault() throws -> HealthIngestDisk {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return try HealthIngestDisk(directory: base.appendingPathComponent("HealthIngest", isDirectory: true))
    }

    func loadQueue() -> [HealthIngestQueuedRecord] {
        load([HealthIngestQueuedRecord].self, name: "queue.json") ?? []
    }

    func saveQueue(_ items: [HealthIngestQueuedRecord]) {
        save(items, name: "queue.json")
    }

    func loadReceipts() -> [HealthIngestReceipt] {
        load([HealthIngestReceipt].self, name: "receipts.json") ?? []
    }

    func saveReceipts(_ receipts: [HealthIngestReceipt]) {
        save(receipts, name: "receipts.json")
    }

    func loadAnchors() -> [String: Data] {
        guard let stored = load([String: String].self, name: "anchors.json") else { return [:] }
        var anchors: [String: Data] = [:]
        for (key, value) in stored {
            if let data = Data(base64Encoded: value) {
                anchors[key] = data
            }
        }
        return anchors
    }

    func saveAnchors(_ anchors: [String: Data]) {
        let stored = anchors.mapValues { $0.base64EncodedString() }
        save(stored, name: "anchors.json")
    }

    func loadCursors() -> [String: Date] {
        load([String: Date].self, name: "cursors.json") ?? [:]
    }

    func saveCursors(_ cursors: [String: Date]) {
        save(cursors, name: "cursors.json")
    }

    func loadStatus() -> HealthIngestPersistedStatus {
        load(HealthIngestPersistedStatus.self, name: "status.json") ?? HealthIngestPersistedStatus()
    }

    func saveStatus(_ status: HealthIngestPersistedStatus) {
        save(status, name: "status.json")
    }

    func loadFirstSeen() -> [String: Date] {
        load([String: Date].self, name: "first-seen.json") ?? [:]
    }

    func saveFirstSeen(_ seen: [String: Date]) {
        save(seen, name: "first-seen.json")
    }

    /// Ids the server has accepted, keyed by record type. Missing keys were not scanned.
    func loadUploadedIDs() -> [String: [String]] {
        load([String: [String]].self, name: "uploaded-ids.json") ?? [:]
    }

    func saveUploadedIDs(_ ids: [String: [String]]) {
        save(ids, name: "uploaded-ids.json")
    }

    func loadRejectedCount() -> Int {
        load(Int.self, name: "rejected-count.json") ?? 0
    }

    func saveRejectedCount(_ count: Int) {
        save(count, name: "rejected-count.json")
    }

    func loadTimeZone() -> String? {
        load(String.self, name: "timezone.json")
    }

    func saveTimeZone(_ identifier: String) {
        save(identifier, name: "timezone.json")
    }

    private func load<T: Decodable>(_ type: T.Type, name: String) -> T? {
        lock.lock()
        defer { lock.unlock() }
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func save(_ value: some Encodable, name: String) {
        lock.lock()
        defer { lock.unlock() }
        let url = directory.appendingPathComponent(name)
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

actor HealthIngestQueue {
    private let disk: HealthIngestDisk
    private var items: [HealthIngestQueuedRecord]
    private var receipts: [HealthIngestReceipt]
    private var firstSeen: [String: Date]
    private let receiptCap = 30_000
    private let snapshotInterval: TimeInterval = 24 * 3600

    init(disk: HealthIngestDisk) {
        self.disk = disk
        items = disk.loadQueue()
        receipts = disk.loadReceipts()
        firstSeen = disk.loadFirstSeen()
    }

    /// Same `(type, id)` is reused. A changed payload replaces a pending row and is sent again
    /// after a previous accept. An unchanged snapshot is sent again once a day.
    func enqueue(_ records: [HealthIngestRecord], now: Date = Date()) -> HealthIngestEnqueueResult {
        var queued = 0
        var oversized = 0
        var changed = false
        for incoming in records {
            var record = incoming
            if HealthIngestType.contentAddressed.contains(record.type) {
                if let seen = firstSeen[record.id] {
                    record.start = seen
                } else {
                    firstSeen[record.id] = record.start
                    disk.saveFirstSeen(firstSeen)
                }
            }
            let payloadBytes = HealthIngestWire.payloadByteCount(record.payload)
            if payloadBytes > HealthIngestWire.maxPayloadBytes {
                oversized += 1
                continue
            }
            let hash = HealthIngestWire.payloadHash(record.payload)
            let key = Self.key(record)
            if let index = items.firstIndex(where: { Self.key($0.record) == key }) {
                guard items[index].hash != hash else { continue }
                let bytes = (try? HealthIngestWire.encode(record).count) ?? payloadBytes
                items[index].record = record
                items[index].bytes = bytes
                items[index].hash = hash
                items[index].notBefore = now
                queued += 1
                changed = true
                continue
            }
            if let receipt = receipts.last(where: { $0.key == key }), receipt.hash == hash {
                let daily = Self.isSnapshot(record.type) && receipt.state == .accepted &&
                    now.timeIntervalSince(receipt.at) >= snapshotInterval
                guard daily else { continue }
            }
            let bytes = (try? HealthIngestWire.encode(record).count) ?? payloadBytes
            guard bytes > 0 else { continue }
            items.append(
                HealthIngestQueuedRecord(
                    record: record,
                    bytes: bytes,
                    hash: hash,
                    failures: 0,
                    notBefore: now
                )
            )
            queued += 1
            changed = true
        }
        if changed {
            disk.saveQueue(items)
        }
        return HealthIngestEnqueueResult(queued: queued, oversized: oversized)
    }

    func nextBatch(limit: Int, maxBytes: Int) -> [HealthIngestRecord] {
        let now = Date()
        var batch: [HealthIngestRecord] = []
        var bytes = 0
        for item in items where item.notBefore <= now {
            if !batch.isEmpty, bytes + item.bytes > maxBytes || batch.count >= limit {
                break
            }
            batch.append(item.record)
            bytes += item.bytes
            if batch.count >= limit || bytes >= maxBytes {
                break
            }
        }
        return batch
    }

    func depth() -> Int { items.count }

    func rejectedCount() -> Int { disk.loadRejectedCount() }

    /// Remember ids the server accepted so a later disappearance can become a deletion.
    func noteUploaded(_ records: [HealthIngestRecord]) {
        let tracked: Set<String> = [
            HealthIngestType.glucose,
            HealthIngestType.carbs,
            HealthIngestType.bolus,
            HealthIngestType.smb,
            HealthIngestType.tempBasal,
            HealthIngestType.pumpEvent
        ]
        var stored = disk.loadUploadedIDs()
        var changed = false
        for record in records where tracked.contains(record.type) {
            var ids = stored[record.type] ?? []
            if !ids.contains(record.id) {
                ids.append(record.id)
                stored[record.type] = ids
                changed = true
            }
        }
        if changed { disk.saveUploadedIDs(stored) }
    }

    func hasReady() -> Bool {
        let now = Date()
        return items.contains { $0.notBefore <= now }
    }

    /// Accepted and duplicate are done. A rejection stays on the queue and is sent again later.
    /// A timeout keeps the records and resends the same ids.
    func resolve(
        batch: [HealthIngestRecord],
        acks: [HealthIngestAck],
        transportFailed: Bool,
        now: Date = Date()
    ) -> String? {
        let keys = batch.map { Self.key($0) }
        if transportFailed {
            let delay = HealthIngestBackoff.delay(afterFailures: bumpFailures(keys))
            postpone(keys, until: now.addingTimeInterval(delay))
            disk.saveQueue(items)
            return nil
        }

        var byKey: [String: HealthIngestAck] = [:]
        for ack in acks { byKey[Self.key(type: ack.type, id: ack.id)] = ack }

        var lastReject: String?
        var remove: Set<String> = []
        var accepted: [HealthIngestRecord] = []
        var postponeKeys: [String] = []
        for record in batch {
            let key = Self.key(record)
            guard let index = items.firstIndex(where: { Self.key($0.record) == key }) else { continue }
            guard let ack = byKey[key] else {
                postponeKeys.append(key)
                continue
            }
            switch ack.status {
            case .accepted,
                 .duplicate:
                remove.insert(key)
                accepted.append(record)
                remember(key: key, hash: items[index].hash, state: .accepted, at: now)
            case .rejected:
                let reason = ack.reason ?? "rejected"
                lastReject = "\(ack.type) \(ack.id): \(reason)"
                postponeKeys.append(key)
                disk.saveRejectedCount(disk.loadRejectedCount() + 1)
            }
        }
        if !postponeKeys.isEmpty {
            postpone(postponeKeys, until: now.addingTimeInterval(HealthIngestBackoff.delay(afterFailures: 1)))
        }
        if !remove.isEmpty {
            items.removeAll { remove.contains(Self.key($0.record)) }
        }
        if !accepted.isEmpty {
            noteUploaded(accepted)
        }
        disk.saveQueue(items)
        disk.saveReceipts(receipts)
        return lastReject
    }

    private static func key(_ record: HealthIngestRecord) -> String {
        key(type: record.type, id: record.id)
    }

    private static func key(type: String, id: String) -> String {
        "\(type)\n\(id)"
    }

    private static func isSnapshot(_ type: String) -> Bool {
        HealthIngestType.contentAddressed.contains(type)
    }

    private func bumpFailures(_ keys: [String]) -> Int {
        let keySet = Set(keys)
        var maxFailures = 1
        for index in items.indices where keySet.contains(Self.key(items[index].record)) {
            items[index].failures += 1
            maxFailures = max(maxFailures, items[index].failures)
        }
        return maxFailures
    }

    private func postpone(_ keys: [String], until date: Date) {
        let keySet = Set(keys)
        for index in items.indices where keySet.contains(Self.key(items[index].record)) {
            items[index].notBefore = date
        }
    }

    private func remember(key: String, hash: String, state: HealthIngestReceipt.State, at: Date) {
        receipts.removeAll { $0.key == key }
        receipts.append(HealthIngestReceipt(key: key, hash: hash, state: state, at: at))
        if receipts.count > receiptCap {
            receipts.removeFirst(receipts.count - receiptCap)
        }
    }
}
