import Foundation
import HealthKit
import Testing

@testable import Trio

@Suite("Health Ingest", .serialized) struct HealthIngestTests {
    @Test func serviceIsOffUntilEnabled() {
        let preferences = HealthIngestPreferences.initial
        #expect(!preferences.enabled)
        #expect(preferences.baseURL.isEmpty)
        #expect(preferences.deviceID == "trio-iphone")
        #expect(preferences.normalizedDeviceID == "trio-iphone")
        #expect(preferences.isOn(.glucose))
        #expect(preferences.isOn(.heart))
    }

    @Test func categoriesCoverEveryRecordType() {
        let covered = Set(HealthIngestCategory.allCases.flatMap(\.recordTypes))
        #expect(covered == HealthIngestType.all)
    }

    @Test func glucoseFloorIs39() {
        #expect(HealthIngestGlucose.lowFloorMgdl == 39)
        #expect(HealthIngestGlucose.isLow(mgdl: 39))
        #expect(HealthIngestGlucose.isLow(mgdl: 20))
        #expect(!HealthIngestGlucose.isLow(mgdl: 40))
        #expect(!HealthIngestGlucose.isLow(mgdl: 0))
    }

    @Test func stableIdsAreReusedAndDoNotCarryARevision() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let stamp = HealthIngestTime.string(from: start)
        let glucose = HealthIngestIdentity.glucose(source: "dexcom", start: start)
        #expect(glucose == "cgm:dexcom:\(stamp)")
        #expect(HealthIngestIdentity.glucose(source: "dexcom", start: start) == glucose)
        #expect(HealthIngestIdentity.loop(start: start) == "loop:\(stamp)")
        #expect(!glucose.contains("#"))
        #expect(stamp.hasSuffix("Z"))
        #expect(HealthIngestTime.date(from: "2026-01-01T05:30:00+05:30") != nil)
        #expect(HealthIngestTime.date(from: "2026-01-01T00:00:00Z") != nil)
    }

    @Test func sleepStagesUseTheServerNames() {
        #expect(HealthIngestSleep.stage(hkValue: HKCategoryValueSleepAnalysis.awake.rawValue) == "awake")
        #expect(HealthIngestSleep.stage(hkValue: HKCategoryValueSleepAnalysis.asleepCore.rawValue) == "core")
        #expect(HealthIngestSleep.stage(hkValue: HKCategoryValueSleepAnalysis.asleepDeep.rawValue) == "deep")
        #expect(HealthIngestSleep.stage(hkValue: HKCategoryValueSleepAnalysis.asleepREM.rawValue) == "rem")
        #expect(HealthIngestSleep.stage(hkValue: HKCategoryValueSleepAnalysis.inBed.rawValue) == "inBed")
        #expect(HealthIngestSleep.stage(hkValue: HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue) == "asleep")
    }

    @Test func originRequiresHTTPSAndRejectsUserinfo() throws {
        let origin = HealthIngestOrigin.parse("https://example.ts.net/")
        #expect(origin?.scheme == "https")
        #expect(origin?.host == "example.ts.net")
        #expect(origin?.path == "" || origin?.path == "/")
        #expect(HealthIngestOrigin.parse("http://example.ts.net") == nil)
        #expect(HealthIngestOrigin.parse("https://user:unit-test-token@example.ts.net") == nil)
        #expect(HealthIngestOrigin.parse("") == nil)
        #expect(HealthIngestOrigin.parse("https://example.ts.net/ingest")?.path == "/ingest")
        let withPort = HealthIngestOrigin.parse("https://example.ts.net:8443")
        #expect(withPort?.port == 8443)
        #expect(withPort?.host == "example.ts.net")
        let status = HealthIngestWire.endpoint(try #require(withPort), path: HealthIngestWire.statusPath)
        #expect(status?.port == 8443)
        #expect(status?.path == "/v1/status")
    }

    @Test func backoffDoublesAndCapsAtFifteenMinutes() {
        #expect(HealthIngestBackoff.delay(afterFailures: 0) == 0)
        #expect(HealthIngestBackoff.delay(afterFailures: 1) == 30)
        #expect(HealthIngestBackoff.delay(afterFailures: 2) == 60)
        #expect(HealthIngestBackoff.delay(afterFailures: 3) == 120)
        #expect(HealthIngestBackoff.delay(afterFailures: 6) == 15 * 60)
        #expect(HealthIngestBackoff.delay(afterFailures: 12) == 15 * 60)
    }

    @Test func envelopeUsesSchemaVersionAndUTCTimestamps() throws {
        let record = makeRecord(id: "glucose-1", type: HealthIngestType.glucose)
        let envelope = HealthIngestEnvelope(
            schemaVersion: HealthIngestWire.schemaVersion,
            device: HealthIngestDevice(id: "device-1", app: HealthIngestWire.appName, appVersion: "1.0 (1)"),
            records: [record]
        )
        let data = try HealthIngestWire.encodeEnvelope(envelope)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["schemaVersion"] as? Int == 1)
        let device = try #require(json["device"] as? [String: Any])
        #expect(device["app"] as? String == "trio")
        #expect(HealthIngestWire.maxBatchRecords == 500)
        #expect(HealthIngestWire.maxBatchBytes == 4 * 1024 * 1024)
        #expect(HealthIngestWire.maxPayloadBytes == 128 * 1024)
        #expect(device["id"] as? String == "device-1")
        let records = try #require(json["records"] as? [[String: Any]])
        let start = try #require(records.first?["start"] as? String)
        #expect(start.hasSuffix("Z"))
        #expect(records.first?["tz"] as? String != nil)
        #expect(records.first?["end"] == nil)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("Bearer"))
        #expect(!text.contains("unit-test-token"))
    }

    @Test func responseIsResultsWithTypeAndId() throws {
        let body = Data(
            #"{"results":[{"type":"glucose","id":"a","status":"duplicate"},{"type":"bolus","id":"b","status":"rejected","reason":"no"}]}"#
                .utf8
        )
        let parsed = try HealthIngestWire.parseAcks(body)
        #expect(parsed.map(\.status) == [.duplicate, .rejected])
        #expect(parsed[0].type == "glucose")
        #expect(parsed[1].reason == "no")
        #expect(throws: HealthIngestWireError.unrecognizedResponse) {
            try HealthIngestWire.parseAcks(Data(#"{"records":[{"type":"glucose","id":"a","status":"accepted"}]}"#.utf8))
        }
        #expect(throws: HealthIngestWireError.unrecognizedResponse) {
            try HealthIngestWire.parseAcks(Data())
        }
    }

    @Test func gzipRoundTripsAndIsSkippedForSmallBodies() throws {
        let input = Data(repeating: 0x61, count: 2048)
        let compressed = try #require(HealthIngestGzip.compress(input))
        #expect(compressed.starts(with: Data([0x1F, 0x8B])))
        #expect(HealthIngestGzip.decompress(compressed) == input)
        #expect(HealthIngestWire.gzipIfWorthwhile(input) != nil)
        #expect(HealthIngestWire.gzipIfWorthwhile(Data("short".utf8)) == nil)
    }

    @Test func queueIsDurableAndDuplicatesAreSuccess() async throws {
        let disk = try makeDisk()
        let queue = HealthIngestQueue(disk: disk)
        let record = makeRecord(id: "glucose-1", type: HealthIngestType.glucose)
        #expect(await queue.enqueue([record]).queued == 1)
        #expect(await queue.enqueue([record]).queued == 0)
        #expect(await queue.depth() == 1)

        let reloaded = HealthIngestQueue(disk: disk)
        #expect(await reloaded.depth() == 1)
        let reason = await reloaded.resolve(
            batch: [record],
            acks: [HealthIngestAck(type: record.type, id: record.id, status: .duplicate)],
            transportFailed: false
        )
        #expect(reason == nil)
        #expect(await reloaded.depth() == 0)
        let afterAck = HealthIngestQueue(disk: disk)
        #expect(await afterAck.enqueue([record]).queued == 0)

        var changed = record
        changed.payload = .object(["mgdl": .number(121), "low": .bool(false)])
        #expect(await afterAck.enqueue([changed]).queued == 1)
    }

    @Test func timeoutKeepsTheSameIdAndRejectionIsRetried() async throws {
        let disk = try makeDisk()
        let queue = HealthIngestQueue(disk: disk)
        let record = makeRecord(id: "bolus-1", type: HealthIngestType.bolus)
        #expect(await queue.enqueue([record]).queued == 1)
        _ = await queue.resolve(batch: [record], acks: [], transportFailed: true)
        #expect(await queue.depth() == 1)
        #expect(await queue.hasReady() == false)
        let still = await queue.nextBatch(limit: 10, maxBytes: 1_000_000)
        #expect(still.isEmpty)

        let rejecting = HealthIngestQueue(disk: try makeDisk())
        #expect(await rejecting.enqueue([record]).queued == 1)
        let dropped = await rejecting.resolve(
            batch: [record],
            acks: [HealthIngestAck(type: record.type, id: record.id, status: .rejected, reason: "schema")],
            transportFailed: false
        )
        #expect(dropped == "bolus bolus-1: schema")
        #expect(await rejecting.depth() == 1)
        #expect(await rejecting.hasReady() == false)
        #expect(await rejecting.rejectedCount() == 1)
        #expect(await rejecting.enqueue([record]).queued == 0)
    }

    @Test func contentHashMatchesTheWorkedExample() {
        let payload = HealthIngestJSON.object(["b": .number(1), "a": .number(2)])
        #expect(HealthIngestCanonicalJSON.string(payload) == "{\"a\":2,\"b\":1}")
        #expect(
            HealthIngestCanonicalJSON.contentID(prefix: "profile", payload: payload) ==
                "profile:d3626ac30a87e6f7a6428233b3c68299"
        )
        let fraction = HealthIngestJSON.object([
            "rate": .number(0.9),
            "gramsPerUnit": .number(10)
        ])
        #expect(HealthIngestCanonicalJSON.string(fraction) == "{\"gramsPerUnit\":10,\"rate\":0.9}")
    }

    @Test func unchangedSettingsSnapshotIsSentAgainAfterADay() async throws {
        let queue = HealthIngestQueue(disk: try makeDisk())
        let snapshot = makeRecord(id: "settings", type: HealthIngestType.settingsSnapshot)
        #expect(await queue.enqueue([snapshot]).queued == 1)
        _ = await queue.resolve(
            batch: [snapshot],
            acks: [HealthIngestAck(type: snapshot.type, id: snapshot.id, status: .accepted)],
            transportFailed: false
        )
        #expect(await queue.enqueue([snapshot]).queued == 0)
        let tomorrow = Date().addingTimeInterval(25 * 3600)
        #expect(await queue.enqueue([snapshot], now: tomorrow).queued == 1)
    }

    @Test func statusCheckSendsTheBearerTokenAndNotTheBody() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HealthIngestURLStub.self]
        HealthIngestURLStub.request = nil
        HealthIngestURLStub.body = Data(#"{"ok":true}"#.utf8)
        HealthIngestURLStub.status = 200
        let client = HealthIngestClient(session: URLSession(configuration: configuration))
        let origin = try #require(HealthIngestOrigin.parse("https://example.ts.net"))
        let code = try await client.status(origin: origin, token: "unit-test-token")
        #expect(code == 200)
        let request = try #require(HealthIngestURLStub.request)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer unit-test-token")
        #expect(request.url?.path == "/v1/status")
        #expect(request.httpBody == nil)
    }

    @Test func postUsesIngestPathAndKeepsTheTokenOutOfTheBody() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HealthIngestURLStub.self]
        HealthIngestURLStub.request = nil
        HealthIngestURLStub.body = Data(#"{"records":[{"id":"glucose-1","status":"accepted"}]}"#.utf8)
        HealthIngestURLStub.status = 200
        let client = HealthIngestClient(session: URLSession(configuration: configuration))
        let origin = try #require(HealthIngestOrigin.parse("https://example.ts.net"))
        let record = makeRecord(id: "glucose-1", type: HealthIngestType.glucose)
        let body = try HealthIngestWire.encodeEnvelope(
            HealthIngestEnvelope(
                schemaVersion: 1,
                device: HealthIngestDevice(id: "trio-iphone", app: "trio", appVersion: "1.0 (1)"),
                records: [record]
            )
        )
        let (code, _) = try await client.post(origin: origin, token: "unit-test-token", body: body, gzip: false)
        #expect(code == 200)
        let request = try #require(HealthIngestURLStub.request)
        #expect(request.url?.path == "/v1/ingest")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer unit-test-token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let sent = request.httpBody ?? Data()
        let text = String(data: sent, encoding: .utf8) ?? ""
        #expect(text.contains("\"schemaVersion\":1"))
        #expect(!text.contains("unit-test-token"))
    }


    @Test func recordIdsAreSanitizedToTheServerAlphabet() {
        #expect(HealthIngestRecordID.sanitize("pump-123-Site Change") == "pump-123-Site-Change")
        #expect(HealthIngestRecordID.component("Workout (80%)") == "Workout-80")
        #expect(HealthIngestRecordID.component("   ") == "unnamed")
        let plus = HealthIngestRecordID.sanitize("+bad")
        #expect(plus.first?.isLetter == true || plus.first?.isNumber == true)
        #expect(!plus.contains("+"))
    }

    @Test func diaHoursAndMultiplierMatchTheServerRanges() {
        #expect(HealthIngestPayload.diaHours(0) == nil)
        #expect(HealthIngestPayload.diaHours(-1) == nil)
        #expect(HealthIngestPayload.diaHours(6) == .number(6))
        #expect(HealthIngestPayload.diaHours(30) == .number(24))
        #expect(HealthIngestPayload.unitMultiplier(percentage: 0) == nil)
        #expect(HealthIngestPayload.unitMultiplier(percentage: 80) == .number(0.8))
        #expect(HealthIngestPayload.unitMultiplier(percentage: 2000) == nil)
        #expect(HealthIngestPayload.unitMultiplier(percentage: nil) == nil)
    }

    @Test func healthKitPayloadsUseContractFieldNames() throws {
        let hrv = try #require(HealthIngestHealthMapping.quantityPayload(recordType: HealthIngestType.hrv, value: 45))
        let energy = try #require(HealthIngestHealthMapping.quantityPayload(recordType: HealthIngestType.activeEnergy, value: 1.5))
        let exercise = try #require(HealthIngestHealthMapping.quantityPayload(recordType: HealthIngestType.exerciseMinutes, value: 1))
        let heart = try #require(HealthIngestHealthMapping.quantityPayload(recordType: HealthIngestType.heartRate, value: 72))
        #expect(keys(hrv).contains("sdnnMs"))
        #expect(!keys(hrv).contains("sdnnMilliseconds"))
        #expect(keys(energy).contains("kcal"))
        #expect(!keys(energy).contains("kilocalories"))
        #expect(keys(exercise).contains("minutes"))
        #expect(keys(heart).contains("bpm"))
        #expect(HealthIngestHealthMapping.quantityPayload(recordType: HealthIngestType.hrv, value: 0) == nil)
        #expect(HealthIngestHealthMapping.quantityPayload(recordType: HealthIngestType.hrv, value: 501) == nil)
        #expect(HealthIngestHealthMapping.quantityPayload(recordType: HealthIngestType.heartRate, value: 0) == nil)

        let workout = try #require(
            HealthIngestHealthMapping.workoutPayload(
                activity: "running",
                durationSeconds: 1800,
                energyKcal: 120,
                distanceMeters: 4000,
                avgHeartRate: 140
            )
        )
        #expect(keys(workout).contains("activity"))
        #expect(keys(workout).contains("energyKcal"))
        #expect(keys(workout).contains("avgHeartRate"))
        #expect(!keys(workout).contains("activityType"))
        #expect(!keys(workout).contains("energyKilocalories"))
        #expect(!keys(workout).contains("averageHeartRateBpm"))
        #expect(
            HealthIngestHealthMapping.workoutPayload(
                activity: "",
                durationSeconds: 60,
                energyKcal: nil,
                distanceMeters: nil,
                avgHeartRate: nil
            ) == nil
        )

        let sleep = HealthIngestHealthMapping.sleepPayload(
            hkValue: HKCategoryValueSleepAnalysis.asleepCore.rawValue
        )
        #expect(keys(sleep).contains("stage"))
        if case .object(let fields) = sleep, case .string(let stage) = fields["stage"] {
            #expect(stage == "core")
        } else {
            Issue.record("sleep payload should include stage")
        }

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(
            HealthIngestHealthMapping.sampleEnd(
                recordType: HealthIngestType.activeEnergy,
                start: start,
                end: start
            ) == .value(start)
        )
        #expect(
            HealthIngestHealthMapping.sampleEnd(
                recordType: HealthIngestType.heartRate,
                start: start,
                end: start
            ) == .value(nil)
        )
        #expect(
            HealthIngestHealthMapping.sampleEnd(
                recordType: HealthIngestType.sleepStage,
                start: start,
                end: start.addingTimeInterval(-1)
            ) == .drop
        )
    }

    @Test func rejectedRecordsAreDroppedAfterThreeAttempts() async throws {
        let disk = try makeDisk()
        let queue = HealthIngestQueue(disk: disk)
        let record = makeRecord(id: "hrv-1", type: HealthIngestType.hrv)
        #expect(await queue.enqueue([record]).queued == 1)
        let ack = HealthIngestAck(
            type: record.type,
            id: record.id,
            status: .rejected,
            reason: "payload.sdnnMs is required"
        )
        for attempt in 1 ... 2 {
            let reason = await queue.resolve(batch: [record], acks: [ack], transportFailed: false)
            #expect(reason == "hrv hrv-1: payload.sdnnMs is required")
            #expect(await queue.depth() == 1)
            #expect(await queue.rejectedCount() == 1)
            #expect(await queue.hasReady() == false)
            _ = attempt
        }
        let dropped = await queue.resolve(batch: [record], acks: [ack], transportFailed: false)
        #expect(dropped == "hrv hrv-1: payload.sdnnMs is required")
        #expect(await queue.depth() == 0)
        #expect(await queue.rejectedCount() == 1)
        #expect(await queue.enqueue([record]).queued == 0)
    }

    @Test func healthKitWireJSONMatchesTheServerContract() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let cases: [(String, HealthIngestJSON, Set<String>, Set<String>)] = [
            (
                HealthIngestType.hrv,
                try #require(HealthIngestHealthMapping.quantityPayload(recordType: HealthIngestType.hrv, value: 45)),
                ["sdnnMs", "source"],
                ["sdnnMilliseconds", "milliseconds"]
            ),
            (
                HealthIngestType.activeEnergy,
                try #require(HealthIngestHealthMapping.quantityPayload(recordType: HealthIngestType.activeEnergy, value: 1.5)),
                ["kcal", "source"],
                ["kilocalories", "activeEnergy", "calories"]
            ),
            (
                HealthIngestType.exerciseMinutes,
                try #require(HealthIngestHealthMapping.quantityPayload(recordType: HealthIngestType.exerciseMinutes, value: 12)),
                ["minutes", "source"],
                ["durationMinutes", "exerciseMinutes"]
            ),
            (
                HealthIngestType.heartRate,
                try #require(HealthIngestHealthMapping.quantityPayload(recordType: HealthIngestType.heartRate, value: 72)),
                ["bpm", "source"],
                ["beatsPerMinute", "heartRate"]
            ),
            (
                HealthIngestType.workout,
                try #require(HealthIngestHealthMapping.workoutPayload(
                    activity: "running",
                    durationSeconds: 1800,
                    energyKcal: 120,
                    distanceMeters: 4000,
                    avgHeartRate: 140
                )),
                ["activity", "durationSeconds", "energyKcal", "distanceMeters", "avgHeartRate", "source"],
                ["activityType", "energyKilocalories", "averageHeartRateBpm", "kilocalories"]
            ),
            (
                HealthIngestType.sleepStage,
                HealthIngestHealthMapping.sleepPayload(hkValue: HKCategoryValueSleepAnalysis.asleepCore.rawValue),
                ["stage", "source"],
                ["sleepStage", "value"]
            )
        ]
        for (type, payload, required, forbidden) in cases {
            let record = HealthIngestRecord(
                type: type,
                id: "\(type)-wire-1",
                start: start,
                end: type == HealthIngestType.sleepStage || type == HealthIngestType.activeEnergy || type == HealthIngestType.workout
                    ? start.addingTimeInterval(60)
                    : nil,
                tz: "Etc/UTC",
                payload: payload
            )
            let wire = try wirePayload(record)
            for key in required {
                #expect(wire[key] != nil, "\(type) wire JSON missing \(key)")
            }
            for key in forbidden {
                #expect(wire[key] == nil, "\(type) wire JSON should not contain \(key)")
            }
        }
    }

    @Test func settingsSnapshotIdMatchesTheServerCanonicalHash() {
        // Server id is settings:<first 32 lowercase hex chars of SHA-256(stableJson(payload))>.
        // Keys must be sorted, no insignificant whitespace, payload only (not the envelope).
        let payload = HealthIngestJSON.object([
            "values": .object([
                "pumpSettings": .object([
                    "maxBolus": .number(10),
                    "diaHours": .number(6)
                ])
            ])
        ])
        #expect(HealthIngestCanonicalJSON.string(payload) == "{\"values\":{\"pumpSettings\":{\"diaHours\":6,\"maxBolus\":10}}}")
        let digest = HealthIngestCanonicalJSON.digest(payload)
        #expect(digest == "6f7a0ae872e2f1777fa07c58e8410e0e")
        let id = HealthIngestCanonicalJSON.contentID(prefix: HealthIngestWire.settingsIDPrefix, payload: payload)
        #expect(id == "settings:\(digest)")
        #expect(id == HealthIngestCanonicalJSON.contentID(prefix: "settings", payload: payload))
    }

    @Test func predictedBGOmitsNegativeAndOutOfRangeValues() {
        #expect(HealthIngestPayload.predictedBG(-12) == nil)
        #expect(HealthIngestPayload.predictedBG(0) == .number(0))
        #expect(HealthIngestPayload.predictedBG(110) == .number(110))
        #expect(HealthIngestPayload.predictedBG(2001) == nil)
        #expect(HealthIngestPayload.predictedBG(Double.nan) == nil)
        #expect(HealthIngestPayload.predictedBG(NSDecimalNumber(value: -3)) == nil)
        #expect(HealthIngestPayload.predictedBG(Optional<Decimal>.none) == nil)
    }

    @Test func rejectedReceiptsCanBeForgottenForALaterBackfill() async throws {
        let disk = try makeDisk()
        let queue = HealthIngestQueue(disk: disk)
        let record = makeRecord(id: "hrv-reset-1", type: HealthIngestType.hrv)
        #expect(await queue.enqueue([record]).queued == 1)
        let ack = HealthIngestAck(
            type: record.type,
            id: record.id,
            status: .rejected,
            reason: "payload.sdnnMs is required"
        )
        for _ in 1 ... 3 {
            _ = await queue.resolve(batch: [record], acks: [ack], transportFailed: false)
        }
        #expect(await queue.depth() == 0)
        #expect(await queue.enqueue([record]).queued == 0)
        await queue.forgetRejectedReceipts()
        #expect(await queue.enqueue([record]).queued == 1)
    }

    @Test func rejectedReceiptsAreCappedSoTheQueueFileCannotGrowWithoutBound() async throws {
        let disk = try makeDisk()
        let queue = HealthIngestQueue(disk: disk)
        for index in 1 ... 2_050 {
            let record = makeRecord(id: "hrv-cap-\(index)", type: HealthIngestType.hrv)
            #expect(await queue.enqueue([record]).queued == 1)
            let ack = HealthIngestAck(
                type: record.type,
                id: record.id,
                status: .rejected,
                reason: "payload.sdnnMs is required"
            )
            for _ in 1 ... 3 {
                _ = await queue.resolve(batch: [record], acks: [ack], transportFailed: false)
            }
        }
        // After the cap, the oldest rejected receipt is evicted and that id can be queued again.
        let first = makeRecord(id: "hrv-cap-1", type: HealthIngestType.hrv)
        #expect(await queue.enqueue([first]).queued == 1)
    }


    private func makeDisk() throws -> HealthIngestDisk {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("health-ingest-\(UUID().uuidString)", isDirectory: true)
        return try HealthIngestDisk(directory: directory)
    }

    private func makeRecord(id: String, type: String) -> HealthIngestRecord {
        HealthIngestRecord(
            type: type,
            id: id,
            start: Date(timeIntervalSince1970: 1_700_000_000),
            end: nil,
            tz: "Etc/UTC",
            payload: .object([
                "mgdl": .number(120),
                "low": .bool(false),
                "sourceId": .string(id)
            ])
        )
    }

    private func keys(_ value: HealthIngestJSON) -> Set<String> {
        if case .object(let fields) = value {
            return Set(fields.keys)
        }
        return []
    }

    private func wirePayload(_ record: HealthIngestRecord) throws -> [String: Any] {
        let data = try HealthIngestWire.encodeEnvelope(
            HealthIngestEnvelope(
                schemaVersion: HealthIngestWire.schemaVersion,
                device: HealthIngestDevice(id: "trio-iphone", app: "trio", appVersion: "1.0 (1)"),
                records: [record]
            )
        )
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try #require(json["records"] as? [[String: Any]])
        return try #require(records.first?["payload"] as? [String: Any])
    }
}

private final class HealthIngestURLStub: URLProtocol {
    static var request: URLRequest?
    static var body = Data()
    static var status = 200

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var copy = request
        if copy.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 1024)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            copy.httpBody = data
        }
        Self.request = copy
        let url = request.url ?? URL(string: "https://example.ts.net")!
        let response = HTTPURLResponse(url: url, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
