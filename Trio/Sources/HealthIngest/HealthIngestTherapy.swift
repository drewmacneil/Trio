import Foundation
import LocalAuthentication

/// Bolus decisions, bolus failures, and CGM events waiting to upload, plus the
/// small lookups carb and pump rows need. Stored as JSON beside the loop notes.
/// Nothing here is a Core Data migration.
enum HealthIngestTherapy {
    static let watchRecommendationLifetime: TimeInterval = 10 * 60

    private static let lock = NSLock()
    /// Disk writes for bolus links. The dose path only appends in memory.
    private static let fileQueue = DispatchQueue(label: "health-ingest.therapy.files", qos: .utility)
    private static var directoryOverride: URL?
    private static var loaded = false
    private static var pending: [HealthIngestRecord] = []
    /// Records accepted on the caller thread and not yet folded into `pending`.
    private static var stagedRecords: [HealthIngestRecord] = []
    private static var carbStamps: [String: CarbStamp] = [:]
    private static var bolusLinks: [BolusLink] = []
    /// Links remembered on the dose path and not yet folded into `bolusLinks`.
    private static var unsavedLinks: [BolusLink] = []
    private static var pumpNotes: [String: PumpNote] = [:]
    private static var pumpSnapshot: PumpSnapshot?
    private static var watchPending: WatchPending?
    private static var bolusAttempt: BolusAttempt?
    private static var sensorWasWarmup = false

    private struct CarbStamp: Codable {
        var enteredAt: Date?
        var editedAt: Date?
    }

    private struct BolusLink: Codable {
        var decisionId: String?
        var source: String
        var units: Double
        var at: Date
        var eventId: String?
    }

    private struct PumpNote: Codable {
        var kind: String?
        var message: String?
        var reservoirUnits: Double?
        var podActivatedAt: Date?
        var insulinAgeHours: Double?
    }

    private struct PumpSnapshot {
        var reservoirUnits: Double?
        var podActivatedAt: Date?
        var at: Date
    }

    private struct WatchPending {
        var decisionId: UUID
        var stagedAt: Date
        var report: BolusCalculationReport
        var fat: Decimal
        var protein: Decimal
        var carbEntryId: String?
        var carbEntryEatenAt: Date?
    }

    private struct BolusAttempt {
        var units: Double
        var source: String
        var decisionId: UUID?
    }

    /// Points the JSON files at a scratch directory. Pass nil to use Application Support again.
    static func useTestDirectory(_ url: URL?) {
        fileQueue.sync {}
        lock.lock()
        directoryOverride = url
        loaded = false
        pending = []
        stagedRecords = []
        carbStamps = [:]
        bolusLinks = []
        unsavedLinks = []
        pumpNotes = [:]
        pumpSnapshot = nil
        watchPending = nil
        bolusAttempt = nil
        sensorWasWarmup = false
        lock.unlock()
    }

    // MARK: - Bolus decision

    static func decisionRecord(
        decisionId: UUID,
        at: Date,
        source: String,
        report: BolusCalculationReport,
        fat: Decimal,
        protein: Decimal,
        enteredUnits: Decimal,
        external: Bool,
        skipped: Bool,
        carbEntryId: String?,
        carbEntryEatenAt: Date?
    ) -> HealthIngestRecord {
        let recommended = decimal(report.result.insulinCalculated) ?? 0
        let entered = skipped ? 0 : (decimal(enteredUnits) ?? 0)
        let outcome = bolusOutcome(recommended: recommended, entered: entered, skipped: skipped)
        let input = report.input
        let age = max(0, at.timeIntervalSince(input.lastLoopDate))
        // cobSimulated is grams (0–2000). Omit it when the screen did not simulate COB.
        // A boolean is rejected.
        let inputs: [String: HealthIngestJSON?] = [
            "bgMgdl": inclusive(decimal(input.currentBG), 0, 2000),
            "deltaMgdl15m": inclusive(decimal(input.deltaBG), -1000, 1000),
            "targetMgdl": inclusive(decimal(input.target), 40, 400),
            "isf": exclusiveMin(decimal(input.isf), above: 0, through: 1000),
            "cr": atLeast(decimal(input.carbRatio), 0),
            "iob": inclusive(decimal(input.iob), -20, 50),
            "cob": inclusive(Double(report.loopCob), 0, 2000),
            "cobSimulated": report.simulatedCob.flatMap { inclusive(Double($0), 0, 2000) },
            "carbs": inclusive(decimal(report.enteredCarbs), 0, 1000),
            "fat": inclusive(decimal(fat), 0, 1000),
            "protein": inclusive(decimal(protein), 0, 1000),
            "carbEntryId": carbEntryId.flatMap { $0.isEmpty ? nil : .string($0) },
            "carbEntryEatenAt": carbEntryEatenAt.map { .string(HealthIngestTime.string(from: $0)) },
            "minPredBG": finite(decimal(input.minPredBG)),
            "lastLoopAgeSec": inclusive(age, 0, 1_000_000),
            "backdated": .bool(report.backdated),
            "fraction": inclusive(decimal(input.fraction), 0, 10),
            "fattyMeal": .bool(input.useFattyMealCorrectionFactor),
            "fattyMealFactor": inclusive(decimal(input.fattyMealFactor), 0, 10),
            "superBolus": .bool(input.useSuperBolus),
            "superBolusFactor": input.useSuperBolus ? inclusive(decimal(input.sweetMealFactor), 0, 10) : nil,
            "maxBolus": inclusive(decimal(input.maxBolus), 0, 100),
            "maxIOB": inclusive(decimal(input.maxIOB), 0, 100),
            "maxCOB": inclusive(decimal(input.maxCOB), 0, 2000)
        ]
        let components: [String: HealthIngestJSON?] = [
            "carbsInsulin": inclusive(decimal(report.result.wholeCobInsulin), -100, 100),
            "iobReduction": inclusive(decimal(report.result.iobInsulinReduction), -100, 100),
            "bgCorrection": inclusive(decimal(report.result.targetDifferenceInsulin), -100, 100),
            "trendInsulin": inclusive(decimal(report.result.fifteenMinutesInsulin), -100, 100),
            "superBolusInsulin": inclusive(decimal(report.result.superBolusInsulin), -100, 100),
            "totalBeforeFactors": inclusive(decimal(report.result.wholeCalc), -100, 100),
            "totalAfterFactors": inclusive(decimal(report.result.factoredInsulin), -100, 100),
            "recommendedRounded": inclusive(recommended, 0, 100)
        ]
        let action: [String: HealthIngestJSON?] = [
            "enteredUnits": inclusive(entered, 0, 100),
            "external": .bool(external && !skipped),
            "outcome": .string(outcome),
            "deltaUnits": inclusive(entered - recommended, -100, 100)
        ]
        let payload = HealthIngestJSON.object([
            "timestamp": .string(HealthIngestTime.string(from: at)),
            "source": .string(source),
            "inputs": .object(inputs),
            "components": .object(components),
            "action": .object(action)
        ])
        return HealthIngestRecord(
            type: HealthIngestType.bolusDecision,
            id: decisionId.uuidString,
            start: at,
            end: nil,
            tz: HealthIngestTime.zoneIdentifier,
            payload: payload
        )
    }

    static func storeDecision(
        decisionId: UUID,
        at: Date = Date(),
        source: String,
        report: BolusCalculationReport,
        fat: Decimal,
        protein: Decimal,
        enteredUnits: Decimal,
        external: Bool,
        skipped: Bool,
        carbEntryId: String?,
        carbEntryEatenAt: Date?
    ) {
        let record = decisionRecord(
            decisionId: decisionId,
            at: at,
            source: source,
            report: report,
            fat: fat,
            protein: protein,
            enteredUnits: enteredUnits,
            external: external,
            skipped: skipped,
            carbEntryId: carbEntryId,
            carbEntryEatenAt: carbEntryEatenAt
        )
        enqueue(record)
    }

    static func bolusOutcome(recommended: Double, entered: Double, skipped: Bool) -> String {
        if skipped { return "skipped" }
        if abs(entered - recommended) < 0.001 { return "accepted" }
        if entered < recommended { return "reduced" }
        return "increased"
    }

    static func stageWatch(report: BolusCalculationReport, fat: Decimal = 0, protein: Decimal = 0) {
        lock.lock()
        let previous = watchPending
        watchPending = WatchPending(
            decisionId: UUID(),
            stagedAt: Date(),
            report: report,
            fat: fat,
            protein: protein,
            carbEntryId: nil,
            carbEntryEatenAt: nil
        )
        lock.unlock()
        if let previous {
            storeDecision(
                decisionId: previous.decisionId,
                at: Date(),
                source: "watch",
                report: previous.report,
                fat: previous.fat,
                protein: previous.protein,
                enteredUnits: 0,
                external: false,
                skipped: true,
                carbEntryId: previous.carbEntryId,
                carbEntryEatenAt: previous.carbEntryEatenAt
            )
        }
    }

    static func noteWatchCarb(id: UUID, eatenAt: Date) {
        lock.lock()
        watchPending?.carbEntryId = id.uuidString
        watchPending?.carbEntryEatenAt = eatenAt
        lock.unlock()
    }

    /// Confirms the staged watch recommendation. Nil when the watch never asked for one.
    static func takeWatch(
        enteredUnits: Decimal,
        carbEntryId: String? = nil,
        carbEntryEatenAt: Date? = nil,
        at: Date = Date()
    ) -> UUID? {
        lock.lock()
        guard let pending = watchPending else {
            lock.unlock()
            return nil
        }
        watchPending = nil
        lock.unlock()
        let entryId = carbEntryId ?? pending.carbEntryId
        let eatenAt = carbEntryEatenAt ?? pending.carbEntryEatenAt
        storeDecision(
            decisionId: pending.decisionId,
            at: at,
            source: "watch",
            report: pending.report,
            fat: pending.fat,
            protein: pending.protein,
            enteredUnits: enteredUnits,
            external: false,
            skipped: false,
            carbEntryId: entryId,
            carbEntryEatenAt: eatenAt
        )
        rememberBolusLink(
            decisionId: pending.decisionId,
            source: "watch",
            units: decimal(enteredUnits) ?? 0,
            at: at
        )
        return pending.decisionId
    }

    static func expireWatchRecommendations(now: Date = Date()) {
        lock.lock()
        guard let pending = watchPending, now.timeIntervalSince(pending.stagedAt) >= watchRecommendationLifetime else {
            lock.unlock()
            return
        }
        watchPending = nil
        lock.unlock()
        storeDecision(
            decisionId: pending.decisionId,
            at: now,
            source: "watch",
            report: pending.report,
            fat: pending.fat,
            protein: pending.protein,
            enteredUnits: 0,
            external: false,
            skipped: true,
            carbEntryId: pending.carbEntryId,
            carbEntryEatenAt: pending.carbEntryEatenAt
        )
    }

    // MARK: - Bolus failure

    static func failureRecord(
        at: Date,
        requestedUnits: Double,
        source: String,
        reason: String,
        message: String?,
        decisionId: UUID?
    ) -> HealthIngestRecord {
        let units = requestedUnits.isFinite ? min(max(requestedUnits, 0), 100) : 0
        let payload = HealthIngestJSON.object([
            "timestamp": .string(HealthIngestTime.string(from: at)),
            "requestedUnits": .number(units),
            "source": .string(source),
            "reason": .string(reason),
            "message": sanitizedMessage(message).map { .string($0) },
            "decisionId": decisionId.map { .string($0.uuidString) }
        ])
        return HealthIngestRecord(
            type: HealthIngestType.bolusFailure,
            id: UUID().uuidString,
            start: at,
            end: nil,
            tz: HealthIngestTime.zoneIdentifier,
            payload: payload
        )
    }

    static func storeFailure(
        at: Date = Date(),
        requestedUnits: Double,
        source: String,
        reason: String,
        message: String?,
        decisionId: UUID?
    ) {
        // Automatic deliveries are not a bolus_failure source. The server accepts phone, watch, or remote.
        guard source == "phone" || source == "watch" || source == "remote" else { return }
        let units = requestedUnits.isFinite ? min(max(requestedUnits, 0), 100) : 0
        enqueue(failureRecord(
            at: at,
            requestedUnits: units,
            source: source,
            reason: reason,
            message: message,
            decisionId: decisionId
        ))
    }

    static func authenticationFailureReason(_ error: Error) -> String {
        guard let laError = error as? LAError else { return "auth_failed" }
        switch laError.code {
        case .userCancel, .appCancel, .systemCancel:
            return "cancelled"
        default:
            return "auth_failed"
        }
    }

    static func beginBolusAttempt(units: Double, source: String, decisionId: UUID?) {
        lock.lock()
        bolusAttempt = BolusAttempt(units: units, source: source, decisionId: decisionId)
        lock.unlock()
    }

    static func endBolusAttempt() {
        lock.lock()
        bolusAttempt = nil
        lock.unlock()
    }

    /// Records `cancelled` for the bolus command still in flight. No record when none is.
    static func cancelInFlightBolus(message: String?) {
        lock.lock()
        let attempt = bolusAttempt
        bolusAttempt = nil
        lock.unlock()
        guard let attempt else { return }
        storeFailure(
            requestedUnits: attempt.units,
            source: attempt.source,
            reason: "cancelled",
            message: message,
            decisionId: attempt.decisionId
        )
    }

    // MARK: - Links onto bolus rows

    /// Records a link for a later bolus row. Appends in memory and returns. Does not throw or touch disk.
    static func rememberBolusLink(decisionId: UUID?, source: String, units: Double, at: Date) {
        let link = BolusLink(
            decisionId: decisionId?.uuidString,
            source: source,
            units: units,
            at: at,
            eventId: nil
        )
        lock.lock()
        unsavedLinks.append(link)
        lock.unlock()
        fileQueue.async {
            Self.persistBolusLinks()
        }
    }

    static func claimBolusLink(eventId: String, units: Double, at: Date) {
        prepareMemory()
        lock.lock()
        absorbUnsavedLinksLocked()
        guard !bolusLinks.contains(where: { $0.eventId == eventId }) else {
            lock.unlock()
            return
        }
        let matches = bolusLinks.indices.filter { index in
            let link = bolusLinks[index]
            return link.eventId == nil
                && abs(link.units - units) < 0.051
                && abs(link.at.timeIntervalSince(at)) < 10 * 60
        }
        guard let best = matches.min(by: {
            abs(bolusLinks[$0].at.timeIntervalSince(at)) < abs(bolusLinks[$1].at.timeIntervalSince(at))
        }) else {
            lock.unlock()
            return
        }
        bolusLinks[best].eventId = eventId
        let snapshot = bolusLinks
        lock.unlock()
        scheduleWrite(snapshot, name: "bolus-links.json")
    }

    static func bolusLink(eventId: String) -> (source: String, decisionId: String?)? {
        prepareMemory()
        lock.lock()
        absorbUnsavedLinksLocked()
        let link = bolusLinks.first { $0.eventId == eventId }
        lock.unlock()
        return link.map { ($0.source, $0.decisionId) }
    }

    /// Folds dose-path links into the in-memory list. Caller holds `lock`. No disk IO.
    private static func absorbUnsavedLinksLocked() {
        guard !unsavedLinks.isEmpty else { return }
        bolusLinks.append(contentsOf: unsavedLinks)
        unsavedLinks.removeAll()
        if bolusLinks.count > 200 {
            bolusLinks.removeFirst(bolusLinks.count - 200)
        }
    }

    private static func persistBolusLinks() {
        prepareMemory()
        lock.lock()
        absorbUnsavedLinksLocked()
        let snapshot = bolusLinks
        lock.unlock()
        writeToDisk(snapshot, name: "bolus-links.json")
    }

    // MARK: - Carbs

    static func noteCarbEntered(id: UUID?, at: Date) {
        guard let id else { return }
        prepareMemory()
        lock.lock()
        var stamp = carbStamps[id.uuidString] ?? CarbStamp(enteredAt: nil, editedAt: nil)
        if stamp.enteredAt == nil { stamp.enteredAt = at }
        carbStamps[id.uuidString] = stamp
        trimCarbStampsLocked()
        let snapshot = carbStamps
        lock.unlock()
        scheduleWrite(snapshot, name: "carb-times.json")
    }

    static func noteCarbEdited(previousID: UUID?, newID: UUID?, at: Date) {
        guard let newID else { return }
        prepareMemory()
        lock.lock()
        let previous = previousID.flatMap { carbStamps[$0.uuidString] }
        carbStamps[newID.uuidString] = CarbStamp(enteredAt: previous?.enteredAt, editedAt: at)
        trimCarbStampsLocked()
        let snapshot = carbStamps
        lock.unlock()
        scheduleWrite(snapshot, name: "carb-times.json")
    }

    static func carbTimes(id: String) -> (enteredAt: Date?, editedAt: Date?) {
        prepareMemory()
        lock.lock()
        let stamp = carbStamps[id]
        lock.unlock()
        return (stamp?.enteredAt, stamp?.editedAt)
    }

    // MARK: - Pump

    /// Latest reservoir and pod activation. `0xDEADBEEF` is Omnipod's "above 50 U" sentinel and is dropped.
    static func notePumpSnapshot(reservoirUnits: Double?, podActivatedAt: Date?, at: Date = Date()) {
        lock.lock()
        pumpSnapshot = PumpSnapshot(
            reservoirUnits: usableReservoir(reservoirUnits),
            podActivatedAt: podActivatedAt,
            at: at
        )
        lock.unlock()
    }

    static func notePumpEvent(id: String?, eventType: String, at: Date, alarmKind: String?, alarmMessage: String?) {
        guard let id, !id.isEmpty else { return }
        prepareMemory()
        lock.lock()
        let snapshot = pumpSnapshot
        let recent = snapshot.map { abs($0.at.timeIntervalSince(at)) < 30 * 60 } ?? false
        var note = PumpNote(
            kind: nil,
            message: sanitizedMessage(alarmMessage),
            reservoirUnits: nil,
            podActivatedAt: nil,
            insulinAgeHours: nil
        )
        note.kind = pumpKind(eventType: eventType, alarmKind: alarmKind)
        if recent, let snapshot {
            note.reservoirUnits = snapshot.reservoirUnits
            if let activated = snapshot.podActivatedAt, activated <= at {
                let hours = at.timeIntervalSince(activated) / 3600
                if hours >= 0, hours <= 1000 {
                    note.podActivatedAt = activated
                    note.insulinAgeHours = hours
                }
            }
        }
        let hasContent = note.kind != nil || note.message != nil || note.reservoirUnits != nil || note.podActivatedAt != nil
        if hasContent {
            pumpNotes[id] = note
        }
        if pumpNotes.count > 200 {
            let overflow = pumpNotes.count - 200
            for key in Array(pumpNotes.keys.prefix(overflow)) {
                pumpNotes.removeValue(forKey: key)
            }
        }
        let saved = pumpNotes
        lock.unlock()
        scheduleWrite(saved, name: "pump-notes.json")
    }

    static func pumpExtras(eventId: String, eventType: String, note: String?) -> [String: HealthIngestJSON?] {
        prepareMemory()
        lock.lock()
        let stored = pumpNotes[eventId]
        lock.unlock()
        var fields: [String: HealthIngestJSON?] = [:]
        let alarm = eventType == PumpEventStored.EventType.pumpAlarm.rawValue
        let kind = stored?.kind ?? (alarm ? "alarm" : nil)
        if kind == "alarm" || kind == "alert" {
            fields["kind"] = .string(kind ?? "alarm")
            let message = stored?.message ?? sanitizedMessage(note)
            fields["message"] = message.map { .string($0) }
        }
        if let units = stored?.reservoirUnits {
            fields["reservoirUnits"] = inclusive(units, 0, 500)
        }
        if let activated = stored?.podActivatedAt {
            fields["podActivatedAt"] = .string(HealthIngestTime.string(from: activated))
        }
        if let hours = stored?.insulinAgeHours {
            fields["insulinAgeHours"] = inclusive(hours, 0, 1000)
        }
        return fields
    }

    /// `low_insulin` and `low_power` are alerts. A pump alarm that stops delivery is an alarm.
    static func pumpKind(eventType: String, alarmKind: String?) -> String? {
        let isAlarm = eventType == PumpEventStored.EventType.pumpAlarm.rawValue || alarmKind != nil
        guard isAlarm else { return nil }
        switch alarmKind {
        case "low_insulin", "low_power":
            return "alert"
        default:
            return "alarm"
        }
    }

    static func usableReservoir(_ units: Double?) -> Double? {
        guard let units, units.isFinite, units >= 0, units <= 500 else { return nil }
        return units
    }

    // MARK: - CGM

    static func cgmRecord(at: Date, kind: String, message: String?) -> HealthIngestRecord {
        let payload = HealthIngestJSON.object([
            "timestamp": .string(HealthIngestTime.string(from: at)),
            "kind": .string(kind),
            "message": sanitizedMessage(message).map { .string($0) }
        ])
        return HealthIngestRecord(
            type: HealthIngestType.cgmEvent,
            id: "cgm-event:\(kind):\(HealthIngestTime.string(from: at))",
            start: at,
            end: nil,
            tz: HealthIngestTime.zoneIdentifier,
            payload: payload
        )
    }

    static func storeCGMEvent(at: Date, kind: String?, message: String?) {
        guard let kind else { return }
        if kind == "warmup_start" {
            lock.lock()
            sensorWasWarmup = true
            lock.unlock()
        }
        enqueue(cgmRecord(at: at, kind: kind, message: message))
    }

    /// A reliable reading after warmup becomes `warmup_end`. Other states arrive as plugin events.
    static func noteGlucoseReliability(reliable: Bool, issue: String?) {
        if !reliable {
            if HealthIngestCGM.issueKind(code: issue, fatal: false) == "warmup_start" {
                lock.lock()
                sensorWasWarmup = true
                lock.unlock()
            }
            return
        }
        lock.lock()
        let ending = sensorWasWarmup
        sensorWasWarmup = false
        lock.unlock()
        if ending {
            storeCGMEvent(at: Date(), kind: "warmup_end", message: nil)
        }
    }

    // MARK: - Loop fields

    static func loopFields(
        glucoseMgdl: Double?,
        eventualBg: Double?,
        recommendedBolus: Double?,
        targetMgdl: Double?,
        thresholdMgdl: Double?,
        carbsRequired: Double?,
        crUsed: Double?
    ) -> [String: HealthIngestJSON?] {
        [
            "glucoseMgdl": glucoseMgdl.flatMap { inclusive($0, 0, 2000) },
            "eventualBg": eventualBg.flatMap(finite),
            "recommendedBolus": recommendedBolus.flatMap { inclusive($0, 0, 100) },
            "targetMgdl": targetMgdl.flatMap { inclusive($0, 40, 400) },
            "thresholdMgdl": thresholdMgdl.flatMap { inclusive($0, 40, 400) },
            "carbsRequired": carbsRequired.flatMap { inclusive($0, 0, 2000) },
            "crUsed": crUsed.flatMap { atLeast($0, 0) }
        ]
    }

    // MARK: - Drain

    static func drain(preferences: HealthIngestPreferences) -> [HealthIngestRecord] {
        expireWatchRecommendations()
        prepareMemory()
        lock.lock()
        foldStagedRecordsLocked()
        var leaving: [HealthIngestRecord] = []
        var staying: [HealthIngestRecord] = []
        for record in pending {
            let send: Bool
            switch record.type {
            case HealthIngestType.cgmEvent:
                send = preferences.isOn(.glucose)
            case HealthIngestType.bolusDecision, HealthIngestType.bolusFailure:
                send = preferences.isOn(.insulin)
            default:
                send = true
            }
            if send {
                leaving.append(record)
            } else {
                staying.append(record)
            }
        }
        pending = staying
        let snapshot = leaving.isEmpty ? nil : pending
        lock.unlock()
        if let snapshot {
            scheduleWrite(snapshot, name: "therapy-queue.json")
        }
        return leaving
    }

    static func sanitizedMessage(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let withoutControls = String(raw.unicodeScalars.filter { $0.properties.generalCategory != .control })
        let pattern = "https?://\\S+|\\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\b|\\b[0-9A-Fa-f]{8,}\\b|\\b\\d{6,}\\b"
        let cleaned: String
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(withoutControls.startIndex..., in: withoutControls)
            cleaned = regex.stringByReplacingMatches(in: withoutControls, range: range, withTemplate: "")
        } else {
            cleaned = withoutControls
        }
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= 2000 { return trimmed }
        return String(trimmed.prefix(2000))
    }

    // MARK: - Storage

    private static func enqueue(_ record: HealthIngestRecord) {
        lock.lock()
        stagedRecords.append(record)
        lock.unlock()
        fileQueue.async {
            Self.persistQueue()
        }
    }

    private static func foldStagedRecordsLocked() {
        for record in stagedRecords {
            if let index = pending.firstIndex(where: { $0.id == record.id && $0.type == record.type }) {
                pending[index] = record
            } else {
                pending.append(record)
            }
        }
        stagedRecords.removeAll()
        if pending.count > 80 {
            pending.removeFirst(pending.count - 80)
        }
    }

    private static func persistQueue() {
        prepareMemory()
        lock.lock()
        foldStagedRecordsLocked()
        let snapshot = pending
        lock.unlock()
        writeToDisk(snapshot, name: "therapy-queue.json")
    }

    private static func trimCarbStampsLocked() {
        if carbStamps.count > 400 {
            let overflow = carbStamps.count - 400
            for key in Array(carbStamps.keys.prefix(overflow)) {
                carbStamps.removeValue(forKey: key)
            }
        }
    }

    /// Reads disk outside `lock`, then installs the snapshot. Does not hold `lock` during file IO.
    private static func prepareMemory() {
        lock.lock()
        let needsLoad = !loaded
        lock.unlock()
        guard needsLoad else { return }
        let diskPending = load([HealthIngestRecord].self, name: "therapy-queue.json") ?? []
        let diskCarbs = load([String: CarbStamp].self, name: "carb-times.json") ?? [:]
        let diskLinks = load([BolusLink].self, name: "bolus-links.json") ?? []
        let diskPumps = load([String: PumpNote].self, name: "pump-notes.json") ?? [:]
        lock.lock()
        if !loaded {
            pending = diskPending
            carbStamps = diskCarbs
            bolusLinks = diskLinks
            pumpNotes = diskPumps
            loaded = true
        }
        lock.unlock()
    }

    private static func load<T: Decodable>(_ type: T.Type, name: String) -> T? {
        guard let url = file(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? HealthIngestWire.makeDecoder().decode(type, from: data)
    }

    private static func scheduleWrite(_ value: some Encodable, name: String) {
        fileQueue.async {
            writeToDisk(value, name: name)
        }
    }

    private static func writeToDisk(_ value: some Encodable, name: String) {
        guard let url = file(name), let data = try? HealthIngestWire.makeEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func file(_ name: String) -> URL? {
        guard let directory = folder() else { return nil }
        return directory.appendingPathComponent(name)
    }

    private static func folder() -> URL? {
        if let directoryOverride {
            try? FileManager.default.createDirectory(at: directoryOverride, withIntermediateDirectories: true)
            return directoryOverride
        }
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let directory = base.appendingPathComponent("HealthIngest", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func finite(_ value: Double?) -> HealthIngestJSON? {
        guard let value else { return nil }
        return HealthIngestPayload.finiteNumber(value)
    }

    /// Inclusive range. Out of range and non-finite values are omitted so the server does not reject the record.
    static func inclusive(_ value: Double?, _ min: Double, _ max: Double) -> HealthIngestJSON? {
        guard let value, value.isFinite, value >= min, value <= max else { return nil }
        return .number(value)
    }

    static func atLeast(_ value: Double?, _ min: Double) -> HealthIngestJSON? {
        guard let value, value.isFinite, value >= min else { return nil }
        return .number(value)
    }

    static func exclusiveMin(_ value: Double?, above: Double, through max: Double) -> HealthIngestJSON? {
        guard let value, value.isFinite, value > above, value <= max else { return nil }
        return .number(value)
    }

    private static func decimal(_ value: Decimal) -> Double? {
        let number = NSDecimalNumber(decimal: value).doubleValue
        return number.isFinite ? number : nil
    }
}

enum HealthIngestCGM {
    /// `nil` for transmitter start and end: those events exist to carry a hardware id, which is not sent.
    static func kind(type: String, errorCode: String?, fatal: Bool, failureMessage: String?) -> String? {
        switch type {
        case "sensorStart":
            return "sensor_start"
        case "calibration":
            return "calibration"
        case "sensorEnd":
            return endKind(text: failureMessage)
        case "sensorIssue":
            return issueKind(code: errorCode, fatal: fatal)
        case "transmitterStart", "transmitterEnd":
            return nil
        default:
            return "other"
        }
    }

    static func issueKind(code: String?, fatal: Bool) -> String {
        let code = (code ?? "").lowercased()
        if code.contains("warmup") { return "warmup_start" }
        if code.contains("expir") { return "sensor_expired" }
        if fatal || code.contains("fail") { return "sensor_failed" }
        return "other"
    }

    static func endKind(text: String?) -> String {
        let text = (text ?? "").lowercased()
        if text.contains("fail") { return "sensor_failed" }
        if text.contains("expir") { return "sensor_expired" }
        return "other"
    }
}
