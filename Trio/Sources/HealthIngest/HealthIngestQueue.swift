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

struct HealthIngestRejectReason: Codable, Equatable {
    var type: String
    var reason: String
    var message: String
    var count: Int
    var lastSeen: Date
}

struct HealthIngestRejectLog: Codable, Equatable {
    static let capacity = 200

    /// Newest last. Only the latest samples; reasons below survive after this rolls.
    var events: [HealthIngestRejectEvent] = []
    /// One row per type and reason. Status and the detail screen both read this.
    var reasons: [HealthIngestRejectReason] = []
    /// True when this value was decoded from the old `counts` map and should be rewritten.
    var didMigrateLegacyCounts = false

    var total: Int { reasons.reduce(0) { $0 + $1.count } }

    var latestReason: String? {
        reasons.max(by: { $0.lastSeen < $1.lastSeen })?.reason
    }

    mutating func append(type: String, reason: String, message: String, at: Date) {
        events.append(HealthIngestRejectEvent(type: type, reason: reason, message: message, at: at))
        if events.count > Self.capacity {
            events.removeFirst(events.count - Self.capacity)
        }
        if let index = reasons.firstIndex(where: { $0.type == type && $0.reason == reason }) {
            reasons[index].count += 1
            reasons[index].message = message
            reasons[index].lastSeen = at
        } else {
            reasons.append(
                HealthIngestRejectReason(type: type, reason: reason, message: message, count: 1, lastSeen: at)
            )
        }
    }

    func groups() -> [HealthIngestRejectGroup] {
        reasons.map {
            HealthIngestRejectGroup(
                type: $0.type,
                reason: $0.reason,
                message: $0.message,
                count: $0.count,
                lastSeen: $0.lastSeen
            )
        }
        .sorted { lhs, rhs in
            if lhs.type != rhs.type { return lhs.type < rhs.type }
            return lhs.lastSeen > rhs.lastSeen
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(events, forKey: .events)
        try container.encode(reasons, forKey: .reasons)
    }

    private enum CodingKeys: String, CodingKey {
        case events
        case reasons
        case counts
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        events = try container.decodeIfPresent([HealthIngestRejectEvent].self, forKey: .events) ?? []
        reasons = try container.decodeIfPresent([HealthIngestRejectReason].self, forKey: .reasons) ?? []
        guard reasons.isEmpty, let counts = try container.decodeIfPresent([String: Int].self, forKey: .counts), !counts.isEmpty else { return }
        didMigrateLegacyCounts = true
        // A counts map with no samples never appeared in the detail list. Importing it
        // would bring back a stale total such as 15,893. Leave the store empty.
        guard !events.isEmpty else { return }
        for (key, count) in counts {
            let parts = key.split(separator: "\n", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let match = events.last { $0.type == parts[0] && $0.reason == parts[1] }
            reasons.append(
                HealthIngestRejectReason(
                    type: parts[0],
                    reason: parts[1],
                    message: match?.message ?? parts[1],
                    count: count,
                    lastSeen: match?.at ?? .distantPast
                )
            )
        }
    }
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
        loadQueue(named: "queue.json")
    }

    func loadQueue(named name: String) -> [HealthIngestQueuedRecord] {
        load([HealthIngestQueuedRecord].self, name: name) ?? []
    }

    func saveQueue(_ items: [HealthIngestQueuedRecord]) {
        saveQueue(items, named: "queue.json")
    }

    func saveQueue(_ items: [HealthIngestQueuedRecord], named name: String) {
        save(items, name: name)
    }

    /// Records beyond the in-memory window live in small segment files of at most
    /// `HealthIngestQueue.segmentSize` rows each, so memory and every rewrite stay bounded.
    func loadSpillManifest() -> HealthIngestSpillManifest {
        loadSpillManifest(named: "queue-spill.json")
    }

    func loadSpillManifest(named name: String) -> HealthIngestSpillManifest {
        load(HealthIngestSpillManifest.self, name: name) ?? HealthIngestSpillManifest()
    }

    func saveSpillManifest(_ manifest: HealthIngestSpillManifest) {
        saveSpillManifest(manifest, named: "queue-spill.json")
    }

    func saveSpillManifest(_ manifest: HealthIngestSpillManifest, named name: String) {
        save(manifest, name: name)
    }

    func loadSpillSegment(_ id: Int) -> [HealthIngestQueuedRecord] {
        loadSpillSegment(prefix: "queue-spill-", id: id)
    }

    func loadSpillSegment(prefix: String, id: Int) -> [HealthIngestQueuedRecord] {
        load([HealthIngestQueuedRecord].self, name: "\(prefix)\(id).json") ?? []
    }

    func saveSpillSegment(_ id: Int, _ items: [HealthIngestQueuedRecord]) {
        saveSpillSegment(prefix: "queue-spill-", id: id, items)
    }

    func saveSpillSegment(prefix: String, id: Int, _ items: [HealthIngestQueuedRecord]) {
        save(items, name: "\(prefix)\(id).json")
    }

    func deleteSpillSegment(_ id: Int) {
        deleteSpillSegment(prefix: "queue-spill-", id: id)
    }

    func deleteSpillSegment(prefix: String, id: Int) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(prefix)\(id).json"))
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

    func loadRejectLog() -> HealthIngestRejectLog {
        load(HealthIngestRejectLog.self, name: "reject-log.json") ?? HealthIngestRejectLog()
    }

    func saveRejectLog(_ log: HealthIngestRejectLog) {
        save(log, name: "reject-log.json")
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

    /// Set once the pre-priority queue has been split. A crash before this is written retries.
    func loadPriorityMigrated() -> Bool {
        load(Bool.self, name: "priority-migrated.json") ?? false
    }

    func savePriorityMigrated() {
        save(true, name: "priority-migrated.json")
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

/// Which reads one pass may start. A HealthKit backlog never blocks Trio records.
enum HealthIngestReadGate {
    struct Decision: Equatable {
        var readDiabetes: Bool
        var readHealthKit: Bool
    }

    /// Trio reads wait only when their own lane holds this many rows. A foreground
    /// catch-up is a two-day chunk, so this fits several chunks, then pauses until
    /// uploads drain the lane.
    static let priorityCap = 2_000

    static func decide(
        healthKitDepth: Int,
        priorityDepth: Int,
        highWater: Int,
        throttled: Bool,
        priorityCap: Int = priorityCap
    ) -> Decision {
        Decision(
            readDiabetes: !throttled && priorityDepth < priorityCap,
            readHealthKit: healthKitDepth < highWater
        )
    }
}

/// Two on-disk lanes. Trio records sit in the priority lane and leave `nextBatch` first.
/// HealthKit backfill stays in the original queue. A queue written before the priority
/// lane is split on open so those rows still upload.
actor HealthIngestQueue {
    /// Rows kept in memory per lane. Anything beyond this goes to spill segments.
    static let windowCap = 1_000
    static let segmentSize = 500

    private struct LaneFiles {
        var queueName: String
        var manifestName: String
        var segmentPrefix: String

        static let regular = LaneFiles(
            queueName: "queue.json",
            manifestName: "queue-spill.json",
            segmentPrefix: "queue-spill-"
        )
        static let priority = LaneFiles(
            queueName: "priority.json",
            manifestName: "priority-spill.json",
            segmentPrefix: "priority-spill-"
        )
    }

    private final class Lane {
        var items: [HealthIngestQueuedRecord]
        var windowKeys: Set<String>
        var spill: HealthIngestSpillManifest
        let files: LaneFiles

        var count: Int { items.count + spill.count }

        init(
            items: [HealthIngestQueuedRecord],
            windowKeys: Set<String>,
            spill: HealthIngestSpillManifest,
            files: LaneFiles
        ) {
            self.items = items
            self.windowKeys = windowKeys
            self.spill = spill
            self.files = files
        }
    }

    private let disk: HealthIngestDisk
    private let priority: Lane
    private let regular: Lane
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
        regular = Self.loadLane(.regular, disk: disk)
        priority = Self.loadLane(.priority, disk: disk)
        if !disk.loadPriorityMigrated() {
            Self.migrateLegacyPriorityRows(disk: disk, regular: regular, priority: priority)
            disk.savePriorityMigrated()
        }
        let stored = disk.loadReceipts()
        receipts = stored
        receiptByKey = Dictionary(stored.map { ($0.key, $0) }, uniquingKeysWith: { _, new in new })
        firstSeen = disk.loadFirstSeen()
    }

    /// A queue file written before spill segments existed can hold tens of thousands
    /// of rows. Move the excess to segments once so memory is bounded from here on.
    private static func loadLane(_ files: LaneFiles, disk: HealthIngestDisk) -> Lane {
        var window = disk.loadQueue(named: files.queueName)
        var manifest = disk.loadSpillManifest(named: files.manifestName)
        if window.count > windowCap {
            let excess = Array(window[windowCap...])
            window = Array(window[..<windowCap])
            var start = 0
            while start < excess.count {
                let end = min(start + segmentSize, excess.count)
                let chunk = Array(excess[start ..< end])
                disk.saveSpillSegment(prefix: files.segmentPrefix, id: manifest.nextID, chunk)
                manifest.segments.append(HealthIngestSpillSegment(id: manifest.nextID, count: chunk.count))
                manifest.nextID += 1
                start = end
            }
            disk.saveSpillManifest(manifest, named: files.manifestName)
            disk.saveQueue(window, named: files.queueName)
        }
        // Pull the oldest segments back in until the window is half full.
        while window.count < windowCap / 2, let first = manifest.segments.first {
            window.append(contentsOf: disk.loadSpillSegment(prefix: files.segmentPrefix, id: first.id))
            manifest.segments.removeFirst()
            disk.saveQueue(window, named: files.queueName)
            disk.saveSpillManifest(manifest, named: files.manifestName)
            disk.deleteSpillSegment(prefix: files.segmentPrefix, id: first.id)
        }
        return Lane(
            items: window,
            windowKeys: Set(window.map { key($0.record) }),
            spill: manifest,
            files: files
        )
    }

    /// Copies Trio rows out of the original queue, then removes them. The copy is saved
    /// first so a crash leaves a duplicate, which the server upserts, rather than a gap.
    private static func migrateLegacyPriorityRows(disk: HealthIngestDisk, regular: Lane, priority: Lane) {
        var moved: [HealthIngestQueuedRecord] = []
        moved.append(contentsOf: regular.items.filter { HealthIngestType.isPriorityLane($0.record.type) })
        var segmentRows: [(segment: HealthIngestSpillSegment, stay: [HealthIngestQueuedRecord], go: [HealthIngestQueuedRecord])] = []
        for segment in regular.spill.segments {
            let rows = disk.loadSpillSegment(prefix: regular.files.segmentPrefix, id: segment.id)
            let go = rows.filter { HealthIngestType.isPriorityLane($0.record.type) }
            let stay = rows.filter { !HealthIngestType.isPriorityLane($0.record.type) }
            if !go.isEmpty {
                moved.append(contentsOf: go)
            }
            segmentRows.append((segment, stay, go))
        }
        guard !moved.isEmpty else { return }

        var seen = keys(in: priority, disk: disk)
        var fresh: [HealthIngestQueuedRecord] = []
        for row in moved where seen.insert(key(row.record)).inserted {
            fresh.append(row)
        }
        appendPending(fresh, to: priority, disk: disk)

        regular.items.removeAll { HealthIngestType.isPriorityLane($0.record.type) }
        regular.windowKeys = Set(regular.items.map { key($0.record) })
        var kept: [HealthIngestSpillSegment] = []
        for entry in segmentRows {
            if entry.go.isEmpty {
                kept.append(entry.segment)
                continue
            }
            if entry.stay.isEmpty {
                disk.deleteSpillSegment(prefix: regular.files.segmentPrefix, id: entry.segment.id)
            } else {
                disk.saveSpillSegment(prefix: regular.files.segmentPrefix, id: entry.segment.id, entry.stay)
                kept.append(HealthIngestSpillSegment(id: entry.segment.id, count: entry.stay.count))
            }
        }
        regular.spill.segments = kept
        disk.saveQueue(regular.items, named: regular.files.queueName)
        disk.saveSpillManifest(regular.spill, named: regular.files.manifestName)
        refillWindow(regular, disk: disk)
        refillWindow(priority, disk: disk)
    }

    /// Same `(type, id)` is reused. A changed payload replaces a pending row and is sent again
    /// after a previous accept. An unchanged snapshot is sent again once a day.
    /// Callers pass at most a few hundred records at a time. Rows beyond the memory window are
    /// written to spill segments, so a large backfill never grows the in-memory queue.
    /// Trio records go to the priority lane. HealthKit records stay on the original lane.
    func enqueue(_ records: [HealthIngestRecord], now: Date = Date()) -> HealthIngestEnqueueResult {
        var queued = 0
        var oversized = 0
        var priorityDirty = false
        var regularDirty = false
        var priorityOverflow: [HealthIngestQueuedRecord] = []
        var regularOverflow: [HealthIngestQueuedRecord] = []
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
            let priorityLane = HealthIngestType.isPriorityLane(record.type)
            let lane = priorityLane ? priority : regular
            if lane.windowKeys.contains(key), let index = lane.items.firstIndex(where: { Self.key($0.record) == key }) {
                guard lane.items[index].hash != hash else { continue }
                lane.items[index].record = record
                lane.items[index].bytes = bytes
                lane.items[index].hash = hash
                lane.items[index].notBefore = now
                queued += 1
                if priorityLane { priorityDirty = true } else { regularDirty = true }
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
            if lane.items.count < Self.windowCap {
                lane.items.append(row)
                lane.windowKeys.insert(key)
                if priorityLane { priorityDirty = true } else { regularDirty = true }
            } else {
                // A repeat of a spilled row is harmless: the server upserts by (type, id).
                if priorityLane {
                    priorityOverflow.append(row)
                } else {
                    regularOverflow.append(row)
                }
            }
            queued += 1
        }
        if firstSeenChanged {
            disk.saveFirstSeen(firstSeen)
        }
        if priorityDirty {
            disk.saveQueue(priority.items, named: priority.files.queueName)
        }
        if regularDirty {
            disk.saveQueue(regular.items, named: regular.files.queueName)
        }
        if !priorityOverflow.isEmpty {
            writeSpill(priorityOverflow, lane: priority)
        }
        if !regularOverflow.isEmpty {
            writeSpill(regularOverflow, lane: regular)
        }
        return HealthIngestEnqueueResult(queued: queued, oversized: oversized)
    }

    /// Serialized size is only used to cap a batch, so a cheap estimate is enough.
    private static func estimatedBytes(_ record: HealthIngestRecord, payloadBytes: Int) -> Int {
        payloadBytes + record.type.utf8.count + record.id.utf8.count + record.tz.utf8.count + 96
    }

    private func writeSpill(_ rows: [HealthIngestQueuedRecord], lane: Lane) {
        Self.writeSpill(rows, lane: lane, disk: disk)
    }

    private static func writeSpill(_ rows: [HealthIngestQueuedRecord], lane: Lane, disk: HealthIngestDisk) {
        var start = 0
        while start < rows.count {
            let end = min(start + segmentSize, rows.count)
            let chunk = Array(rows[start ..< end])
            disk.saveSpillSegment(prefix: lane.files.segmentPrefix, id: lane.spill.nextID, chunk)
            lane.spill.segments.append(HealthIngestSpillSegment(id: lane.spill.nextID, count: chunk.count))
            lane.spill.nextID += 1
            start = end
        }
        disk.saveSpillManifest(lane.spill, named: lane.files.manifestName)
    }

    /// Loads the oldest spill segments once the window has drained below half.
    private func refillWindow(_ lane: Lane) {
        Self.refillWindow(lane, disk: disk)
    }

    /// Window first, then the manifest, then the file: a crash leaves a duplicate, not a loss.
    private static func refillWindow(_ lane: Lane, disk: HealthIngestDisk) {
        while lane.items.count < windowCap / 2, let first = lane.spill.segments.first {
            let rows = disk.loadSpillSegment(prefix: lane.files.segmentPrefix, id: first.id)
            for row in rows {
                lane.items.append(row)
                lane.windowKeys.insert(key(row.record))
            }
            lane.spill.segments.removeFirst()
            disk.saveQueue(lane.items, named: lane.files.queueName)
            disk.saveSpillManifest(lane.spill, named: lane.files.manifestName)
            disk.deleteSpillSegment(prefix: lane.files.segmentPrefix, id: first.id)
        }
    }

    private static func appendPending(_ rows: [HealthIngestQueuedRecord], to lane: Lane, disk: HealthIngestDisk) {
        guard !rows.isEmpty else { return }
        var overflow: [HealthIngestQueuedRecord] = []
        var changed = false
        for row in rows {
            let rowKey = key(row.record)
            if lane.windowKeys.contains(rowKey) { continue }
            if lane.items.count < windowCap {
                lane.items.append(row)
                lane.windowKeys.insert(rowKey)
                changed = true
            } else {
                overflow.append(row)
            }
        }
        if changed {
            disk.saveQueue(lane.items, named: lane.files.queueName)
        }
        if !overflow.isEmpty {
            writeSpill(overflow, lane: lane, disk: disk)
        }
    }

    private static func keys(in lane: Lane, disk: HealthIngestDisk) -> Set<String> {
        var found = lane.windowKeys
        for segment in lane.spill.segments {
            for row in disk.loadSpillSegment(prefix: lane.files.segmentPrefix, id: segment.id) {
                found.insert(key(row.record))
            }
        }
        return found
    }

    /// Priority lane first, then the HealthKit lane. One batch can hold both when the
    /// priority rows do not fill it. Ids are unchanged.
    func nextBatch(limit: Int, maxBytes: Int) -> [HealthIngestRecord] {
        let now = Date()
        var batch: [HealthIngestRecord] = []
        var bytes = 0
        var seen = Set<String>()
        func take(_ lane: Lane) {
            for item in lane.items where item.notBefore <= now {
                let rowKey = Self.key(item.record)
                if seen.contains(rowKey) { continue }
                if !batch.isEmpty, bytes + item.bytes > maxBytes || batch.count >= limit {
                    break
                }
                batch.append(item.record)
                seen.insert(rowKey)
                bytes += item.bytes
                if batch.count >= limit || bytes >= maxBytes {
                    break
                }
            }
        }
        take(priority)
        take(regular)
        return batch
    }

    func depth() -> Int { priority.count + regular.count }

    /// Trio rows waiting, including their spill segments.
    func priorityDepth() -> Int { priority.count }

    /// HealthKit rows waiting, including their spill segments.
    func regularDepth() -> Int { regular.count }

    /// HealthKit rows held in memory. Never above `windowCap` after init or an enqueue.
    func windowCount() -> Int { regular.items.count }

    /// Sum of the per-reason counts. Matches the detail screen, including reasons
    /// whose samples have already rolled off the 200-event buffer.
    func rejectedCount() -> Int { disk.loadRejectLog().total }

    /// The per-reason store is the only source of truth. Phones that already shipped
    /// can still have the old integer file (15,893) with an empty detail list. Rewrite
    /// that file on launch so the stale number is gone without a mapping-version bump.
    func reconcileRejectedCount() {
        let log = disk.loadRejectLog()
        if log.didMigrateLegacyCounts {
            disk.saveRejectLog(log)
        }
        let total = log.total
        if disk.loadRejectedCount() != total {
            disk.saveRejectedCount(total)
        }
    }

    func recordRejection(type: String, reason: String, message: String, at: Date = Date()) {
        var log = disk.loadRejectLog()
        log.append(type: type, reason: reason, message: message, at: at)
        disk.saveRejectLog(log)
        disk.saveRejectedCount(log.total)
    }

    func rejectionSummary() -> (latest: String?, groups: [HealthIngestRejectGroup]) {
        let log = disk.loadRejectLog()
        return (log.latestReason, log.groups())
    }

    func clearRejections() {
        disk.saveRejectLog(HealthIngestRejectLog())
        disk.saveRejectedCount(0)
    }

    /// Forgets rejected receipts so a later backfill can enqueue the same ids again
    /// after a payload or server-contract fix.
    func forgetRejectedReceipts() {
        let remaining = receipts.filter { $0.state != .rejected }
        receipts = remaining
        rebuildReceiptIndex()
        disk.saveReceipts(receipts)
    }

    func dropTypes(_ types: Set<String>) {
        for lane in [priority, regular] {
            lane.items.removeAll { types.contains($0.record.type) }
            lane.windowKeys = Set(lane.items.map { Self.key($0.record) })
            disk.saveQueue(lane.items, named: lane.files.queueName)
            var kept: [HealthIngestSpillSegment] = []
            for segment in lane.spill.segments {
                let rows = disk.loadSpillSegment(prefix: lane.files.segmentPrefix, id: segment.id)
                let remaining = rows.filter { !types.contains($0.record.type) }
                if remaining.isEmpty {
                    disk.deleteSpillSegment(prefix: lane.files.segmentPrefix, id: segment.id)
                } else {
                    if remaining.count != rows.count {
                        disk.saveSpillSegment(prefix: lane.files.segmentPrefix, id: segment.id, remaining)
                    }
                    kept.append(HealthIngestSpillSegment(id: segment.id, count: remaining.count))
                }
            }
            lane.spill.segments = kept
            disk.saveSpillManifest(lane.spill, named: lane.files.manifestName)
            refillWindow(lane)
        }
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
        return priority.items.contains { $0.notBefore <= now } || regular.items.contains { $0.notBefore <= now }
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
            saveLanes()
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
            guard let located = locate(key) else { continue }
            guard let ack = byKey[key] else {
                postponeKeys.append(key)
                continue
            }
            switch ack.status {
            case .accepted,
                 .duplicate:
                remove.insert(key)
                accepted.append(record)
                remember(key: key, hash: located.lane.items[located.index].hash, state: .accepted, at: now)
            case .rejected:
                let reason = ack.reason ?? "rejected"
                let message = ack.message?.trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = (message?.isEmpty == false) ? message! : reason
                lastReject = "\(ack.type) \(ack.id): \(detail)"
                located.lane.items[located.index].failures += 1
                recordRejection(type: ack.type, reason: reason, message: detail, at: now)
                if located.lane.items[located.index].failures >= 3 {
                    remove.insert(key)
                    remember(key: key, hash: located.lane.items[located.index].hash, state: .rejected, at: now)
                } else {
                    postponeKeys.append(key)
                }
            }
        }
        if !postponeKeys.isEmpty {
            postpone(postponeKeys, until: now.addingTimeInterval(HealthIngestBackoff.delay(afterFailures: 1)))
        }
        if !remove.isEmpty {
            for lane in [priority, regular] {
                lane.items.removeAll { remove.contains(Self.key($0.record)) }
                lane.windowKeys.subtract(remove)
            }
        }
        if !accepted.isEmpty {
            noteUploaded(accepted)
        }
        saveLanes()
        disk.saveReceipts(receipts)
        refillWindow(priority)
        refillWindow(regular)
        return lastReject
    }

    private func saveLanes() {
        disk.saveQueue(priority.items, named: priority.files.queueName)
        disk.saveQueue(regular.items, named: regular.files.queueName)
    }

    private func locate(_ key: String) -> (lane: Lane, index: Int)? {
        if priority.windowKeys.contains(key),
           let index = priority.items.firstIndex(where: { Self.key($0.record) == key }) {
            return (priority, index)
        }
        if regular.windowKeys.contains(key),
           let index = regular.items.firstIndex(where: { Self.key($0.record) == key }) {
            return (regular, index)
        }
        return nil
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
        for lane in [priority, regular] {
            for index in lane.items.indices where keySet.contains(Self.key(lane.items[index].record)) {
                lane.items[index].failures += 1
                maxFailures = max(maxFailures, lane.items[index].failures)
            }
        }
        return maxFailures
    }

    private func postpone(_ keys: [String], until date: Date) {
        let keySet = Set(keys)
        for lane in [priority, regular] {
            for index in lane.items.indices where keySet.contains(Self.key(lane.items[index].record)) {
                lane.items[index].notBefore = date
            }
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
