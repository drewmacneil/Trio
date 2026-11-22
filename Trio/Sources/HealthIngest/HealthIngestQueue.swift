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

struct HealthIngestSpillSegment: Codable, Equatable {
    var id: Int
    var count: Int
}

struct HealthIngestSpillManifest: Codable, Equatable {
    /// Oldest first.
    var segments: [HealthIngestSpillSegment] = []
    var nextID = 1

    var count: Int { segments.reduce(0) { $0 + $1.count } }
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

    /// Records beyond the in-memory window live in small segment files of at most
    /// `HealthIngestQueue.segmentSize` rows each, so memory and every rewrite stay bounded.
    func loadSpillManifest() -> HealthIngestSpillManifest {
        load(HealthIngestSpillManifest.self, name: "queue-spill.json") ?? HealthIngestSpillManifest()
    }

    func saveSpillManifest(_ manifest: HealthIngestSpillManifest) {
        save(manifest, name: "queue-spill.json")
    }

    func loadSpillSegment(_ id: Int) -> [HealthIngestQueuedRecord] {
        load([HealthIngestQueuedRecord].self, name: "queue-spill-\(id).json") ?? []
    }

    func saveSpillSegment(_ id: Int, _ items: [HealthIngestQueuedRecord]) {
        save(items, name: "queue-spill-\(id).json")
    }

    func deleteSpillSegment(_ id: Int) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("queue-spill-\(id).json"))
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

    /// Where a long catch-up read stopped, so a relaunch continues instead of skipping the gap.
    func loadDiabetesResume() -> Date? {
        load([String: Date].self, name: "diabetes-resume.json")?["resume"]
    }

    func saveDiabetesResume(_ date: Date?) {
        save(date.map { ["resume": $0] } ?? [:], name: "diabetes-resume.json")
    }

    func loadMappingVersion() -> Int {
        load(Int.self, name: "mapping-version.json") ?? 0
    }

    func saveMappingVersion(_ version: Int) {
        save(version, name: "mapping-version.json")
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
    /// Rows kept in memory and in `queue.json`. Anything beyond this goes to spill segments.
    static let windowCap = 1_000
    static let segmentSize = 500

    private let disk: HealthIngestDisk
    private var items: [HealthIngestQueuedRecord]
    private var windowKeys: Set<String>
    private var spill: HealthIngestSpillManifest
    private var receipts: [HealthIngestReceipt]
    private var receiptByKey: [String: HealthIngestReceipt]
    private var firstSeen: [String: Date]
    /// Accepted receipts stay so deletions can be detected. Rejected receipts
    /// only need to prevent an immediate resend; a large rejected set made
    /// `receipts.json` expensive to decode at launch.
    private let receiptCap = 4_000
    private let rejectedReceiptCap = 2_000
    private let snapshotInterval: TimeInterval = 24 * 3600

    init(disk: HealthIngestDisk) {
        self.disk = disk
        var window = disk.loadQueue()
        var manifest = disk.loadSpillManifest()
        // A queue file written before spill segments existed can hold tens of thousands
        // of rows. Move the excess to segments once so memory is bounded from here on.
        if window.count > Self.windowCap {
            let excess = Array(window[Self.windowCap...])
            window = Array(window[..<Self.windowCap])
            var start = 0
            while start < excess.count {
                let end = min(start + Self.segmentSize, excess.count)
                let chunk = Array(excess[start ..< end])
                disk.saveSpillSegment(manifest.nextID, chunk)
                manifest.segments.append(HealthIngestSpillSegment(id: manifest.nextID, count: chunk.count))
                manifest.nextID += 1
                start = end
            }
            disk.saveSpillManifest(manifest)
            disk.saveQueue(window)
        }
        // Pull the oldest segments back in until the window is half full.
        while window.count < Self.windowCap / 2, let first = manifest.segments.first {
            window.append(contentsOf: disk.loadSpillSegment(first.id))
            manifest.segments.removeFirst()
            disk.saveQueue(window)
            disk.saveSpillManifest(manifest)
            disk.deleteSpillSegment(first.id)
        }
        items = window
        windowKeys = Set(window.map { Self.key($0.record) })
        spill = manifest
        let stored = disk.loadReceipts()
        receipts = stored
        receiptByKey = Dictionary(stored.map { ($0.key, $0) }, uniquingKeysWith: { _, new in new })
        firstSeen = disk.loadFirstSeen()
    }

    /// Same `(type, id)` is reused. A changed payload replaces a pending row and is sent again
    /// after a previous accept. An unchanged snapshot is sent again once a day.
    /// Callers pass at most a few hundred records at a time. Rows beyond the memory window are
    /// written to spill segments, so a large backfill never grows the in-memory queue.
    func enqueue(_ records: [HealthIngestRecord], now: Date = Date()) -> HealthIngestEnqueueResult {
        var queued = 0
        var oversized = 0
        var changed = false
        var overflow: [HealthIngestQueuedRecord] = []
        var firstSeenChanged = false
        for incoming in records {
            var record = incoming
            if HealthIngestType.contentAddressed.contains(record.type) {
                if let seen = firstSeen[record.id] {
                    record.start = seen
                } else {
                    firstSeen[record.id] = record.start
                    firstSeenChanged = true
                }
            }
            // One canonical serialization feeds both the size check and the hash.
            let canonical = HealthIngestCanonicalJSON.string(record.payload)
            let payloadBytes = canonical.utf8.count
            if payloadBytes > HealthIngestWire.maxPayloadBytes {
                oversized += 1
                continue
            }
            let hash = HealthIngestCanonicalJSON.digest(canonical: canonical)
            let key = Self.key(record)
            let bytes = Self.estimatedBytes(record, payloadBytes: payloadBytes)
            if windowKeys.contains(key), let index = items.firstIndex(where: { Self.key($0.record) == key }) {
                guard items[index].hash != hash else { continue }
                items[index].record = record
                items[index].bytes = bytes
                items[index].hash = hash
                items[index].notBefore = now
                queued += 1
                changed = true
                continue
            }
            if let receipt = receiptByKey[key], receipt.hash == hash {
                let daily = Self.isSnapshot(record.type) && receipt.state == .accepted &&
                    now.timeIntervalSince(receipt.at) >= snapshotInterval
                guard daily else { continue }
            }
            guard bytes > 0 else { continue }
            let row = HealthIngestQueuedRecord(
                record: record,
                bytes: bytes,
                hash: hash,
                failures: 0,
                notBefore: now
            )
            if items.count < Self.windowCap {
                items.append(row)
                windowKeys.insert(key)
                changed = true
            } else {
                // A repeat of a spilled row is harmless: the server upserts by (type, id).
                overflow.append(row)
            }
            queued += 1
        }
        if firstSeenChanged {
            disk.saveFirstSeen(firstSeen)
        }
        if changed {
            disk.saveQueue(items)
        }
        if !overflow.isEmpty {
            writeSpill(overflow)
        }
        return HealthIngestEnqueueResult(queued: queued, oversized: oversized)
    }

    /// Serialized size is only used to cap a batch, so a cheap estimate is enough.
    private static func estimatedBytes(_ record: HealthIngestRecord, payloadBytes: Int) -> Int {
        payloadBytes + record.type.utf8.count + record.id.utf8.count + record.tz.utf8.count + 96
    }

    private func writeSpill(_ rows: [HealthIngestQueuedRecord]) {
        var start = 0
        while start < rows.count {
            let end = min(start + Self.segmentSize, rows.count)
            let chunk = Array(rows[start ..< end])
            disk.saveSpillSegment(spill.nextID, chunk)
            spill.segments.append(HealthIngestSpillSegment(id: spill.nextID, count: chunk.count))
            spill.nextID += 1
            start = end
        }
        disk.saveSpillManifest(spill)
    }

    /// Loads the oldest spill segments once the window has drained below half.
    private func refillWindow() {
        while items.count < Self.windowCap / 2, let first = spill.segments.first {
            let rows = disk.loadSpillSegment(first.id)
            for row in rows {
                items.append(row)
                windowKeys.insert(Self.key(row.record))
            }
            spill.segments.removeFirst()
            // Window first, then the manifest, then the file: a crash leaves a duplicate, not a loss.
            disk.saveQueue(items)
            disk.saveSpillManifest(spill)
            disk.deleteSpillSegment(first.id)
        }
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

    func depth() -> Int { items.count + spill.count }

    /// Rows held in memory. Never above `windowCap` after init or an enqueue.
    func windowCount() -> Int { items.count }

    func rejectedCount() -> Int { disk.loadRejectedCount() }

    /// Forgets rejected receipts so a later backfill can enqueue the same ids again
    /// after a payload or server-contract fix.
    func forgetRejectedReceipts() {
        let remaining = receipts.filter { $0.state != .rejected }
        receipts = remaining
        rebuildReceiptIndex()
        disk.saveReceipts(receipts)
    }

    func dropTypes(_ types: Set<String>) {
        items.removeAll { types.contains($0.record.type) }
        windowKeys = Set(items.map { Self.key($0.record) })
        disk.saveQueue(items)
        var kept: [HealthIngestSpillSegment] = []
        for segment in spill.segments {
            let rows = disk.loadSpillSegment(segment.id)
            let remaining = rows.filter { !types.contains($0.record.type) }
            if remaining.isEmpty {
                disk.deleteSpillSegment(segment.id)
            } else {
                if remaining.count != rows.count {
                    disk.saveSpillSegment(segment.id, remaining)
                }
                kept.append(HealthIngestSpillSegment(id: segment.id, count: remaining.count))
            }
        }
        spill.segments = kept
        disk.saveSpillManifest(spill)
        refillWindow()
    }

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
        let relevant = records.filter { tracked.contains($0.type) }
        guard !relevant.isEmpty else { return }
        var stored = disk.loadUploadedIDs()
        var known: [String: Set<String>] = [:]
        var changed = false
        for record in relevant {
            if known[record.type] == nil { known[record.type] = Set(stored[record.type] ?? []) }
            if known[record.type]?.insert(record.id).inserted == true {
                stored[record.type, default: []].append(record.id)
                changed = true
            }
        }
        if changed { disk.saveUploadedIDs(stored) }
    }

    func hasReady() -> Bool {
        let now = Date()
        return items.contains { $0.notBefore <= now }
    }

    /// Accepted and duplicate are done. A rejection is retried a few times, then dropped
    /// so a bad record cannot be resent forever. A timeout keeps the records and resends
    /// the same ids.
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
            guard windowKeys.contains(key),
                  let index = items.firstIndex(where: { Self.key($0.record) == key }) else { continue }
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
                items[index].failures += 1
                if items[index].failures == 1 {
                    disk.saveRejectedCount(disk.loadRejectedCount() + 1)
                }
                if items[index].failures >= 3 {
                    remove.insert(key)
                    remember(key: key, hash: items[index].hash, state: .rejected, at: now)
                } else {
                    postponeKeys.append(key)
                }
            }
        }
        if !postponeKeys.isEmpty {
            postpone(postponeKeys, until: now.addingTimeInterval(HealthIngestBackoff.delay(afterFailures: 1)))
        }
        if !remove.isEmpty {
            items.removeAll { remove.contains(Self.key($0.record)) }
            windowKeys.subtract(remove)
        }
        if !accepted.isEmpty {
            noteUploaded(accepted)
        }
        disk.saveQueue(items)
        disk.saveReceipts(receipts)
        refillWindow()
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
        if receiptByKey[key] != nil {
            receipts.removeAll { $0.key == key }
        }
        let receipt = HealthIngestReceipt(key: key, hash: hash, state: state, at: at)
        receipts.append(receipt)
        receiptByKey[key] = receipt
        pruneReceipts()
    }

    private func rebuildReceiptIndex() {
        receiptByKey = Dictionary(receipts.map { ($0.key, $0) }, uniquingKeysWith: { _, new in new })
    }

    private func pruneReceipts() {
        let rejectedIndexes = receipts.indices.filter { receipts[$0].state == .rejected }
        if rejectedIndexes.count > rejectedReceiptCap {
            let evict = Set(rejectedIndexes.prefix(rejectedIndexes.count - rejectedReceiptCap))
            receipts = receipts.enumerated().compactMap { evict.contains($0.offset) ? nil : $0.element }
        }
        if receipts.count > receiptCap {
            // Drop oldest rejected rows first so accepted ids used for deletions remain.
            var overflow = receipts.count - receiptCap
            receipts.removeAll { item in
                guard overflow > 0, item.state == .rejected else { return false }
                overflow -= 1
                return true
            }
            if receipts.count > receiptCap {
                receipts.removeFirst(receipts.count - receiptCap)
            }
        }
        if receiptByKey.count != receipts.count {
            rebuildReceiptIndex()
        }
    }
}
