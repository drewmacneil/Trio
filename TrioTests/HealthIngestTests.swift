import Foundation
import HealthKit
import LocalAuthentication
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
        #expect(HealthIngestWire.maxBatchBytes == 1024 * 1024)
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


    @Test func payloadHelpersKeepStoredValuesAndDropOnlyNonFiniteNumbers() {
        #expect(HealthIngestPayload.diaHours(0) == .number(0))
        #expect(HealthIngestPayload.diaHours(-1) == .number(-1))
        #expect(HealthIngestPayload.diaHours(6) == .number(6))
        #expect(HealthIngestPayload.diaHours(30) == .number(30))
        #expect(HealthIngestPayload.diaHours(.infinity) == nil)
        #expect(HealthIngestPayload.unitMultiplier(percentage: 0) == .number(0))
        #expect(HealthIngestPayload.unitMultiplier(percentage: 80) == .number(0.8))
        #expect(HealthIngestPayload.unitMultiplier(percentage: 2000) == .number(20))
        #expect(HealthIngestPayload.unitMultiplier(percentage: nil) == nil)
        #expect(HealthIngestPayload.unitMultiplier(percentage: .nan) == nil)
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
        #expect(HealthIngestHealthMapping.quantityPayload(recordType: HealthIngestType.hrv, value: 0) != nil)
        #expect(HealthIngestHealthMapping.quantityPayload(recordType: HealthIngestType.hrv, value: 501) != nil)
        #expect(HealthIngestHealthMapping.quantityPayload(recordType: HealthIngestType.heartRate, value: 0) != nil)
        #expect(HealthIngestHealthMapping.quantityPayload(recordType: HealthIngestType.hrv, value: .nan) == nil)

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
            ) == .value(start.addingTimeInterval(-1))
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
            #expect(await queue.rejectedCount() == attempt)
            #expect(await queue.hasReady() == false)
        }
        let dropped = await queue.resolve(batch: [record], acks: [ack], transportFailed: false)
        #expect(dropped == "hrv hrv-1: payload.sdnnMs is required")
        #expect(await queue.depth() == 0)
        #expect(await queue.rejectedCount() == 3)
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

    @Test func healthKitSourceFieldsSitBesidePayload() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = try #require(
            HealthIngestHealthMapping.quantityPayload(recordType: HealthIngestType.heartRate, value: 72)
        )
        let record = HealthIngestRecord(
            type: HealthIngestType.heartRate,
            id: "hr-source-1",
            start: start,
            end: nil,
            tz: "Etc/UTC",
            payload: payload,
            sourceName: "Apple Watch",
            sourceBundleIdentifier: "com.apple.health",
            deviceName: "Apple Watch",
            deviceModel: "Watch",
            deviceManufacturer: "Apple Inc."
        )
        let wire = try wireRecord(record)
        #expect(wire["sourceName"] as? String == "Apple Watch")
        #expect(wire["sourceBundleIdentifier"] as? String == "com.apple.health")
        #expect(wire["deviceName"] as? String == "Apple Watch")
        #expect(wire["deviceModel"] as? String == "Watch")
        #expect(wire["deviceManufacturer"] as? String == "Apple Inc.")
        let body = try #require(wire["payload"] as? [String: Any])
        #expect(body["source"] as? String == "healthkit")
        #expect(body["bpm"] != nil)
        for key in ["sourceName", "sourceBundleIdentifier", "deviceName", "deviceModel", "deviceManufacturer"] {
            #expect(body[key] == nil, "payload should not contain \(key)")
        }

        let healthKitTypes = [
            HealthIngestType.heartRate,
            HealthIngestType.restingHR,
            HealthIngestType.hrv,
            HealthIngestType.sleepStage,
            HealthIngestType.activeEnergy,
            HealthIngestType.exerciseMinutes,
            HealthIngestType.workout
        ]
        for type in healthKitTypes {
            let encoded = try wireRecord(
                HealthIngestRecord(
                    type: type,
                    id: "\(type)-source",
                    start: start,
                    end: nil,
                    tz: "Etc/UTC",
                    payload: .object(["source": .string(HealthIngestHealthMapping.source)]),
                    sourceName: "Apple Watch",
                    sourceBundleIdentifier: "com.apple.health"
                )
            )
            #expect(encoded["id"] as? String == "\(type)-source")
            #expect(encoded["sourceName"] as? String == "Apple Watch")
            #expect(encoded["sourceBundleIdentifier"] as? String == "com.apple.health")
            #expect(encoded["deviceName"] == nil)
            #expect(encoded["deviceModel"] == nil)
            #expect(encoded["deviceManufacturer"] == nil)
            let encodedPayload = try #require(encoded["payload"] as? [String: Any])
            #expect(encodedPayload["source"] as? String == "healthkit")
        }

        let trioTypes = [
            HealthIngestType.glucose,
            HealthIngestType.bolus,
            HealthIngestType.carbs,
            HealthIngestType.loopCycle
        ]
        for type in trioTypes {
            let encoded = try wireRecord(makeRecord(id: "\(type)-native", type: type))
            for key in ["sourceName", "sourceBundleIdentifier", "deviceName", "deviceModel", "deviceManufacturer"] {
                #expect(encoded[key] == nil, "\(type) should not send \(key)")
            }
        }
    }

    @Test func healthKitSourceOmitsMissingDeviceAndInvalidStrings() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let noDevice = HealthIngestRecord(
            type: HealthIngestType.hrv,
            id: "hrv-no-device",
            start: start,
            end: nil,
            tz: "Etc/UTC",
            payload: .object(["source": .string("healthkit"), "sdnnMs": .number(45)]),
            sourceName: " Watch ",
            sourceBundleIdentifier: "com.apple.health",
            deviceName: nil,
            deviceModel: nil,
            deviceManufacturer: nil
        )
        let bare = try wireRecord(noDevice)
        #expect(bare["sourceName"] as? String == " Watch ")
        #expect(bare["sourceBundleIdentifier"] as? String == "com.apple.health")
        #expect(bare["deviceName"] == nil)
        #expect(bare["deviceModel"] == nil)
        #expect(bare["deviceManufacturer"] == nil)
        let bareText = try wireText(noDevice)
        #expect(!bareText.contains("\"deviceName\""))
        #expect(!bareText.contains("\"deviceModel\""))
        #expect(!bareText.contains("\"deviceManufacturer\""))
        #expect(!bareText.contains("null"))

        let tooLong = String(repeating: "q", count: 257)
        let emojiLimit = String(repeating: "😀", count: 128)
        let emojiOver = String(repeating: "😀", count: 129)
        #expect(emojiLimit.utf16.count == 256)
        #expect(emojiOver.count == 129)
        #expect(emojiOver.utf16.count > 256)
        let invalid = HealthIngestRecord(
            type: HealthIngestType.sleepStage,
            id: "sleep-invalid",
            start: start,
            end: start.addingTimeInterval(60),
            tz: "Etc/UTC",
            payload: .object(["source": .string("healthkit"), "stage": .string("core")]),
            sourceName: "",
            sourceBundleIdentifier: "bad\u{0007}tail",
            deviceName: "line\nbreak",
            deviceModel: tooLong,
            deviceManufacturer: emojiOver
        )
        let dropped = try wireRecord(invalid)
        #expect(dropped["sourceName"] == nil)
        #expect(dropped["sourceBundleIdentifier"] == nil)
        #expect(dropped["deviceName"] == nil)
        #expect(dropped["deviceModel"] == nil)
        #expect(dropped["deviceManufacturer"] == nil)
        let droppedPayload = try #require(dropped["payload"] as? [String: Any])
        #expect(droppedPayload["source"] as? String == "healthkit")
        #expect(droppedPayload["stage"] as? String == "core")
        let droppedText = try wireText(invalid)
        #expect(!droppedText.contains(tooLong))
        #expect(!droppedText.contains(String(repeating: "q", count: 256)))
        #expect(!droppedText.contains("bad"))
        #expect(!droppedText.contains("tail"))
        #expect(!droppedText.contains("line"))
        #expect(!droppedText.contains(emojiOver))

        let kept = HealthIngestRecord(
            type: HealthIngestType.activeEnergy,
            id: "energy-limits",
            start: start,
            end: start,
            tz: "Etc/UTC",
            payload: .object(["source": .string("healthkit"), "kcal": .number(1)]),
            sourceName: String(repeating: "a", count: 256),
            sourceBundleIdentifier: emojiLimit,
            deviceName: "tab\tfails",
            deviceModel: "del\u{007F}fails",
            deviceManufacturer: "keep\u{2028}line"
        )
        let limits = try wireRecord(kept)
        #expect(limits["sourceName"] as? String == String(repeating: "a", count: 256))
        #expect(limits["sourceBundleIdentifier"] as? String == emojiLimit)
        #expect(limits["deviceName"] == nil)
        #expect(limits["deviceModel"] == nil)
        #expect(limits["deviceManufacturer"] as? String == "keep\u{2028}line")
        let limitsText = try wireText(kept)
        #expect(!limitsText.contains("tab"))
        #expect(!limitsText.contains("fails"))
    }

    @Test func mappingVersionSixResendsHealthKitHistoryWithTheSameIds() async throws {
        #expect(HealthIngestWire.mappingVersion == 7)
        let disk = try makeDisk()
        disk.saveMappingVersion(5)
        #expect(disk.loadMappingVersion() < HealthIngestWire.mappingVersion)

        let queue = HealthIngestQueue(disk: disk)
        let heart = makeRecord(id: "hr-same", type: HealthIngestType.heartRate)
        #expect(await queue.enqueue([heart]).queued == 1)
        _ = await queue.resolve(
            batch: [heart],
            acks: [HealthIngestAck(type: heart.type, id: heart.id, status: .accepted)],
            transportFailed: false
        )
        #expect(await queue.enqueue([heart]).queued == 0)

        var blank = heart
        blank.sourceName = ""
        blank.deviceName = "\n"
        blank.deviceModel = String(repeating: "m", count: 257)
        #expect(await queue.enqueue([blank]).queued == 0)

        var sourced = heart
        sourced.sourceName = "Apple Watch"
        sourced.sourceBundleIdentifier = "com.apple.health"
        sourced.deviceName = "Apple Watch"
        sourced.deviceModel = "Watch"
        sourced.deviceManufacturer = "Apple Inc."
        #expect(sourced.id == heart.id)
        #expect(await queue.enqueue([sourced]).queued == 1)
        let batch = await queue.nextBatch(limit: 10, maxBytes: HealthIngestWire.maxBatchBytes)
        #expect(batch.map(\.id) == ["hr-same"])
        #expect(batch.first?.sourceBundleIdentifier == "com.apple.health")
        _ = await queue.resolve(
            batch: batch,
            acks: [HealthIngestAck(type: heart.type, id: heart.id, status: .accepted)],
            transportFailed: false
        )
        #expect(await queue.enqueue([sourced]).queued == 0)

        let glucose = makeRecord(id: "glucose-same", type: HealthIngestType.glucose)
        #expect(await queue.enqueue([glucose]).queued == 1)
        _ = await queue.resolve(
            batch: [glucose],
            acks: [HealthIngestAck(type: glucose.type, id: glucose.id, status: .accepted)],
            transportFailed: false
        )
        #expect(await queue.enqueue([glucose]).queued == 0)

        var persisted = makeRecord(id: "hr-disk", type: HealthIngestType.restingHR)
        persisted.sourceName = "Apple Watch"
        persisted.sourceBundleIdentifier = "com.apple.health"
        persisted.deviceName = ""
        persisted.deviceModel = "Watch"
        let persistDisk = try makeDisk()
        let store = HealthIngestQueue(disk: persistDisk)
        #expect(await store.enqueue([persisted]).queued == 1)
        let reloaded = HealthIngestQueue(disk: persistDisk)
        let restored = await reloaded.nextBatch(limit: 5, maxBytes: HealthIngestWire.maxBatchBytes)
        #expect(restored.first?.id == "hr-disk")
        #expect(restored.first?.sourceName == "Apple Watch")
        #expect(restored.first?.sourceBundleIdentifier == "com.apple.health")
        #expect(restored.first?.deviceName == nil)
        #expect(restored.first?.deviceModel == "Watch")
        #expect(restored.first?.deviceManufacturer == nil)
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

    @Test func predictedBGKeepsNegativesAndDropsOnlyNonFiniteValues() {
        #expect(HealthIngestPayload.predictedBG(-12) == .number(-12))
        #expect(HealthIngestPayload.predictedBG(0) == .number(0))
        #expect(HealthIngestPayload.predictedBG(110) == .number(110))
        #expect(HealthIngestPayload.predictedBG(2001) == .number(2001))
        #expect(HealthIngestPayload.predictedBG(Double.nan) == nil)
        #expect(HealthIngestPayload.predictedBG(Double.infinity) == nil)
        #expect(HealthIngestPayload.predictedBG(NSDecimalNumber(value: -3)) == .number(-3))
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
        // Each rejection rewrites receipts.json. Rejecting one id past the cap,
        // 2,050 times, rewrote a growing file thousands of times and took about
        // three minutes. Seed a file that is already at the cap, then reject one
        // new id through the queue so the oldest rejected receipt is dropped.
        let disk = try makeDisk()
        let cap = HealthIngestQueue.rejectedReceiptCap
        let oldest = makeRecord(id: "hrv-cap-1", type: HealthIngestType.hrv)
        let seeded = (1 ... cap).map { index in
            let record = makeRecord(id: "hrv-cap-\(index)", type: HealthIngestType.hrv)
            return HealthIngestReceipt(
                key: "\(record.type)\n\(record.id)",
                hash: HealthIngestCanonicalJSON.digest(record.payload),
                state: .rejected,
                at: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        disk.saveReceipts(seeded)

        let queue = HealthIngestQueue(disk: disk)
        #expect(await queue.enqueue([oldest]).queued == 0)

        let extra = makeRecord(id: "hrv-cap-\(cap + 1)", type: HealthIngestType.hrv)
        #expect(await queue.enqueue([extra]).queued == 1)
        let ack = HealthIngestAck(
            type: extra.type,
            id: extra.id,
            status: .rejected,
            reason: "payload.sdnnMs is required"
        )
        for _ in 1 ... 3 {
            _ = await queue.resolve(batch: [extra], acks: [ack], transportFailed: false)
        }

        let rejected = disk.loadReceipts().filter { $0.state == .rejected }
        #expect(rejected.count == cap)
        #expect(rejected.count <= HealthIngestQueue.receiptCap)
        #expect(!rejected.contains { $0.key == "\(HealthIngestType.hrv)\nhrv-cap-1" })
        #expect(rejected.contains { $0.key == "\(HealthIngestType.hrv)\nhrv-cap-\(cap + 1)" })
        #expect(await queue.enqueue([oldest]).queued == 1)
        #expect(await queue.enqueue([makeRecord(id: "hrv-cap-2", type: HealthIngestType.hrv)]).queued == 0)
    }


    @Test func canonicalJSONMatchesJavaScriptStringEscaping() {
        // JSON.stringify leaves "/" and non-ASCII raw and escapes only ", \\ and C0 controls.
        // JSONSerialization wrote "\\/", which changed the id of any snapshot containing "mg/dL".
        let payload = HealthIngestJSON.object([
            "values": .object([
                "preferences": .object([
                    "units": .string("mg/dL"),
                    "name": .string("a\"b\\c\n\u{01}é")
                ]),
                "n": .array([.number(1), .number(2.5)])
            ])
        ])
        let expected = "{\"values\":{\"n\":[1,2.5],\"preferences\":{\"name\":\"a\\\"b\\\\c\\n\\u0001é\",\"units\":\"mg/dL\"}}}"
        #expect(HealthIngestCanonicalJSON.string(payload) == expected)
        #expect(HealthIngestCanonicalJSON.digest(payload) == "864be80a81810c42970c041c89eed7cf")
        #expect(HealthIngestCanonicalJSON.digest(canonical: expected) == HealthIngestCanonicalJSON.digest(payload))
    }

    @Test func queueKeepsOnlyAWindowInMemoryAndSpillsTheRest() async throws {
        let disk = try makeDisk()
        let queue = HealthIngestQueue(disk: disk)
        let total = 2_600
        var sent = 0
        while sent < total {
            let upper = min(sent + 500, total)
            let records = (sent ..< upper).map { makeRecord(id: "hr-\($0)", type: HealthIngestType.heartRate) }
            #expect(await queue.enqueue(records).queued == records.count)
            #expect(await queue.windowCount() <= HealthIngestQueue.windowCap)
            sent = upper
        }
        #expect(await queue.depth() == total)
        #expect(await queue.windowCount() == HealthIngestQueue.windowCap)

        // A relaunch sees the same rows without loading them all.
        let reopened = HealthIngestQueue(disk: disk)
        #expect(await reopened.depth() == total)
        #expect(await reopened.windowCount() <= HealthIngestQueue.windowCap)

        var delivered = Set<String>()
        while true {
            let batch = await reopened.nextBatch(limit: HealthIngestWire.maxBatchRecords, maxBytes: HealthIngestWire.maxBatchBytes)
            if batch.isEmpty { break }
            #expect(batch.count <= HealthIngestWire.maxBatchRecords)
            #expect(await reopened.windowCount() <= HealthIngestQueue.windowCap)
            let acks = batch.map { HealthIngestAck(type: $0.type, id: $0.id, status: .accepted, reason: nil) }
            _ = await reopened.resolve(batch: batch, acks: acks, transportFailed: false)
            for record in batch { delivered.insert(record.id) }
        }
        #expect(delivered.count == total)
        #expect(await reopened.depth() == 0)
    }

    @Test func anOversizedLegacyQueueFileIsSplitIntoSegmentsOnOpen() async throws {
        let disk = try makeDisk()
        let legacy = (0 ..< 2_500).map { index -> HealthIngestQueuedRecord in
            let record = makeRecord(id: "legacy-\(index)", type: HealthIngestType.hrv)
            return HealthIngestQueuedRecord(record: record, bytes: 200, hash: "h\(index)", failures: 0, notBefore: Date(timeIntervalSince1970: 0))
        }
        disk.saveQueue(legacy)
        let queue = HealthIngestQueue(disk: disk)
        #expect(await queue.depth() == 2_500)
        #expect(await queue.windowCount() <= HealthIngestQueue.windowCap)
        #expect(disk.loadQueue().count <= HealthIngestQueue.windowCap)
        await queue.dropTypes([HealthIngestType.hrv])
        #expect(await queue.depth() == 0)
    }

    @Test func scheduleClocksUseHourMinuteWithLeadingZeros() {
        #expect(HealthIngestCanonicalJSON.clock(seconds: 0) == "00:00")
        #expect(HealthIngestCanonicalJSON.clock(seconds: 9 * 3600 + 30 * 60) == "09:30")
        #expect(HealthIngestCanonicalJSON.clock(start: "9:05:00", seconds: 0) == "09:05")
        #expect(HealthIngestCanonicalJSON.clock(hour: 0) == "00:00")
        #expect(HealthIngestWire.mappingVersion == 7)
        #expect(HealthIngestAck.acceptedRowCount([
            HealthIngestAck(type: "hrv", id: "1", status: .accepted),
            HealthIngestAck(type: "hrv", id: "2", status: .duplicate),
            HealthIngestAck(type: "hrv", id: "3", status: .rejected, reason: "payload.sdnnMs is required")
        ]) == 1)
        #expect(HealthIngestHealthKitReader.timeout(for: HealthIngestType.workout) == 90)
        #expect(HealthIngestHealthKitReader.timeout(for: HealthIngestType.heartRate) == 30)
        let error = NSError(domain: "HealthIngest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Protected health data is unavailable"])
        #expect(HealthIngestHealthKitReader.failureText(recordType: "workout", error: error) == "workout: Protected health data is unavailable")
    }

    @Test func rejectLogKeepsTheLastTwoHundredAndClears() async throws {
        let disk = try makeDisk()
        let queue = HealthIngestQueue(disk: disk)
        for index in 0 ..< 205 {
            let record = makeRecord(id: "reject-\(index)", type: index.isMultiple(of: 2) ? HealthIngestType.loopCycle : HealthIngestType.profileSnapshot)
            #expect(await queue.enqueue([record]).queued == 1)
            let ack = HealthIngestAck(
                type: record.type,
                id: record.id,
                status: .rejected,
                reason: index.isMultiple(of: 2) ? "minPredBG out of range" : "schedule start",
                message: "detail \(index)"
            )
            _ = await queue.resolve(batch: [record], acks: [ack], transportFailed: false)
        }
        let summary = await queue.rejectionSummary()
        #expect(disk.loadRejectLog().events.count == 200)
        #expect(summary.groups.count == 2)
        let loop = try #require(summary.groups.first { $0.type == HealthIngestType.loopCycle })
        #expect(loop.count == 103)
        #expect(loop.message == "detail 204")
        #expect(await queue.rejectedCount() == 205)
        #expect(summary.groups.reduce(0) { $0 + $1.count } == 205)
        await queue.clearRejections()
        #expect(await queue.rejectedCount() == 0)
        #expect(disk.loadRejectLog().events.isEmpty)
        #expect(disk.loadRejectLog().reasons.isEmpty)
        #expect(await queue.rejectionSummary().groups.isEmpty)
    }

    @Test func rejectReasonsRemainAfterTheSampleBufferRollsOff() async throws {
        let disk = try makeDisk()
        let queue = HealthIngestQueue(disk: disk)
        for index in 0 ..< HealthIngestRejectLog.capacity {
            let record = makeRecord(id: "kcal-\(index)", type: HealthIngestType.activeEnergy)
            #expect(await queue.enqueue([record]).queued == 1)
            _ = await queue.resolve(
                batch: [record],
                acks: [HealthIngestAck(
                    type: record.type,
                    id: record.id,
                    status: .rejected,
                    reason: "payload.kcal is required",
                    message: "kcal missing"
                )],
                transportFailed: false
            )
        }
        for index in 0 ..< HealthIngestRejectLog.capacity {
            let record = makeRecord(id: "sdnn-\(index)", type: HealthIngestType.hrv)
            #expect(await queue.enqueue([record]).queued == 1)
            _ = await queue.resolve(
                batch: [record],
                acks: [HealthIngestAck(
                    type: record.type,
                    id: record.id,
                    status: .rejected,
                    reason: "payload.sdnnMs is required",
                    message: "sdnn missing"
                )],
                transportFailed: false
            )
        }
        let summary = await queue.rejectionSummary()
        #expect(disk.loadRejectLog().events.count == HealthIngestRejectLog.capacity)
        #expect(disk.loadRejectLog().events.allSatisfy { $0.type == HealthIngestType.hrv })
        let kcal = try #require(summary.groups.first { $0.reason == "payload.kcal is required" })
        #expect(kcal.count == HealthIngestRejectLog.capacity)
        #expect(kcal.message == "kcal missing")
        let rejected = await queue.rejectedCount()
        #expect(summary.groups.reduce(0) { $0 + $1.count } == rejected)
    }

    @Test func launchReconcileDropsTheStaleCounterWithoutAMappingBump() async throws {
        let disk = try makeDisk()
        disk.saveRejectedCount(15_893)
        let orphaned = #"{"events":[],"counts":{"hrv\npayload.sdnnMs is required":15893}}"#
        try orphaned.write(to: disk.directory.appendingPathComponent("reject-log.json"), atomically: true, encoding: .utf8)
        let queue = HealthIngestQueue(disk: disk)
        #expect(await queue.rejectionSummary().groups.isEmpty)
        #expect(await queue.rejectedCount() == 0)
        await queue.reconcileRejectedCount()
        #expect(disk.loadRejectedCount() == 0)
        #expect(disk.loadRejectLog().reasons.isEmpty)
        #expect(disk.loadRejectLog().didMigrateLegacyCounts == false)
        let saved = try String(contentsOf: disk.directory.appendingPathComponent("reject-log.json"), encoding: .utf8)
        #expect(!saved.contains("\"counts\""))

        let visible = """
        {"events":[{"type":"hrv","reason":"payload.sdnnMs is required","message":"sdnn missing","at":"2026-01-01T00:00:00Z"}],"counts":{"hrv\\npayload.sdnnMs is required":4}}
        """
        try visible.write(to: disk.directory.appendingPathComponent("reject-log.json"), atomically: true, encoding: .utf8)
        disk.saveRejectedCount(15_893)
        await queue.reconcileRejectedCount()
        let summary = await queue.rejectionSummary()
        let group = try #require(summary.groups.first)
        #expect(group.count == 4)
        #expect(group.reason == "payload.sdnnMs is required")
        let rejected = await queue.rejectedCount()
        #expect(summary.groups.reduce(0) { $0 + $1.count } == rejected)
        #expect(rejected == 4)
        #expect(disk.loadRejectedCount() == 4)
    }

    @Test func backfillProgressPersistsRestoresAndClears() throws {
        let disk = try makeDisk()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let stored = HealthIngestPersistedBackfill(
            days: 90,
            windowStart: start,
            rowsSent: 40,
            chosenDays: 90,
            active: true
        )
        disk.saveBackfillProgress(stored)
        #expect(disk.loadBackfillProgress() == stored)

        let restored = HealthIngestBackfillRestore.resolve(
            stored: disk.loadBackfillProgress(),
            pending: true,
            earliestCursor: start.addingTimeInterval(10 * 24 * 3600),
            now: start.addingTimeInterval(90 * 24 * 3600)
        )
        #expect(restored.active)
        #expect(restored.days == 90)
        #expect(restored.windowStart == start)
        #expect(restored.rowsSent == 40)
        #expect(restored.chosenDays == 90)

        let cleared = HealthIngestBackfillRestore.resolve(
            stored: stored,
            pending: false,
            earliestCursor: nil,
            now: start
        )
        #expect(!cleared.active)
        #expect(cleared.days == 0)
        #expect(cleared.rowsSent == 0)
        #expect(cleared.chosenDays == 90)
        disk.saveBackfillProgress(
            HealthIngestPersistedBackfill(
                days: cleared.days,
                windowStart: cleared.windowStart,
                rowsSent: cleared.rowsSent,
                chosenDays: cleared.chosenDays,
                active: cleared.active
            )
        )
        let loaded = try #require(disk.loadBackfillProgress())
        #expect(!loaded.active)
        #expect(loaded.rowsSent == 0)
        #expect(loaded.chosenDays == 90)
    }

    @Test func missingBackfillProgressUsesTheEarliestCursor() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // 68 days unread means the pass has covered 22 days of a window that must be 90.
        let cursor = now.addingTimeInterval(-68 * 24 * 3600)
        let resolved = HealthIngestBackfillRestore.resolve(
            stored: nil,
            pending: true,
            earliestCursor: cursor,
            now: now
        )
        #expect(resolved.active)
        #expect(resolved.days == 90)
        #expect(resolved.rowsSent == 0)
        #expect(resolved.chosenDays == 90)
        let progress = HealthIngestBackfillProgress.measure(
            start: resolved.windowStart,
            frontier: cursor,
            days: resolved.days,
            rowsSent: resolved.rowsSent,
            phase: "Reading Health samples"
        )
        #expect(progress.day == 23)
        #expect(progress.days == 90)
        #expect(progress.fraction > 0)
        #expect(progress.fraction < 1)

        let recent = HealthIngestBackfillProgress.recover(
            earliestCursor: now.addingTimeInterval(-2 * 24 * 3600),
            now: now
        )
        #expect(recent.days == 3)
    }

    @Test func relaunchWithSavedBackfillPublishesTheWindowBeforeCursorsLoad() throws {
        let now = Date()
        let start = now.addingTimeInterval(-90 * 24 * 3600)
        let cursor = now.addingTimeInterval(-68 * 24 * 3600)
        let status = try relaunchStatus(
            stored: HealthIngestPersistedBackfill(
                days: 90,
                windowStart: start,
                rowsSent: 1_240,
                chosenDays: 7,
                active: true
            ),
            cursor: cursor
        )
        let progress = try #require(status.backfill)
        #expect(status.backfillRunning)
        #expect(progress.days == 90)
        #expect(progress.day == 23)
        #expect(progress.rowsSent == 1_240)
        #expect(progress.fraction > 0.2)
        #expect(progress.fraction < 0.3)
    }

    @Test func relaunchWithoutSavedBackfillRecoversTheWindowFromCursors() throws {
        let cursor = Date().addingTimeInterval(-68 * 24 * 3600)
        let missing = try relaunchStatus(stored: nil, cursor: cursor)
        try expectRecoveredNinetyDayWindow(missing)

        let inactive = try relaunchStatus(
            stored: HealthIngestPersistedBackfill(
                days: 0,
                windowStart: Date(timeIntervalSince1970: 0),
                rowsSent: 0,
                chosenDays: 7,
                active: false
            ),
            cursor: cursor
        )
        try expectRecoveredNinetyDayWindow(inactive)
    }

    private func expectRecoveredNinetyDayWindow(_ status: HealthIngestStatus) throws {
        let progress = try #require(status.backfill)
        #expect(status.backfillRunning)
        #expect(progress.days == 90)
        // The cursor is 68 days before the test's clock. Recovery uses a slightly later
        // "now", so the covered span is just under 22 days (day 22) or exactly 22 (day 23).
        #expect(progress.day == 22 || progress.day == 23)
        #expect(progress.fraction > 0.2)
        #expect(progress.fraction < 0.3)
    }

    /// Fresh uploader and reader over on-disk cursors. The reader is not loaded first.
    private func relaunchStatus(stored: HealthIngestPersistedBackfill?, cursor: Date) throws -> HealthIngestStatus {
        let disk = try makeDisk()
        if let stored {
            disk.saveBackfillProgress(stored)
        }
        disk.saveCursors([HealthIngestType.heartRate: cursor])
        var preferences = HealthIngestPreferences.initial
        preferences.enabled = true
        preferences.baseURL = "https://example.ts.net"
        let uploader = HealthIngestUploader(relaunchFrom: disk, preferences: preferences)
        return uploader.publishRelaunchStatus()
    }

    @Test func freshBackfillReadsAsDayOneUntilTheCursorMoves() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let untouched = HealthIngestBackfillProgress.frontier(start: start, cursor: nil, resume: nil)
        let fresh = HealthIngestBackfillProgress.measure(
            start: start,
            frontier: untouched,
            days: 90,
            rowsSent: 0,
            phase: "Reading Health samples"
        )
        #expect(untouched == start)
        #expect(fresh.day == 1)
        #expect(fresh.days == 90)
        #expect(fresh.rowsSent == 0)
        #expect(fresh.fraction == 0)

        let day23 = start.addingTimeInterval(22 * 24 * 3600)
        let reading = HealthIngestBackfillProgress.measure(
            start: start,
            frontier: HealthIngestBackfillProgress.frontier(start: start, cursor: day23, resume: nil),
            days: 90,
            rowsSent: 1_240,
            phase: "Reading Health samples"
        )
        #expect(reading.day == 23)
        #expect(reading.rowsSent == 1_240)

        let finishedAt = start.addingTimeInterval(90 * 24 * 3600)
        let finished = HealthIngestBackfillProgress.measure(
            start: start,
            frontier: HealthIngestBackfillProgress.frontier(start: start, cursor: finishedAt, resume: nil),
            days: 90,
            rowsSent: 4_000,
            phase: "Reading Health samples"
        )
        #expect(finished.day == 90)
        #expect(finished.fraction == 1)
    }

    @Test func diabetesItemsLeaveAheadOfAHealthKitBackfill() async throws {
        let disk = try makeDisk()
        let queue = HealthIngestQueue(disk: disk)
        let total = 1_200
        var sent = 0
        while sent < total {
            let upper = min(sent + 400, total)
            let records = (sent ..< upper).map { makeRecord(id: "hr-\($0)", type: HealthIngestType.heartRate) }
            #expect(await queue.enqueue(records).queued == records.count)
            sent = upper
        }
        let recent = [
            makeRecord(id: "glucose-now", type: HealthIngestType.glucose),
            makeRecord(id: "loop-now", type: HealthIngestType.loopCycle),
            makeRecord(id: "bolus-now", type: HealthIngestType.bolus),
            makeRecord(id: "carbs-now", type: HealthIngestType.carbs),
            makeRecord(id: "basal-now", type: HealthIngestType.tempBasal)
        ]
        #expect(await queue.enqueue(recent).queued == recent.count)
        #expect(await queue.regularDepth() == total)
        #expect(await queue.priorityDepth() == recent.count)
        #expect(await queue.windowCount() <= HealthIngestQueue.windowCap)

        let batch = await queue.nextBatch(limit: HealthIngestWire.maxBatchRecords, maxBytes: HealthIngestWire.maxBatchBytes)
        #expect(Array(batch.prefix(recent.count)).map(\.id) == recent.map(\.id))
        #expect(batch.count > recent.count)
        #expect(batch[recent.count].type == HealthIngestType.heartRate)

        let acks = recent.map { HealthIngestAck(type: $0.type, id: $0.id, status: .accepted) }
        _ = await queue.resolve(batch: recent, acks: acks, transportFailed: false)
        #expect(await queue.priorityDepth() == 0)
        #expect(await queue.regularDepth() == total)
        let next = await queue.nextBatch(limit: 1, maxBytes: 1_000_000)
        #expect(next.first?.type == HealthIngestType.heartRate)
    }

    @Test func diabetesReadIsNotSkippedWhenHealthKitBacklogIsAtHighWater() async throws {
        let disk = try makeDisk()
        let queue = HealthIngestQueue(disk: disk)
        let backlog = (0 ..< 40).map { makeRecord(id: "hr-\($0)", type: HealthIngestType.heartRate) }
        #expect(await queue.enqueue(backlog).queued == backlog.count)
        let highWater = await queue.regularDepth()
        #expect(highWater == backlog.count)
        let open = HealthIngestReadGate.decide(
            healthKitDepth: highWater,
            priorityDepth: await queue.priorityDepth(),
            highWater: highWater,
            throttled: false
        )
        #expect(open.readDiabetes)
        #expect(!open.readHealthKit)

        let under = HealthIngestReadGate.decide(
            healthKitDepth: highWater,
            priorityDepth: 0,
            highWater: highWater + 1,
            throttled: false
        )
        #expect(under.readDiabetes)
        #expect(under.readHealthKit)

        let capped = HealthIngestReadGate.decide(
            healthKitDepth: 0,
            priorityDepth: HealthIngestReadGate.priorityCap,
            highWater: highWater,
            throttled: false
        )
        #expect(!capped.readDiabetes)
        #expect(capped.readHealthKit)

        let background = HealthIngestReadGate.decide(
            healthKitDepth: 0,
            priorityDepth: 0,
            highWater: highWater,
            throttled: true
        )
        #expect(!background.readDiabetes)
        #expect(background.readHealthKit)
    }

    @Test func priorityLaneSurvivesRestart() async throws {
        let disk = try makeDisk()
        let queue = HealthIngestQueue(disk: disk)
        let heart = (0 ..< 8).map { makeRecord(id: "hr-\($0)", type: HealthIngestType.heartRate) }
        let diabetes = [
            makeRecord(id: "glucose-1", type: HealthIngestType.glucose),
            makeRecord(id: "bolus-1", type: HealthIngestType.bolus),
            makeRecord(id: "carbs-1", type: HealthIngestType.carbs),
            makeRecord(id: "loop-1", type: HealthIngestType.loopCycle),
            makeRecord(id: "basal-1", type: HealthIngestType.tempBasal)
        ]
        #expect(await queue.enqueue(heart).queued == heart.count)
        #expect(await queue.enqueue(diabetes).queued == diabetes.count)

        let stored = disk.loadQueue(named: "priority.json")
        #expect(stored.map(\.record.id) == diabetes.map(\.id))
        #expect(stored.map(\.record.type) == diabetes.map(\.type))

        let reloaded = HealthIngestQueue(disk: disk)
        #expect(await reloaded.priorityDepth() == diabetes.count)
        #expect(await reloaded.regularDepth() == heart.count)
        #expect(await reloaded.depth() == heart.count + diabetes.count)
        let batch = await reloaded.nextBatch(limit: 20, maxBytes: 1_000_000)
        #expect(Array(batch.prefix(diabetes.count)).map(\.id) == diabetes.map(\.id))
        #expect(Array(batch.prefix(diabetes.count)).map(\.type) == diabetes.map(\.type))
        #expect(batch.map(\.id).contains("hr-0"))
    }

    @Test func legacyQueueMigratesOntoThePriorityLaneWithoutLoss() async throws {
        let disk = try makeDisk()
        let windowCount = HealthIngestQueue.windowCap / 2
        var window: [HealthIngestQueuedRecord] = []
        var segment: [HealthIngestQueuedRecord] = []
        var expectedPriority: [String] = []
        var expectedRegular: [String] = []
        for index in 0 ..< windowCount {
            let priority = index.isMultiple(of: 5)
            let type = priority ? HealthIngestType.glucose : HealthIngestType.heartRate
            let id = priority ? "glucose-\(index)" : "hr-\(index)"
            window.append(queued(id: id, type: type, hash: "w\(index)"))
            if priority { expectedPriority.append(id) } else { expectedRegular.append(id) }
        }
        for index in 0 ..< 80 {
            let priority = index.isMultiple(of: 2)
            let type = priority ? HealthIngestType.bolus : HealthIngestType.hrv
            let id = priority ? "bolus-\(index)" : "hrv-\(index)"
            segment.append(queued(id: id, type: type, hash: "s\(index)"))
            if priority { expectedPriority.append(id) } else { expectedRegular.append(id) }
        }
        disk.saveQueue(window)
        disk.saveSpillSegment(1, segment)
        disk.saveSpillManifest(HealthIngestSpillManifest(segments: [.init(id: 1, count: segment.count)], nextID: 2))
        #expect(!disk.loadPriorityMigrated())

        let queue = HealthIngestQueue(disk: disk)
        let total = window.count + segment.count
        #expect(await queue.depth() == total)
        #expect(await queue.priorityDepth() == expectedPriority.count)
        #expect(await queue.regularDepth() == expectedRegular.count)
        #expect(disk.loadPriorityMigrated())
        #expect(disk.loadQueue().allSatisfy { !HealthIngestType.isPriorityLane($0.record.type) })
        let manifest = disk.loadSpillManifest()
        for part in manifest.segments {
            let rows = disk.loadSpillSegment(part.id)
            #expect(rows.allSatisfy { !HealthIngestType.isPriorityLane($0.record.type) })
        }

        let reloaded = HealthIngestQueue(disk: disk)
        #expect(await reloaded.depth() == total)
        #expect(await reloaded.priorityDepth() == expectedPriority.count)
        var delivered: [String] = []
        while delivered.count < total {
            let batch = await reloaded.nextBatch(limit: HealthIngestWire.maxBatchRecords, maxBytes: HealthIngestWire.maxBatchBytes)
            if batch.isEmpty { break }
            delivered.append(contentsOf: batch.map(\.id))
            let acks = batch.map { HealthIngestAck(type: $0.type, id: $0.id, status: .accepted) }
            _ = await reloaded.resolve(batch: batch, acks: acks, transportFailed: false)
        }
        #expect(delivered == expectedPriority + expectedRegular)
        #expect(await reloaded.depth() == 0)
    }

    @Test func therapyRecordsMatchTheServerContract() throws {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let decisionId = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let eaten = at.addingTimeInterval(-120)
        let decision = HealthIngestTherapy.decisionRecord(
            decisionId: decisionId,
            at: at,
            source: "phone",
            report: therapyReport(simulatedCob: 18, at: at),
            fat: 10,
            protein: 20,
            enteredUnits: 2,
            external: false,
            skipped: false,
            carbEntryId: "22222222-2222-4222-8222-222222222222",
            carbEntryEatenAt: eaten
        )
        #expect(decision.type == HealthIngestType.bolusDecision)
        #expect(decision.id == decisionId.uuidString)
        #expect(!decision.id.contains(":"))
        #expect(decision.start == at)
        let payload = try wirePayload(decision)
        #expect(payload["source"] as? String == "phone")
        #expect(payload["timestamp"] as? String == HealthIngestTime.string(from: at))
        let inputs = try #require(payload["inputs"] as? [String: Any])
        #expect(inputs["cobSimulated"] is NSNumber)
        #expect((inputs["cobSimulated"] as? NSNumber)?.doubleValue == 18)
        #expect(!(inputs["cobSimulated"] is Bool))
        #expect((inputs["cob"] as? NSNumber)?.doubleValue == 15)
        #expect(inputs["bgMgdl"] as? NSNumber != nil)
        #expect(inputs["fattyMeal"] as? Bool == true)
        #expect(inputs["superBolusFactor"] == nil)
        let action = try #require(payload["action"] as? [String: Any])
        #expect(action["outcome"] as? String == "reduced")
        #expect(action["external"] as? Bool == false)
        let text = try wireText(decision)
        #expect(!text.contains("\"cobSimulated\":true"))
        #expect(!text.contains("\"cobSimulated\":false"))

        let withoutSimulation = HealthIngestTherapy.decisionRecord(
            decisionId: decisionId,
            at: at,
            source: "watch",
            report: therapyReport(simulatedCob: nil, at: at),
            fat: 0,
            protein: 0,
            enteredUnits: 0,
            external: false,
            skipped: true,
            carbEntryId: nil,
            carbEntryEatenAt: nil
        )
        let skippedInputs = try #require(try wirePayload(withoutSimulation)["inputs"] as? [String: Any])
        #expect(skippedInputs["cobSimulated"] == nil)
        let skippedAction = try #require(try wirePayload(withoutSimulation)["action"] as? [String: Any])
        #expect(skippedAction["outcome"] as? String == "skipped")

        let tooMuch = HealthIngestTherapy.decisionRecord(
            decisionId: decisionId,
            at: at,
            source: "remote",
            report: therapyReport(simulatedCob: 2500, at: at),
            fat: 0,
            protein: 0,
            enteredUnits: 1,
            external: true,
            skipped: false,
            carbEntryId: nil,
            carbEntryEatenAt: nil
        )
        let remoteInputs = try #require(try wirePayload(tooMuch)["inputs"] as? [String: Any])
        #expect(remoteInputs["cobSimulated"] == nil)

        let failure = HealthIngestTherapy.failureRecord(
            at: at,
            requestedUnits: 2,
            source: "watch",
            reason: "pump_error",
            message: "example pump busy https://example.invalid/path 11111111-1111-4111-8111-111111111111",
            decisionId: decisionId
        )
        let failurePayload = try wirePayload(failure)
        #expect(failurePayload["reason"] as? String == "pump_error")
        #expect(failurePayload["source"] as? String == "watch")
        #expect(failurePayload["decisionId"] as? String == decisionId.uuidString)
        let message = try #require(failurePayload["message"] as? String)
        #expect(!message.contains("http"))
        #expect(!message.contains("11111111"))

        let cgm = HealthIngestTherapy.cgmRecord(at: at, kind: "warmup_end", message: "example sensor ready")
        let cgmPayload = try wirePayload(cgm)
        #expect(cgmPayload["kind"] as? String == "warmup_end")
        #expect(cgm.id.hasPrefix("cgm-event:"))
        #expect(!cgm.id.contains("serial"))
        #expect(HealthIngestCGM.kind(type: "sensorIssue", errorCode: "warmup", fatal: false, failureMessage: nil) == "warmup_start")
        #expect(HealthIngestCGM.kind(type: "sensorIssue", errorCode: "expired", fatal: false, failureMessage: nil) == "sensor_expired")
        #expect(HealthIngestCGM.kind(type: "sensorIssue", errorCode: "sensorFailed", fatal: true, failureMessage: nil) == "sensor_failed")
        #expect(HealthIngestCGM.kind(type: "sensorStart", errorCode: nil, fatal: false, failureMessage: nil) == "sensor_start")
        #expect(HealthIngestCGM.kind(type: "calibration", errorCode: nil, fatal: false, failureMessage: nil) == "calibration")
        #expect(HealthIngestCGM.kind(type: "transmitterStart", errorCode: nil, fatal: false, failureMessage: nil) == nil)
        #expect(HealthIngestCGM.kind(type: "sensorEnd", errorCode: nil, fatal: false, failureMessage: nil) == "other")

        let loop = HealthIngestTherapy.loopFields(
            glucoseMgdl: 121,
            eventualBg: 110,
            recommendedBolus: nil,
            targetMgdl: 100,
            thresholdMgdl: 70,
            carbsRequired: 0,
            crUsed: 10
        )
        #expect(loop["glucoseMgdl"] != nil)
        #expect(loop["recommendedBolus"] == nil)
        #expect(loop["crUsed"] != nil)
        #expect(HealthIngestTherapy.loopFields(
            glucoseMgdl: 5000,
            eventualBg: nil,
            recommendedBolus: -1,
            targetMgdl: 5,
            thresholdMgdl: nil,
            carbsRequired: nil,
            crUsed: nil
        ).values.allSatisfy { $0 == nil })

        #expect(HealthIngestTherapy.pumpKind(eventType: "PumpAlarm", alarmKind: "occlusion") == "alarm")
        #expect(HealthIngestTherapy.pumpKind(eventType: "PumpAlarm", alarmKind: "low_insulin") == "alert")
        #expect(HealthIngestTherapy.usableReservoir(0xDEAD_BEEF) == nil)
        #expect(HealthIngestTherapy.usableReservoir(80) == 80)
        #expect(HealthIngestTherapy.bolusOutcome(recommended: 2.5, entered: 2, skipped: false) == "reduced")
        #expect(HealthIngestTherapy.authenticationFailureReason(LAError(.userCancel)) == "cancelled")
        #expect(HealthIngestTherapy.authenticationFailureReason(LAError(.authenticationFailed)) == "auth_failed")
    }

    @Test func therapyQueueDrainsDecisionsAndSkipsAutomaticFailures() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("health-ingest-therapy-\(UUID().uuidString)", isDirectory: true)
        HealthIngestTherapy.useTestDirectory(directory)
        defer { HealthIngestTherapy.useTestDirectory(nil) }
        let at = Date(timeIntervalSince1970: 1_700_000_100)
        let decisionId = UUID()
        HealthIngestTherapy.storeDecision(
            decisionId: decisionId,
            at: at,
            source: "phone",
            report: therapyReport(simulatedCob: 12, at: at),
            fat: 0,
            protein: 0,
            enteredUnits: 1,
            external: false,
            skipped: false,
            carbEntryId: nil,
            carbEntryEatenAt: nil
        )
        HealthIngestTherapy.storeFailure(
            at: at,
            requestedUnits: 1,
            source: "automatic",
            reason: "pump_error",
            message: "not a user bolus",
            decisionId: nil
        )
        HealthIngestTherapy.storeCGMEvent(at: at, kind: "sensor_start", message: nil)
        let carbId = UUID()
        HealthIngestTherapy.noteCarbEntered(id: carbId, at: at)
        HealthIngestTherapy.noteCarbEdited(previousID: carbId, newID: carbId, at: at.addingTimeInterval(60))
        let times = HealthIngestTherapy.carbTimes(id: carbId.uuidString)
        #expect(times.enteredAt == at)
        #expect(times.editedAt == at.addingTimeInterval(60))
        let drained = HealthIngestTherapy.drain(preferences: .initial)
        #expect(drained.contains { $0.type == HealthIngestType.bolusDecision && $0.id == decisionId.uuidString })
        #expect(drained.contains { $0.type == HealthIngestType.cgmEvent })
        #expect(!drained.contains { $0.type == HealthIngestType.bolusFailure })
        #expect(HealthIngestTherapy.drain(preferences: .initial).isEmpty)
    }

    private func therapyReport(simulatedCob: Int16?, at: Date) -> BolusCalculationReport {
        BolusCalculationReport(
            input: CalculationInput(
                carbs: 40,
                currentBG: 121,
                deltaBG: 8,
                target: 110,
                isf: 50,
                carbRatio: 10,
                iob: 1.2,
                cob: simulatedCob ?? 15,
                useFattyMealCorrectionFactor: true,
                fattyMealFactor: 1.2,
                useSuperBolus: false,
                sweetMealFactor: 0,
                basal: 0.9,
                fraction: 0.8,
                maxBolus: 8,
                maxIOB: 10,
                maxCOB: 120,
                minPredBG: 95,
                lastLoopDate: at.addingTimeInterval(-90)
            ),
            result: CalculationResult(
                insulinCalculated: 2.5,
                factoredInsulin: 2.5,
                wholeCalc: 3.1,
                iobInsulinReduction: -1.2,
                superBolusInsulin: 0,
                targetDifference: 11,
                targetDifferenceInsulin: 0.2,
                fifteenMinutesInsulin: 0.1,
                wholeCob: 55,
                wholeCobInsulin: 4
            ),
            loopCob: 15,
            simulatedCob: simulatedCob,
            enteredCarbs: 40,
            backdated: false
        )
    }

    private func queued(id: String, type: String, hash: String) -> HealthIngestQueuedRecord {
        HealthIngestQueuedRecord(
            record: makeRecord(id: id, type: type),
            bytes: 200,
            hash: hash,
            failures: 0,
            notBefore: Date(timeIntervalSince1970: 0)
        )
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

    private func wireRecord(_ record: HealthIngestRecord) throws -> [String: Any] {
        let data = try HealthIngestWire.encodeEnvelope(
            HealthIngestEnvelope(
                schemaVersion: HealthIngestWire.schemaVersion,
                device: HealthIngestDevice(id: "trio-iphone", app: "trio", appVersion: "1.0 (1)"),
                records: [record]
            )
        )
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try #require(json["records"] as? [[String: Any]])
        return try #require(records.first)
    }

    private func wireText(_ record: HealthIngestRecord) throws -> String {
        let data = try HealthIngestWire.encodeEnvelope(
            HealthIngestEnvelope(
                schemaVersion: HealthIngestWire.schemaVersion,
                device: HealthIngestDevice(id: "trio-iphone", app: "trio", appVersion: "1.0 (1)"),
                records: [record]
            )
        )
        return try #require(String(data: data, encoding: .utf8))
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
