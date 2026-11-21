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
    var failures: Int
    var rejects: Int
    var notBefore: Date
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

    func loadUploadedIDs() -> [String] {
        load([String].self, name: "uploaded-ids.json") ?? []
    }

    func saveUploadedIDs(_ ids: [String]) {
        save(ids, name: "uploaded-ids.json")
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

    func loadDeviceID() -> String {
        if let existing = load(String.self, name: "device-id.json"), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        save(created, name: "device-id.json")
        return created
    }

    func loadStatus() -> HealthIngestPersistedStatus {
        load(HealthIngestPersistedStatus.self, name: "status.json") ?? HealthIngestPersistedStatus()
    }

    func saveStatus(_ status: HealthIngestPersistedStatus) {
        save(status, name: "status.json")
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
    private var pendingIDs: Set<String>
    private var uploadedOrder: [String]
    private var uploadedSet: Set<String>
    private let uploadedCap = 30_000
    private let rejectLimit = 5

    init(disk: HealthIngestDisk) {
        self.disk = disk
        items = disk.loadQueue()
        pendingIDs = Set(items.map(\.record.id))
        uploadedOrder = disk.loadUploadedIDs()
        uploadedSet = Set(uploadedOrder)
    }

    func enqueue(_ records: [HealthIngestRecord]) -> Int {
        var added = 0
        let now = Date()
        for record in records {
            guard !pendingIDs.contains(record.id), !uploadedSet.contains(record.id) else { continue }
            let bytes = (try? HealthIngestWire.encode(record).count) ?? 0
            guard bytes > 0 else { continue }
            items.append(
                HealthIngestQueuedRecord(
                    record: record,
                    bytes: bytes,
                    failures: 0,
                    rejects: 0,
                    notBefore: now
                )
            )
            pendingIDs.insert(record.id)
            added += 1
        }
        if added > 0 {
            disk.saveQueue(items)
        }
        return added
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

    func hasReady() -> Bool {
        let now = Date()
        return items.contains { $0.notBefore <= now }
    }

    /// Duplicates are success. Rejected records stay for a few attempts, then leave the queue
    /// so one bad record cannot block the rest. Transport failures keep every record.
    func resolve(
        batchIDs: [String],
        acks: [HealthIngestAck],
        transportFailed: Bool
    ) -> String? {
        if transportFailed {
            let delay = HealthIngestBackoff.delay(afterFailures: bumpFailures(batchIDs))
            postpone(batchIDs, until: Date().addingTimeInterval(delay))
            disk.saveQueue(items)
            return nil
        }

        var byID: [String: HealthIngestAck] = [:]
        for ack in acks { byID[ack.id] = ack }

        var lastReject: String?
        var remove: Set<String> = []
        var postponeIDs: [String] = []
        for id in batchIDs {
            guard let index = items.firstIndex(where: { $0.record.id == id }) else { continue }
            guard let ack = byID[id] else {
                postponeIDs.append(id)
                continue
            }
            switch ack.status {
            case .accepted,
                 .duplicate:
                remove.insert(id)
                rememberUploaded(id)
            case .rejected:
                items[index].rejects += 1
                let reason = ack.reason ?? "rejected"
                lastReject = reason
                if items[index].rejects >= rejectLimit {
                    remove.insert(id)
                } else {
                    let delay = HealthIngestBackoff.delay(afterFailures: items[index].rejects)
                    items[index].notBefore = Date().addingTimeInterval(delay)
                }
            }
        }
        if !postponeIDs.isEmpty {
            let delay = HealthIngestBackoff.delay(afterFailures: 1)
            postpone(postponeIDs, until: Date().addingTimeInterval(delay))
        }
        if !remove.isEmpty {
            items.removeAll { remove.contains($0.record.id) }
            pendingIDs.subtract(remove)
        }
        disk.saveQueue(items)
        disk.saveUploadedIDs(uploadedOrder)
        return lastReject
    }

    private func bumpFailures(_ ids: [String]) -> Int {
        var maxFailures = 1
        for index in items.indices where ids.contains(items[index].record.id) {
            items[index].failures += 1
            maxFailures = max(maxFailures, items[index].failures)
        }
        return maxFailures
    }

    private func postpone(_ ids: [String], until date: Date) {
        let idSet = Set(ids)
        for index in items.indices where idSet.contains(items[index].record.id) {
            items[index].notBefore = date
        }
    }

    private func rememberUploaded(_ id: String) {
        guard uploadedSet.insert(id).inserted else { return }
        uploadedOrder.append(id)
        if uploadedOrder.count > uploadedCap {
            let drop = uploadedOrder.count - uploadedCap
            for removed in uploadedOrder.prefix(drop) {
                uploadedSet.remove(removed)
            }
            uploadedOrder.removeFirst(drop)
        }
    }
}
