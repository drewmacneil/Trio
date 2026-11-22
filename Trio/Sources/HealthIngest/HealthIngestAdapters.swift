@preconcurrency import CoreData
import Foundation

/// Dexcom and Libre report a floor of 39 mg/dL. Trio clamps anything below that to 39 before it is stored,
/// so a stored 39 is the raw value Trio kept and `low` means it is on that floor.
enum HealthIngestGlucose {
    static let lowFloorMgdl = 39

    static func isLow(mgdl: Int) -> Bool {
        mgdl > 0 && mgdl <= lowFloorMgdl
    }
}

struct HealthIngestReadResult {
    var records: [HealthIngestRecord] = []
    var errors: [String] = []
    /// Record ids currently in storage, only for types that were scanned. An empty set means none remain.
    var liveIDs: [String: Set<String>] = [:]
}

/// Reads Trio storage into ingest records. Upstream storage changes should break here and nowhere else.
struct HealthIngestDiabetesAdapter {
    func records(
        since: Date,
        preferences: HealthIngestPreferences,
        settings: SettingsManager,
        profiles: TherapyProfileStorage,
        pumpModel: String?,
        supportedBasalRates: [Double]
    ) async -> HealthIngestReadResult {
        var result = HealthIngestReadResult()
        let units = settings.settings.units.rawValue

        if preferences.isOn(.glucose) {
            let source = settings.settings.cgmPluginIdentifier.isEmpty
                ? settings.settings.cgm.rawValue
                : settings.settings.cgmPluginIdentifier
            await collect(into: &result, label: "glucose") {
                try await glucoseRecords(since: since, source: source)
            }
            if let ids = try? await liveGlucoseIDs(source: source) {
                result.liveIDs[HealthIngestType.glucose] = ids
            }
        }
        if preferences.isOn(.insulin) || preferences.isOn(.pumpEvents) {
            await collect(into: &result, label: "pump history") {
                try await pumpRecords(since: since, preferences: preferences)
            }
            if let ids = try? await livePumpIDs(preferences: preferences) {
                result.liveIDs.merge(ids) { _, new in new }
            }
        }
        if preferences.isOn(.carbs) {
            await collect(into: &result, label: "carbs") {
                try await carbRecords(since: since)
            }
            if let ids = try? await liveCarbIDs() {
                result.liveIDs[HealthIngestType.carbs] = ids
            }
        }
        if preferences.isOn(.adjustments) {
            await collect(into: &result, label: "overrides") {
                try await overrideRecords(since: since, units: units)
            }
            await collect(into: &result, label: "temp targets") {
                try await tempTargetRecords(since: since, units: units)
            }
        }
        if preferences.isOn(.loopCycles) {
            await collect(into: &result, label: "loop cycles") {
                try await loopRecords(since: since)
            }
        }
        if preferences.isOn(.profilesAndSettings) {
            await collect(into: &result, label: "profiles") {
                try await profileSnapshot(profiles: profiles)
            }
            await collect(into: &result, label: "settings") {
                try await settingsSnapshot(
                    settings: settings,
                    units: units,
                    pumpModel: pumpModel,
                    supportedBasalRates: supportedBasalRates
                )
            }
            await collect(into: &result, label: "profile switches") {
                try await profileSwitches(since: since)
            }
        }
        return result
    }

    private func collect(
        into result: inout HealthIngestReadResult,
        label: String,
        _ body: () async throws -> [HealthIngestRecord]
    ) async {
        do {
            result.records.append(contentsOf: try await body())
        } catch {
            result.errors.append("Could not read \(label)")
            warning(.healthKit, "Health Ingest \(label) read failed", error: error)
        }
    }

    private func glucoseRecords(since: Date, source: String) async throws -> [HealthIngestRecord] {
        let context = CoreDataStack.shared.newTaskContext()
        let request = GlucoseStored.fetchRequest()
        request.predicate = NSPredicate(format: "date >= %@", since as NSDate)
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
        request.fetchBatchSize = 256
        return try await context.perform {
            try context.fetch(request).compactMap { Self.mapGlucose($0, source: $0.isManual ? "manual" : source) }
        }
    }

    private func liveGlucoseIDs(source: String) async throws -> Set<String> {
        let context = CoreDataStack.shared.newTaskContext()
        return try await context.perform {
            let deleted = try context.fetch(DeletedGlucoseStored.fetchRequest())
            let deletedDates = Set(deleted.map(\.date))
            let rows = try context.fetch(GlucoseStored.fetchRequest())
            var ids = Set<String>()
            for row in rows {
                guard let start = row.date, !deletedDates.contains(start) else { continue }
                let rowSource = row.isManual ? "manual" : source
                ids.insert(HealthIngestIdentity.glucose(source: rowSource, start: start))
            }
            return ids
        }
    }

    private func liveCarbIDs() async throws -> Set<String> {
        let context = CoreDataStack.shared.newTaskContext()
        return try await context.perform {
            let rows = try context.fetch(CarbEntryStored.fetchRequest())
            return Set(rows.compactMap { Self.mapCarb($0)?.id })
        }
    }

    private func livePumpIDs(preferences: HealthIngestPreferences) async throws -> [String: Set<String>] {
        let context = CoreDataStack.shared.newTaskContext()
        let includeInsulin = preferences.isOn(.insulin)
        let includeEvents = preferences.isOn(.pumpEvents)
        return try await context.perform {
            let rows = try context.fetch(PumpEventStored.fetchRequest())
            var ids: [String: Set<String>] = [:]
            for row in rows {
                guard let record = Self.mapPump(row, includeInsulin: includeInsulin, includeEvents: includeEvents) else { continue }
                ids[record.type, default: []].insert(record.id)
            }
            if includeInsulin {
                ids[HealthIngestType.bolus] = ids[HealthIngestType.bolus] ?? []
                ids[HealthIngestType.smb] = ids[HealthIngestType.smb] ?? []
                ids[HealthIngestType.tempBasal] = ids[HealthIngestType.tempBasal] ?? []
            }
            if includeEvents {
                ids[HealthIngestType.pumpEvent] = ids[HealthIngestType.pumpEvent] ?? []
            }
            return ids
        }
    }

    private func pumpRecords(since: Date, preferences: HealthIngestPreferences) async throws -> [HealthIngestRecord] {
        let context = CoreDataStack.shared.newTaskContext()
        let request = PumpEventStored.fetchRequest()
        request.predicate = NSPredicate(format: "timestamp >= %@", since as NSDate)
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
        request.relationshipKeyPathsForPrefetching = ["bolus", "tempBasal"]
        request.fetchBatchSize = 128
        let includeInsulin = preferences.isOn(.insulin)
        let includeEvents = preferences.isOn(.pumpEvents)
        return try await context.perform {
            try context.fetch(request).compactMap { event in
                Self.mapPump(event, includeInsulin: includeInsulin, includeEvents: includeEvents)
            }
        }
    }

    private func carbRecords(since: Date) async throws -> [HealthIngestRecord] {
        let context = CoreDataStack.shared.newTaskContext()
        let request = CarbEntryStored.fetchRequest()
        request.predicate = NSPredicate(format: "date >= %@", since as NSDate)
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
        request.fetchBatchSize = 128
        return try await context.perform {
            try context.fetch(request).compactMap(Self.mapCarb)
        }
    }

    private func overrideRecords(since: Date, units: String) async throws -> [HealthIngestRecord] {
        let context = CoreDataStack.shared.newTaskContext()
        return try await context.perform {
            let runs = try Self.fetchRuns(since: since, in: context)
            let runParents = Set(runs.compactMap { $0.override?.objectID })
            let overrides = try Self.fetchOverrides(since: since, in: context)
            let fromRuns = runs.compactMap { Self.mapOverrideRun($0, units: units) }
            let fromOverrides = overrides.compactMap { row -> HealthIngestRecord? in
                if row.isPreset || runParents.contains(row.objectID) || row.overrideRun != nil { return nil }
                return Self.mapOverride(row, units: units)
            }
            return fromRuns + fromOverrides
        }
    }

    private func tempTargetRecords(since: Date, units: String) async throws -> [HealthIngestRecord] {
        let context = CoreDataStack.shared.newTaskContext()
        return try await context.perform {
            let runs = try Self.fetchTempTargetRuns(since: since, in: context)
            let runParents = Set(runs.compactMap { $0.tempTarget?.objectID })
            let targets = try Self.fetchTempTargets(since: since, in: context)
            let fromRuns = runs.compactMap { Self.mapTempTargetRun($0, units: units) }
            let fromTargets = targets.compactMap { row -> HealthIngestRecord? in
                if row.isPreset || runParents.contains(row.objectID) || row.tempTargetRun != nil { return nil }
                return Self.mapTempTarget(row, units: units)
            }
            return fromRuns + fromTargets
        }
    }

    private func loopRecords(since: Date) async throws -> [HealthIngestRecord] {
        let context = CoreDataStack.shared.newTaskContext()
        let request = OrefDetermination.fetchRequest()
        request.predicate = NSPredicate(format: "deliverAt >= %@ OR timestamp >= %@", since as NSDate, since as NSDate)
        request.sortDescriptors = [NSSortDescriptor(key: "deliverAt", ascending: true)]
        request.relationshipKeyPathsForPrefetching = ["forecasts", "forecasts.forecastValues"]
        request.fetchBatchSize = 32
        return try await context.perform {
            try context.fetch(request).compactMap(Self.mapLoop)
        }
    }

    private func profileSnapshot(profiles: TherapyProfileStorage) async throws -> [HealthIngestRecord] {
        let stored = try await profiles.fetchProfiles()
        let payload = Self.profilePayload(stored)
        return [Self.addressed(type: HealthIngestType.profileSnapshot, prefix: HealthIngestWire.profileIDPrefix, payload: payload)]
    }

    private func settingsSnapshot(
        settings: SettingsManager,
        units: String,
        pumpModel: String?,
        supportedBasalRates: [Double]
    ) async throws -> [HealthIngestRecord] {
        let pump = settings.pumpSettings
        var pumpFields: [String: HealthIngestJSON?] = [
            "diaHours": HealthIngestPayload.diaHours(Self.double(pump.insulinActionCurve)),
            "maxBolus": .number(max(Self.double(pump.maxBolus), 0)),
            "maxBasal": .number(max(Self.double(pump.maxBasal), 0))
        ]
        if let pumpModel, !pumpModel.isEmpty {
            pumpFields["pumpModel"] = .string(pumpModel)
        }
        if !supportedBasalRates.isEmpty {
            pumpFields["supportedBasalRates"] = .array(supportedBasalRates.map { .number($0) })
        }
        let payload = HealthIngestJSON.object([
            "values": .object([
                "preferences": HealthIngestWire.jsonValue(settings.preferences),
                "pumpSettings": .object(pumpFields),
                "trioSettings": HealthIngestWire.jsonValue(settings.settings)
            ])
        ])
        return [Self.addressed(type: HealthIngestType.settingsSnapshot, prefix: HealthIngestWire.settingsIDPrefix, payload: payload)]
    }

    private func profileSwitches(since: Date) async throws -> [HealthIngestRecord] {
        let context = CoreDataStack.shared.newTaskContext()
        return try await context.perform {
            let request = TherapyProfileSwitchStored.fetchRequest()
            request.predicate = NSPredicate(format: "date >= %@", since as NSDate)
            return try context.fetch(request).compactMap { row -> HealthIngestRecord? in
                guard let date = row.date, let name = row.name, !name.isEmpty else { return nil }
                let trigger = Self.switchTrigger(row.trigger)
                let payload = HealthIngestJSON.object([
                    "date": .string(HealthIngestTime.string(from: date)),
                    "name": .string(name),
                    "trigger": .string(trigger)
                ])
                let safeName = HealthIngestRecordID.component(name)
                return Self.record(
                    type: HealthIngestType.profileSwitch,
                    id: "profile-switch:\(HealthIngestTime.string(from: date)):\(safeName)",
                    start: date,
                    end: nil,
                    payload: payload
                )
            }
        }
    }

    private static func fetchRuns(since: Date, in context: NSManagedObjectContext) throws -> [OverrideRunStored] {
        let request = OverrideRunStored.fetchRequest()
        request.predicate = NSPredicate(format: "startDate >= %@ OR endDate >= %@", since as NSDate, since as NSDate)
        request.relationshipKeyPathsForPrefetching = ["override"]
        return try context.fetch(request)
    }

    private static func fetchOverrides(since: Date, in context: NSManagedObjectContext) throws -> [OverrideStored] {
        let request = OverrideStored.fetchRequest()
        request.predicate = NSPredicate(format: "isPreset == NO AND date >= %@", since as NSDate)
        request.relationshipKeyPathsForPrefetching = ["overrideRun"]
        return try context.fetch(request)
    }

    private static func fetchTempTargetRuns(since: Date, in context: NSManagedObjectContext) throws -> [TempTargetRunStored] {
        let request = TempTargetRunStored.fetchRequest()
        request.predicate = NSPredicate(format: "startDate >= %@ OR endDate >= %@", since as NSDate, since as NSDate)
        request.relationshipKeyPathsForPrefetching = ["tempTarget"]
        return try context.fetch(request)
    }

    private static func fetchTempTargets(since: Date, in context: NSManagedObjectContext) throws -> [TempTargetStored] {
        let request = TempTargetStored.fetchRequest()
        request.predicate = NSPredicate(format: "isPreset == NO AND date >= %@", since as NSDate)
        request.relationshipKeyPathsForPrefetching = ["tempTargetRun"]
        return try context.fetch(request)
    }

    static func mapGlucose(_ row: GlucoseStored, source: String) -> HealthIngestRecord? {
        guard let start = row.date else { return nil }
        let mgdl = Int(row.glucose)
        let payload = HealthIngestJSON.object([
            "mgdl": .number(Double(mgdl)),
            "low": .bool(HealthIngestGlucose.isLow(mgdl: mgdl)),
            "direction": row.direction.map { .string($0) },
            "manual": row.isManual ? .bool(true) : nil,
            "smoothedMgdl": row.smoothedGlucose.flatMap { value in
                value.doubleValue == 0 ? nil : .decimal(value)
            }
        ])
        return record(
            type: HealthIngestType.glucose,
            id: HealthIngestIdentity.glucose(source: source, start: start),
            start: start,
            end: nil,
            payload: payload
        )
    }

    static func mapPump(
        _ event: PumpEventStored,
        includeInsulin: Bool,
        includeEvents: Bool
    ) -> HealthIngestRecord? {
        guard let start = event.timestamp else { return nil }
        let sourceID = event.id ?? event.syncIdentifier ?? "pump-\(Int(start.timeIntervalSince1970))-\(event.type ?? "")"
        let type = event.type ?? ""
        if type == PumpEventStored.EventType.bolus.rawValue {
            guard includeInsulin else { return nil }
            return mapBolus(event, sourceID: sourceID, start: start)
        }
        if type == PumpEventStored.EventType.tempBasal.rawValue {
            guard includeInsulin else { return nil }
            return mapTempBasal(event, sourceID: sourceID, start: start)
        }
        guard includeEvents else { return nil }
        let payload = HealthIngestJSON.object([
            "event": .string(Self.pumpEventName(type)),
            "note": event.note.flatMap { $0.isEmpty ? nil : .string($0) }
        ])
        return record(type: HealthIngestType.pumpEvent, id: sourceID, start: start, end: nil, payload: payload)
    }

    private static func mapBolus(_ event: PumpEventStored, sourceID: String, start: Date) -> HealthIngestRecord {
        let bolus = event.bolus
        let smb = bolus?.isSMB ?? false
        let payload = HealthIngestJSON.object([
            "units": .decimal(bolus?.amount) ?? .number(0),
            "programmedUnits": .decimal(bolus?.programmedAmount),
            "external": (bolus?.isExternal == true) ? .bool(true) : nil,
            "programmedByPumpUI": (bolus?.isProgrammedByPumpUI == true) ? .bool(true) : nil,
            "isMutable": .bool(event.isMutable),
            "peakTime": Self.positiveNumber(event.peakTime),
            "actionDuration": Self.positiveNumber(event.actionDuration),
            "insulinType": event.insulinType.flatMap { $0.isEmpty ? nil : .string($0) }
        ])
        return record(
            type: smb ? HealthIngestType.smb : HealthIngestType.bolus,
            id: sourceID,
            start: start,
            end: nil,
            payload: payload
        )
    }

    private static func mapTempBasal(_ event: PumpEventStored, sourceID: String, start: Date) -> HealthIngestRecord {
        let temp = event.tempBasal
        let scheduled = temp?.isScheduledBasal ?? false
        let end = scheduled ? nil : temp?.endDate
        let payload = HealthIngestJSON.object([
            "rate": .number(temp?.rate?.doubleValue ?? 0),
            "durationMinutes": .number(Double(temp?.duration ?? 0)),
            "automatic": scheduled ? nil : .bool(true),
            "deliveredUnits": .decimal(temp?.deliveredUnits),
            "insulinType": event.insulinType.flatMap { $0.isEmpty ? nil : .string($0) }
        ])
        return record(
            type: HealthIngestType.tempBasal,
            id: sourceID,
            start: temp?.startDate ?? start,
            end: end == start ? nil : end,
            payload: payload
        )
    }

    static func mapCarb(_ row: CarbEntryStored) -> HealthIngestRecord? {
        guard let start = row.date else { return nil }
        let sourceID = row.id?.uuidString ?? "carb-\(Int(start.timeIntervalSince1970))-\(row.carbs)"
        let fat: HealthIngestJSON? = row.fat > 0 ? .number(row.fat) : nil
        let protein: HealthIngestJSON? = row.protein > 0 ? .number(row.protein) : nil
        let note: HealthIngestJSON? = row.note.flatMap { note in note.isEmpty ? nil : .string(note) }
        let fpu: HealthIngestJSON? = row.isFPU ? .bool(true) : nil
        let fpuID: HealthIngestJSON? = row.fpuID.map { .string($0.uuidString) }
        let payload = HealthIngestJSON.object([
            "grams": .number(row.carbs),
            "fatGrams": fat,
            "proteinGrams": protein,
            "note": note,
            "isFPU": fpu,
            "fpuID": fpuID
        ])
        return record(type: HealthIngestType.carbs, id: sourceID, start: start, end: nil, payload: payload)
    }

    private static func mapOverrideRun(_ run: OverrideRunStored, units: String) -> HealthIngestRecord? {
        guard let start = run.startDate ?? run.override?.date else { return nil }
        let parent = run.override
        let sourceID = parent?.id ?? run.id?.uuidString ?? "override-run-\(Int(start.timeIntervalSince1970))"
        return overrideRecord(
            sourceID: sourceID,
            start: start,
            end: run.endDate,
            name: run.name ?? parent?.name,
            percentage: parent?.percentage,
            duration: parent?.duration,
            indefinite: parent?.indefinite ?? false,
            enabled: parent?.enabled ?? false,
            target: run.target ?? parent?.target,
            smbOff: parent?.smbIsOff ?? false,
            units: units,
            phase: "completed",
            advanced: parent
        )
    }

    private static func mapOverride(_ row: OverrideStored, units: String) -> HealthIngestRecord? {
        guard let start = row.date, let sourceID = row.id else { return nil }
        let end = ending(start: start, minutes: row.duration?.decimalValue, indefinite: row.indefinite)
        return overrideRecord(
            sourceID: sourceID,
            start: start,
            end: end,
            name: row.name,
            percentage: row.percentage,
            duration: row.duration,
            indefinite: row.indefinite,
            enabled: row.enabled,
            target: row.target,
            smbOff: row.smbIsOff,
            units: units,
            phase: row.enabled ? "active" : "inactive",
            advanced: row
        )
    }

    private static func overrideRecord(
        sourceID: String,
        start: Date,
        end: Date?,
        name: String?,
        percentage: Double?,
        duration: NSDecimalNumber?,
        indefinite: Bool,
        enabled: Bool,
        target: NSDecimalNumber?,
        smbOff: Bool,
        units: String,
        phase: String,
        advanced: OverrideStored?
    ) -> HealthIngestRecord {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let schedule = Self.smbWindow(advanced)
        let payload = HealthIngestJSON.object([
            "name": (trimmedName?.isEmpty == false) ? .string(trimmedName!) : nil,
            "multiplier": HealthIngestPayload.unitMultiplier(percentage: percentage),
            "targetMgdl": target.map { .number(HealthIngestCanonicalJSON.mgdl($0.doubleValue, units: units)) },
            "durationMinutes": Self.positiveNumber(duration),
            "indefinite": indefinite ? .bool(true) : .bool(false),
            "active": .bool(enabled),
            "smbIsOff": smbOff ? .bool(true) : nil,
            "smbIsScheduledOff": schedule == nil ? nil : .bool(true),
            "smbScheduledStart": schedule.map { .string($0.start) },
            "smbScheduledEnd": schedule.map { .string($0.end) },
            "isf": (advanced?.isf == true) ? .bool(true) : nil,
            "cr": (advanced?.cr == true) ? .bool(true) : nil,
            "smbMinutes": .decimal(advanced?.smbMinutes),
            "uamMinutes": .decimal(advanced?.uamMinutes),
            "phase": .string(phase)
        ])
        return record(
            type: HealthIngestType.override,
            id: sourceID,
            start: start,
            end: end,
            payload: payload
        )
    }

    private static func mapTempTargetRun(_ run: TempTargetRunStored, units: String) -> HealthIngestRecord? {
        guard let start = run.startDate ?? run.tempTarget?.date else { return nil }
        let parent = run.tempTarget
        let sourceID = parent?.id?.uuidString ?? run.id?.uuidString ?? "temp-target-run-\(Int(start.timeIntervalSince1970))"
        return tempTargetRecord(
            sourceID: sourceID,
            start: start,
            end: run.endDate,
            name: run.name ?? parent?.name,
            target: run.target ?? parent?.target,
            duration: parent?.duration,
            enabled: parent?.enabled ?? false,
            halfBasal: parent?.halfBasalTarget,
            units: units,
            phase: "completed"
        )
    }

    private static func mapTempTarget(_ row: TempTargetStored, units: String) -> HealthIngestRecord? {
        guard let start = row.date else { return nil }
        let sourceID = row.id?.uuidString ?? "temp-target-\(Int(start.timeIntervalSince1970))"
        let end = ending(start: start, minutes: row.duration?.decimalValue, indefinite: false)
        return tempTargetRecord(
            sourceID: sourceID,
            start: start,
            end: end,
            name: row.name,
            target: row.target,
            duration: row.duration,
            enabled: row.enabled,
            halfBasal: row.halfBasalTarget,
            units: units,
            phase: row.enabled ? "active" : "inactive"
        )
    }

    private static func tempTargetRecord(
        sourceID: String,
        start: Date,
        end: Date?,
        name: String?,
        target: NSDecimalNumber?,
        duration: NSDecimalNumber?,
        enabled: Bool,
        halfBasal: NSDecimalNumber?,
        units: String,
        phase: String
    ) -> HealthIngestRecord {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = HealthIngestJSON.object([
            "name": (trimmedName?.isEmpty == false) ? .string(trimmedName!) : nil,
            "targetMgdl": target.map { .number(HealthIngestCanonicalJSON.mgdl($0.doubleValue, units: units)) },
            "durationMinutes": Self.positiveNumber(duration),
            "halfBasalTarget": halfBasal.map { .number(HealthIngestCanonicalJSON.mgdl($0.doubleValue, units: units)) },
            "phase": .string(phase),
            "enabled": .bool(enabled)
        ])
        return record(
            type: HealthIngestType.tempTarget,
            id: sourceID,
            start: start,
            end: end,
            payload: payload
        )
    }

    private static func mapLoop(_ row: OrefDetermination) -> HealthIngestRecord? {
        let start = row.deliverAt ?? row.timestamp
        guard let start else { return nil }
        let curves = ["iob", "cob", "zt", "uam"]
        var predictions: [String: HealthIngestJSON] = [:]
        for name in curves {
            let values = (row.forecasts ?? []).first { $0.type == name }?
                .forecastValuesArray
                .map { HealthIngestJSON.number(Double($0.value)) } ?? []
            predictions[name] = .array(values)
        }
        let note = HealthIngestLoopCapture.lookup(start: start)
        var determinationFields: [String: HealthIngestJSON?] = [
            "reason": row.reason.map { .string($0) } ?? .null,
            "iob": .decimal(row.iob),
            "cob": .number(Double(row.cob)),
            "eventualBG": .decimal(row.eventualBG),
            "sensitivityRatio": .decimal(row.sensitivityRatio),
            "insulinReq": .decimal(row.insulinReq),
            "rate": .decimal(row.rate),
            "duration": .decimal(row.duration),
            "units": .decimal(row.bolus),
            "smb": .decimal(row.smbToDeliver),
            "minDelta": .decimal(row.minDelta),
            "expectedDelta": .decimal(row.expectedDelta),
            "scheduledBasal": .decimal(row.scheduledBasal),
            "received": .bool(row.received),
            "predBGs": .object([
                "IOB": predictions["iob"],
                "COB": predictions["cob"],
                "UAM": predictions["uam"],
                "ZT": predictions["zt"]
            ])
        ]
        if let extra = note?.determination {
            for (key, value) in extra {
                determinationFields[key] = value
            }
        }
        let enacted = Self.enactedPayload(row)
        let payload = Self.loopPayload(
            row: row,
            predictions: predictions,
            determination: .object(determinationFields),
            enacted: enacted,
            note: note
        )
        return record(
            type: HealthIngestType.loopCycle,
            id: HealthIngestIdentity.loop(start: start),
            start: start,
            end: row.timestampEnacted,
            payload: payload
        )
    }

    private static func profilePayload(_ stored: StoredTherapyProfiles) -> HealthIngestJSON {
        var profiles: [HealthIngestJSON] = stored.inactiveProfiles.map { profileJSON($0) }
        if let active = stored.activeProfileValues {
            profiles.append(profileJSON(active))
        }
        let activeName = stored.activeProfileName ?? stored.activeProfileValues?.name ?? TrioTherapyProfile.defaultName
        if profiles.isEmpty {
            profiles.append(.object([
                "name": .string(activeName),
                "basal": .array([.object(["start": .string("00:00"), "rate": .number(0)])])
            ]))
        }
        return .object([
            "activeProfileName": .string(activeName),
            "profiles": .array(profiles)
        ])
    }

    private static func profileJSON(_ profile: TrioTherapyProfile) -> HealthIngestJSON {
        .object([
            "name": .string(profile.name),
            "basal": .array(profile.basal.map { entry in
                .object([
                    "start": .string(HealthIngestCanonicalJSON.clock(seconds: entry.seconds)),
                    "rate": .number(Self.double(entry.value))
                ])
            }),
            "carbRatio": .array(profile.carbRatio.map { entry in
                .object([
                    "start": .string(HealthIngestCanonicalJSON.clock(seconds: entry.seconds)),
                    "gramsPerUnit": .number(max(Self.double(entry.value), 0))
                ])
            }),
            "isf": .array(profile.sensitivity.map { entry in
                .object([
                    "start": .string(HealthIngestCanonicalJSON.clock(seconds: entry.seconds)),
                    "mgdlPerUnit": .number(max(Self.double(entry.value), 0))
                ])
            }),
            "target": .array(profile.target.map { entry in
                .object([
                    "start": .string(HealthIngestCanonicalJSON.clock(seconds: entry.seconds)),
                    "lowMgdl": .number(Self.double(entry.low)),
                    "highMgdl": .number(Self.double(entry.high))
                ])
            })
        ])
    }

    private static func ending(start: Date, minutes: Decimal?, indefinite: Bool) -> Date? {
        if indefinite { return nil }
        guard let minutes, minutes > 0 else { return nil }
        let seconds = NSDecimalNumber(decimal: minutes * 60).doubleValue
        guard seconds.isFinite, seconds > 0 else { return nil }
        return start.addingTimeInterval(seconds)
    }

    private static func enactedPayload(_ row: OrefDetermination) -> HealthIngestJSON {
        guard row.enacted else { return .null }
        let smb: HealthIngestJSON? = .decimal(row.smbToDeliver)
        let rate: HealthIngestJSON? = .decimal(row.rate)
        let minutes: HealthIngestJSON? = Self.positiveNumber(row.duration)
        let bolus: HealthIngestJSON? = .decimal(row.bolus)
        return .object([
            "smbUnits": smb,
            "tempBasalRate": rate,
            "tempBasalDurationMinutes": minutes,
            "bolusUnits": bolus
        ])
    }

    private static func loopPayload(
        row: OrefDetermination,
        predictions: [String: HealthIngestJSON],
        determination: HealthIngestJSON,
        enacted: HealthIngestJSON,
        note: HealthIngestLoopCapture.Note?
    ) -> HealthIngestJSON {
        let iob: HealthIngestJSON = .decimal(row.iob) ?? .number(0)
        let cob: HealthIngestJSON = .number(Double(row.cob))
        let isf: HealthIngestJSON = .decimal(row.insulinSensitivity) ?? .null
        let ratio: HealthIngestJSON = .decimal(row.sensitivityRatio) ?? .number(1)
        let reason: HealthIngestJSON = row.reason.map { .string($0) } ?? .null
        let zone = note?.timeZone ?? HealthIngestTime.zoneIdentifier
        return .object([
            "iob": iob,
            "cob": cob,
            "isf": isf,
            "autosensRatio": ratio,
            "autosensRaw": note?.autosensRaw.map { .number($0) },
            "determination": determination,
            "reason": reason,
            "predictions": .object(predictions),
            "enacted": enacted,
            "effectiveProfileId": note?.effectiveProfileId.map { .string($0) },
            "timeZone": .string(zone),
            "appGitSha": HealthIngestBuild.gitSha.map { .string($0) },
            "dynamicIsf": note?.dynamicIsf,
            "iobBreakdown": note?.iobBreakdown,
            "meal": note?.meal
        ])
    }

    private static func addressed(type: String, prefix: String, payload: HealthIngestJSON) -> HealthIngestRecord {
        record(
            type: type,
            id: HealthIngestCanonicalJSON.contentID(prefix: prefix, payload: payload),
            start: Date(),
            end: nil,
            payload: payload
        )
    }

    private static func double(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }

    private static func switchTrigger(_ raw: String?) -> String {
        let folded = (raw ?? "manual").lowercased().map { character -> Character in
            if character.isLetter || character.isNumber || character == "_" || character == "-" { return character }
            return "_"
        }
        var text = String(folded).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        while text.contains("__") { text = text.replacingOccurrences(of: "__", with: "_") }
        guard let first = text.first, first.isLetter else { return "manual" }
        return String(text.prefix(64))
    }

    private static func pumpEventName(_ raw: String) -> String {
        switch raw {
        case "SiteChange",
             "Site Change": return "site_change"
        case "PumpSuspend": return "suspend"
        case "PumpResume": return "resume"
        case "PumpAlarm": return "alarm"
        case "PumpBattery",
             "Pump Battery Change": return "battery_change"
        case "Insulin Change": return "reservoir_change"
        case "Rewind": return "rewind"
        case "Prime": return "prime"
        default:
            break
        }
        let folded = raw.lowercased().map { character -> Character in
            if character.isLetter || character.isNumber { return character }
            return "_"
        }
        var text = String(folded)
        while text.contains("__") {
            text = text.replacingOccurrences(of: "__", with: "_")
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        guard let first = text.first, first.isLetter || first.isNumber, text.count <= 64 else { return "other" }
        return text
    }

    private static func positiveNumber(_ value: NSDecimalNumber?) -> HealthIngestJSON? {
        guard let value, value.doubleValue > 0 else { return nil }
        return .number(value.doubleValue)
    }

    private static func smbWindow(_ row: OverrideStored?) -> (start: String, end: String)? {
        guard row?.smbIsScheduledOff == true,
              let start = row?.start.flatMap({ HealthIngestCanonicalJSON.clock(hour: $0.decimalValue) }),
              let end = row?.end.flatMap({ HealthIngestCanonicalJSON.clock(hour: $0.decimalValue) })
        else { return nil }
        return (start, end)
    }

    private static func record(
        type: String,
        id: String,
        start: Date,
        end: Date?,
        payload: HealthIngestJSON
    ) -> HealthIngestRecord {
        HealthIngestRecord(
            type: type,
            id: HealthIngestRecordID.sanitize(id),
            start: start,
            end: end,
            tz: HealthIngestTime.zoneIdentifier,
            payload: payload
        )
    }
}
