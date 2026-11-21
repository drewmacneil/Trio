import CoreData
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
}

/// Reads Trio storage into ingest records. Upstream storage changes should break here and nowhere else.
struct HealthIngestDiabetesAdapter {
    func records(
        since: Date,
        preferences: HealthIngestPreferences,
        settings: SettingsManager,
        profiles: TherapyProfileStorage
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
        }
        if preferences.isOn(.insulin) || preferences.isOn(.pumpEvents) {
            await collect(into: &result, label: "pump history") {
                try await pumpRecords(since: since, preferences: preferences)
            }
        }
        if preferences.isOn(.carbs) {
            await collect(into: &result, label: "carbs") {
                try await carbRecords(since: since)
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
                try await profileSnapshot(profiles: profiles, units: units)
            }
            await collect(into: &result, label: "settings") {
                try await settingsSnapshot(settings: settings, units: units)
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

    private func profileSnapshot(profiles: TherapyProfileStorage, units: String) async throws -> [HealthIngestRecord] {
        let stored = try await profiles.fetchProfiles()
        let payload = Self.profilePayload(stored, units: units)
        let record = HealthIngestRecord(
            type: HealthIngestType.profileSnapshot,
            id: HealthIngestWire.profileSnapshotID,
            start: Date(),
            end: nil,
            tz: HealthIngestTime.zoneIdentifier,
            payload: payload
        )
        return [record]
    }

    private func settingsSnapshot(settings: SettingsManager, units: String) async throws -> [HealthIngestRecord] {
        let presets = try await presetPayloads()
        let payload = HealthIngestJSON.object([
            "settingsUnits": .string(units),
            "trioSettings": HealthIngestWire.jsonValue(settings.settings),
            "preferences": HealthIngestWire.jsonValue(settings.preferences),
            "pumpSettings": HealthIngestWire.jsonValue(settings.pumpSettings),
            "overridePresets": .array(presets.overrides),
            "tempTargetPresets": .array(presets.tempTargets)
        ])
        return [
            HealthIngestRecord(
                type: HealthIngestType.settingsSnapshot,
                id: HealthIngestWire.settingsSnapshotID,
                start: Date(),
                end: nil,
                tz: HealthIngestTime.zoneIdentifier,
                payload: payload
            )
        ]
    }

    private func presetPayloads() async throws -> (overrides: [HealthIngestJSON], tempTargets: [HealthIngestJSON]) {
        let context = CoreDataStack.shared.newTaskContext()
        return try await context.perform {
            let overrides = try context.fetch(Self.presetRequest(OverrideStored.self)).map(Self.overridePresetJSON)
            let targets = try context.fetch(Self.presetRequest(TempTargetStored.self)).map(Self.tempTargetPresetJSON)
            return (overrides, targets)
        }
    }

    private static func presetRequest<T: NSManagedObject>(_ type: T.Type) -> NSFetchRequest<T> {
        let request = NSFetchRequest<T>(entityName: String(describing: type))
        request.predicate = NSPredicate(format: "isPreset == YES")
        return request
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
            "pumpEventType": .string(type),
            "note": event.note.map { .string($0) },
            "sourceId": .string(sourceID)
        ])
        return record(type: HealthIngestType.pumpEvent, id: sourceID, start: start, end: nil, payload: payload)
    }

    private static func mapBolus(_ event: PumpEventStored, sourceID: String, start: Date) -> HealthIngestRecord {
        let bolus = event.bolus
        let smb = bolus?.isSMB ?? false
        let payload = HealthIngestJSON.object([
            "units": .decimal(bolus?.amount),
            "programmedUnits": .decimal(bolus?.programmedAmount),
            "external": (bolus?.isExternal == true) ? .bool(true) : nil,
            "programmedByPumpUI": (bolus?.isProgrammedByPumpUI == true) ? .bool(true) : nil,
            "insulinType": event.insulinType.map { .string($0) }
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
            "scheduledBasal": scheduled ? .bool(true) : nil,
            "deliveredUnits": .decimal(temp?.deliveredUnits),
            "insulinType": event.insulinType.map { .string($0) }
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
        let payload = HealthIngestJSON.object([
            "grams": .number(row.carbs),
            "fatGrams": row.fat > 0 ? .number(row.fat) : nil,
            "proteinGrams": row.protein > 0 ? .number(row.protein) : nil,
            "note": row.note.flatMap { $0.isEmpty ? nil : .string($0) },
            "isFPU": row.isFPU ? .bool(true) : nil,
            "fpuID": row.fpuID?.uuidString.map { .string($0) }
        ])
        return record(type: HealthIngestType.carbs, id: sourceID, start: start, end: nil, payload: payload)
    }

    private static func mapOverrideRun(_ run: OverrideRunStored, units _: String) -> HealthIngestRecord? {
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

    private static func mapOverride(_ row: OverrideStored, units _: String) -> HealthIngestRecord? {
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
        units _: String,
        phase: String,
        advanced: OverrideStored?
    ) -> HealthIngestRecord {
        let payload = HealthIngestJSON.object([
            "name": name.map { .string($0) },
            "percentage": percentage.map { .number($0) },
            "durationMinutes": .decimal(duration),
            "indefinite": indefinite ? .bool(true) : nil,
            "enabled": .bool(enabled),
            "target": .decimal(target),
            "smbOff": smbOff ? .bool(true) : nil,
            "isf": (advanced?.isf == true) ? .bool(true) : nil,
            "cr": (advanced?.cr == true) ? .bool(true) : nil,
            "isfAndCr": (advanced?.isfAndCr == true) ? .bool(true) : nil,
            "advancedSettings": (advanced?.advancedSettings == true) ? .bool(true) : nil,
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

    private static func mapTempTargetRun(_ run: TempTargetRunStored, units _: String) -> HealthIngestRecord? {
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

    private static func mapTempTarget(_ row: TempTargetStored, units _: String) -> HealthIngestRecord? {
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
        units _: String,
        phase: String
    ) -> HealthIngestRecord {
        let payload = HealthIngestJSON.object([
            "name": name.map { .string($0) },
            "target": .decimal(target),
            "durationMinutes": .decimal(duration),
            "enabled": .bool(enabled),
            "halfBasalTarget": .decimal(halfBasal),
            "phase": .string(phase)
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
        let determination = HealthIngestJSON.object([
            "bg": .decimal(row.glucose),
            "eventualBG": .decimal(row.eventualBG),
            "insulinReq": .decimal(row.insulinReq),
            "carbsRequired": .number(Double(row.carbsRequired)),
            "rate": .decimal(row.rate),
            "durationMinutes": .decimal(row.duration),
            "smb": .decimal(row.smbToDeliver),
            "bolus": .decimal(row.bolus),
            "temp": row.temp.map { .string($0) },
            "currentTarget": .decimal(row.currentTarget),
            "carbRatio": .decimal(row.carbRatio),
            "reservoir": .decimal(row.reservoir),
            "threshold": .decimal(row.threshold)
        ])
        let enacted: HealthIngestJSON = row.enacted
            ? .object([
                "at": row.timestampEnacted.map { .string(HealthIngestTime.string(from: $0)) },
                "rate": .decimal(row.rate),
                "durationMinutes": .decimal(row.duration),
                "smb": .decimal(row.smbToDeliver),
                "temp": row.temp.map { .string($0) }
            ])
            : .null
        let payload = HealthIngestJSON.object([
            "iob": .decimal(row.iob),
            "cob": .number(Double(row.cob)),
            "isf": .decimal(row.insulinSensitivity),
            "autosensRatio": .decimal(row.sensitivityRatio),
            "determination": determination,
            "reason": row.reason.map { .string($0) },
            "predictions": .object(predictions),
            "enacted": enacted
        ])
        return record(
            type: HealthIngestType.loopCycle,
            id: HealthIngestIdentity.loop(start: start),
            start: start,
            end: row.timestampEnacted,
            payload: payload
        )
    }

    private static func profilePayload(_ stored: StoredTherapyProfiles, units: String) -> HealthIngestJSON {
        var profiles: [HealthIngestJSON] = stored.inactiveProfiles.map { profileJSON($0, active: false) }
        if let active = stored.activeProfileValues {
            profiles.append(profileJSON(active, active: true))
        } else if let name = stored.activeProfileName {
            profiles.append(.object(["name": .string(name), "active": .bool(true)]))
        }
        let switches = stored.scheduledSwitches.map { entry in
            HealthIngestJSON.object([
                "profileName": .string(entry.profileName),
                "weekday": .number(Double(entry.weekday)),
                "time": .number(Double(entry.time)),
                "paused": .bool(entry.paused)
            ])
        }
        return .object([
            "settingsUnits": .string(units),
            "activeProfileName": stored.activeProfileName.map { .string($0) },
            "profiles": .array(profiles),
            "scheduledSwitches": .array(switches)
        ])
    }

    private static func profileJSON(_ profile: TrioTherapyProfile, active: Bool) -> HealthIngestJSON {
        .object([
            "name": .string(profile.name),
            "active": .bool(active),
            "basal": schedule(profile.basal),
            "carbRatio": schedule(profile.carbRatio),
            "sensitivity": schedule(profile.sensitivity),
            "target": .array(profile.target.map { entry in
                .object([
                    "seconds": .number(Double(entry.seconds)),
                    "low": .decimal(entry.low),
                    "high": .decimal(entry.high)
                ])
            })
        ])
    }

    private static func schedule(_ entries: [TherapyScheduleEntry]) -> HealthIngestJSON {
        .array(entries.map { entry in
            .object([
                "seconds": .number(Double(entry.seconds)),
                "value": .decimal(entry.value)
            ])
        })
    }

    private static func overridePresetJSON(_ row: OverrideStored) -> HealthIngestJSON {
        .object([
            "name": row.name.map { .string($0) },
            "percentage": .number(row.percentage),
            "durationMinutes": .decimal(row.duration),
            "indefinite": .bool(row.indefinite),
            "target": .decimal(row.target),
            "smbOff": .bool(row.smbIsOff),
            "isf": .bool(row.isf),
            "cr": .bool(row.cr)
        ])
    }

    private static func tempTargetPresetJSON(_ row: TempTargetStored) -> HealthIngestJSON {
        .object([
            "name": row.name.map { .string($0) },
            "target": .decimal(row.target),
            "durationMinutes": .decimal(row.duration),
            "halfBasalTarget": .decimal(row.halfBasalTarget)
        ])
    }

    private static func ending(start: Date, minutes: Decimal?, indefinite: Bool) -> Date? {
        if indefinite { return nil }
        guard let minutes, minutes > 0 else { return nil }
        let seconds = NSDecimalNumber(decimal: minutes * 60).doubleValue
        guard seconds.isFinite, seconds > 0 else { return nil }
        return start.addingTimeInterval(seconds)
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
            id: id,
            start: start,
            end: end,
            tz: HealthIngestTime.zoneIdentifier,
            payload: payload
        )
    }
}
