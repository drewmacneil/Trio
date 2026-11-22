import CoreData
import Foundation

/// Per-loop inputs captured beside `determineBasal` so a later upload can replay the cycle.
enum HealthIngestLoopCapture {
    struct Note: Codable {
        var start: Date
        var timeZone: String
        var autosensRaw: Double?
        var effectiveProfileId: String?
        var effectivePayload: HealthIngestJSON?
        var dynamicIsf: HealthIngestJSON?
        var iobBreakdown: HealthIngestJSON?
        var meal: HealthIngestJSON?
        var determination: [String: HealthIngestJSON]?
    }

    struct Stat: Codable {
        var start: Date
        var end: Date
        var result: String
        var error: String?
        var timeZone: String
    }

    static func recording(
        profile: Profile,
        autosens: Autosens?,
        meal: ComputedCarbs?,
        iob: [IobResult],
        variables: TrioCustomOrefVariables,
        at: Date,
        enabled: Bool,
        _ body: () throws -> Determination?
    ) throws -> Determination? {
        do {
            let determination = try body()
            if enabled {
                if let determination {
                    store(success: determination, profile: profile, autosens: autosens, meal: meal, iob: iob, variables: variables, at: at)
                } else {
                    storeStat(result: "skipped", error: "No determination", start: at, end: at)
                }
            }
            return determination
        } catch {
            if enabled {
                storeStat(result: "failed", error: error.localizedDescription, start: at, end: Date())
            }
            throw error
        }
    }

    static func lookup(start: Date) -> Note? {
        notes().first { abs($0.start.timeIntervalSince(start)) < 2 }
    }

    static func drainStats() -> [HealthIngestRecord] {
        let pending = stats()
        guard !pending.isEmpty else { return [] }
        saveStats([])
        return pending.map { stat in
            HealthIngestRecord(
                type: HealthIngestType.loopStat,
                id: "loop-stat:\(HealthIngestTime.string(from: stat.start))",
                start: stat.start,
                end: stat.end,
                tz: stat.timeZone,
                payload: .object([
                    "result": .string(stat.result),
                    "error": stat.error.map { .string(String($0.prefix(8000))) } ?? .null
                ])
            )
        }
    }

    private static func store(
        success determination: Determination,
        profile: Profile,
        autosens: Autosens?,
        meal: ComputedCarbs?,
        iob: [IobResult],
        variables: TrioCustomOrefVariables,
        at: Date
    ) {
        let payload = effectivePayload(profile)
        let profileID = HealthIngestCanonicalJSON.contentID(prefix: HealthIngestWire.effectiveIDPrefix, payload: payload)
        let zone = TimeZone.current.identifier
        let current = iob.first
        var notes = notes()
        notes.append(
            Note(
                start: determination.deliverAt ?? at,
                timeZone: zone,
                autosensRaw: autosens.map { NSDecimalNumber(decimal: $0.ratio).doubleValue },
                effectiveProfileId: profileID,
                effectivePayload: payload,
                dynamicIsf: dynamicIsf(variables),
                iobBreakdown: current.map(breakdown),
                meal: meal.map(mealPayload),
                determination: extraDetermination(determination)
            )
        )
        if notes.count > 40 { notes.removeFirst(notes.count - 40) }
        saveNotes(notes)
        var records = pendingProfiles()
        records.append(
            HealthIngestRecord(
                type: HealthIngestType.effectiveProfile,
                id: profileID,
                start: determination.deliverAt ?? at,
                end: nil,
                tz: zone,
                payload: payload
            )
        )
        if records.count > 40 { records.removeFirst(records.count - 40) }
        saveProfiles(records)
    }

    static func drainProfiles() -> [HealthIngestRecord] {
        let records = pendingProfiles()
        saveProfiles([])
        return records
    }

    private static func extraDetermination(_ determination: Determination) -> [String: HealthIngestJSON] {
        var fields: [String: HealthIngestJSON] = [:]
        if let value = determination.minPredBG, let number = HealthIngestPayload.predictedBG(Double(value)) {
            fields["minPredBG"] = number
        }
        if let value = determination.minGuardBG, let number = HealthIngestPayload.predictedBG(Double(value)) {
            fields["minGuardBG"] = number
        }
        if let value = determination.tdd { fields["tdd"] = .number(NSDecimalNumber(decimal: value).doubleValue) }
        if let stamp = determination.timestamp {
            fields["timestamp"] = .string(HealthIngestTime.string(from: stamp))
        }
        if let curves = determination.predictions {
            fields["predBGs"] = .object([
                "IOB": curves.iob.map { .array($0.map { .number(Double($0)) }) },
                "COB": curves.cob.map { .array($0.map { .number(Double($0)) }) },
                "UAM": curves.uam.map { .array($0.map { .number(Double($0)) }) },
                "ZT": curves.zt.map { .array($0.map { .number(Double($0)) }) }
            ])
        }
        return fields
    }

    private static func effectivePayload(_ profile: Profile) -> HealthIngestJSON {
        let basal = (profile.basalprofile ?? []).map { entry in
            HealthIngestJSON.object([
                "start": .string(HealthIngestCanonicalJSON.clock(start: entry.start, seconds: entry.minutes * 60)),
                "rate": .number(NSDecimalNumber(decimal: entry.rate).doubleValue)
            ])
        }
        let ratios = (profile.carbRatios?.schedule ?? []).map { entry in
            HealthIngestJSON.object([
                "start": .string(HealthIngestCanonicalJSON.clock(start: entry.start, seconds: entry.offset * 60)),
                "gramsPerUnit": .number(NSDecimalNumber(decimal: entry.ratio).doubleValue)
            ])
        }
        let isf = (profile.isfProfile?.sensitivities ?? []).map { entry in
            HealthIngestJSON.object([
                "start": .string(HealthIngestCanonicalJSON.clock(start: entry.start, seconds: entry.offset * 60)),
                "mgdlPerUnit": .number(NSDecimalNumber(decimal: entry.sensitivity).doubleValue)
            ])
        }
        let targets = (profile.bgTargets?.targets ?? []).map { entry in
            HealthIngestJSON.object([
                "start": .string(HealthIngestCanonicalJSON.clock(start: entry.start, seconds: entry.offset * 60)),
                "lowMgdl": .number(NSDecimalNumber(decimal: entry.low).doubleValue),
                "highMgdl": .number(NSDecimalNumber(decimal: entry.high).doubleValue)
            ])
        }
        var fields: [String: HealthIngestJSON?] = [
            "basal": basal.isEmpty ? nil : .array(basal),
            "carbRatio": ratios.isEmpty ? nil : .array(ratios),
            "isf": isf.isEmpty ? nil : .array(isf),
            "target": targets.isEmpty ? nil : .array(targets)
        ]
        if let dia = profile.dia {
            fields["diaHours"] = .number(NSDecimalNumber(decimal: dia).doubleValue)
        }
        if fields.values.allSatisfy({ $0 == nil }) {
            fields["basal"] = .array([.object(["start": .string("00:00"), "rate": .number(0)])])
        }
        return .object(fields)
    }

    private static func dynamicIsf(_ variables: TrioCustomOrefVariables) -> HealthIngestJSON {
        .object([
            "tddHistory": .array(tddHistory()),
            "weightedAverage": .number(NSDecimalNumber(decimal: variables.weightedAverage).doubleValue),
            "average2h": .number(NSDecimalNumber(decimal: variables.past2hoursAverage).doubleValue)
        ])
    }

    private static func tddHistory() -> [HealthIngestJSON] {
        let context = CoreDataStack.shared.newTaskContext()
        var rows: [HealthIngestJSON] = []
        context.performAndWait {
            let request = TDDStored.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
            let fetched = (try? context.fetch(request)) ?? []
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = "yyyy-MM-dd"
            for row in fetched.suffix(60) {
                guard let date = row.date, let total = row.total else { continue }
                rows.append(.object([
                    "date": .string(formatter.string(from: date)),
                    "tdd": .number(total.doubleValue)
                ]))
            }
        }
        return rows
    }

    private static func breakdown(_ iob: IobResult) -> HealthIngestJSON {
        .object([
            "iob": .number(NSDecimalNumber(decimal: iob.iob).doubleValue),
            "activity": .number(NSDecimalNumber(decimal: iob.activity).doubleValue),
            "basaliob": .number(NSDecimalNumber(decimal: iob.basaliob).doubleValue),
            "bolusiob": .number(NSDecimalNumber(decimal: iob.bolusiob).doubleValue),
            "netbasalinsulin": .number(NSDecimalNumber(decimal: iob.netbasalinsulin).doubleValue),
            "iobWithZeroTemp": .number(NSDecimalNumber(decimal: iob.iobWithZeroTemp.iob).doubleValue)
        ])
    }

    private static func mealPayload(_ meal: ComputedCarbs) -> HealthIngestJSON {
        let last = meal.lastCarbTime > 0
            ? HealthIngestTime.string(from: Date(timeIntervalSince1970: meal.lastCarbTime / 1000))
            : nil
        return .object([
            "mealCOB": .number(NSDecimalNumber(decimal: meal.mealCOB).doubleValue),
            "carbs": .number(NSDecimalNumber(decimal: meal.carbs).doubleValue),
            "slopeFromMaxDeviation": .number(NSDecimalNumber(decimal: meal.slopeFromMaxDeviation).doubleValue),
            "slopeFromMinDeviation": .number(NSDecimalNumber(decimal: meal.slopeFromMinDeviation).doubleValue),
            "lastCarbTime": last.map { .string($0) },
            "currentDeviation": meal.currentDeviation.map { .number(NSDecimalNumber(decimal: $0).doubleValue) },
            "maxDeviation": .number(NSDecimalNumber(decimal: meal.maxDeviation).doubleValue),
            "minDeviation": .number(NSDecimalNumber(decimal: meal.minDeviation).doubleValue)
        ])
    }

    private static func storeStat(result: String, error: String?, start: Date, end: Date) {
        var pending = stats()
        pending.append(
            Stat(
                start: start,
                end: end,
                result: result,
                error: error,
                timeZone: TimeZone.current.identifier
            )
        )
        if pending.count > 40 { pending.removeFirst(pending.count - 40) }
        saveStats(pending)
    }

    private static func notes() -> [Note] { load("loop-notes.json") ?? [] }
    private static func saveNotes(_ notes: [Note]) { save(notes, name: "loop-notes.json") }
    private static func stats() -> [Stat] { load("loop-stats.json") ?? [] }
    private static func saveStats(_ stats: [Stat]) { save(stats, name: "loop-stats.json") }
    private static func pendingProfiles() -> [HealthIngestRecord] { load("effective-profiles.json") ?? [] }
    private static func saveProfiles(_ records: [HealthIngestRecord]) { save(records, name: "effective-profiles.json") }

    private static func load<T: Decodable>(_ name: String) -> T? {
        guard let url = file(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? HealthIngestWire.makeDecoder().decode(T.self, from: data)
    }

    private static func save(_ value: some Encodable, name: String) {
        guard let url = file(name), let data = try? HealthIngestWire.makeEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func file(_ name: String) -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let directory = base.appendingPathComponent("HealthIngest", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }
}
