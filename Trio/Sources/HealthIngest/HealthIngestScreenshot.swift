#if DEBUG
    import SwiftUI
    import UIKit

    /// Debug-only host so the settings screen can be captured without onboarding.
    /// Fixture values stay out of the repo: pass a JSON file path after the mode.
    enum HealthIngestScreenshot {
        static var isActive: Bool {
            ProcessInfo.processInfo.arguments.contains("-HealthIngestScreenshot")
        }

        static var mode: String {
            let args = ProcessInfo.processInfo.arguments
            guard let index = args.firstIndex(of: "-HealthIngestScreenshot"), index + 1 < args.count else { return "off" }
            return args[index + 1]
        }

        /// `uptodate-status` scrolls the form to the status section. The fixture file is separate.
        static var scrollAnchor: String? {
            let parts = mode.split(separator: "-", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return String(parts[1])
        }

        static var fixtureURL: URL? {
            let args = ProcessInfo.processInfo.arguments
            guard let index = args.firstIndex(of: "-HealthIngestScreenshot"), index + 2 < args.count else { return nil }
            return URL(fileURLWithPath: args[index + 2])
        }
    }

    struct HealthIngestScreenshotHost: View {
        @State private var baseURL: String
        @State private var deviceID: String
        @State private var tokenDraft = ""
        @State private var backfillDays: Int
        @State private var confirmReset: Bool
        @State private var confirmRemoveServer = false
        private let loaded: HealthIngestScreenshotFixture
        private let relaunched: HealthIngestStatus?
        @Environment(AppState.self) private var appState

        init() {
            let loaded = Self.loadFixture()
            self.loaded = loaded
            let relaunched = HealthIngestScreenshot.mode.hasPrefix("relaunch") ? Self.relaunchStatus() : nil
            self.relaunched = relaunched
        _baseURL = State(initialValue: loaded.baseURL)
        _deviceID = State(initialValue: loaded.deviceID)
        _tokenDraft = State(initialValue: loaded.tokenDraft)
            _backfillDays = State(initialValue: relaunched?.backfill?.days ?? loaded.backfillDays)
            _confirmReset = State(initialValue: HealthIngestScreenshot.mode == "reset")
        }

        /// On-disk cursors and a saved 90-day pass, then the same restore a relaunch publishes.
        /// The reader is not loaded before that restore. `chosenDays` is the picker default, 7.
        private static func relaunchStatus() -> HealthIngestStatus? {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("health-ingest-relaunch-shot", isDirectory: true)
            guard let disk = try? HealthIngestDisk(directory: directory) else { return nil }
            let now = Date()
            disk.saveCursors([HealthIngestType.heartRate: now.addingTimeInterval(-68 * 24 * 3600)])
            disk.saveBackfillProgress(
                HealthIngestPersistedBackfill(
                    days: 90,
                    windowStart: now.addingTimeInterval(-90 * 24 * 3600),
                    rowsSent: 1240,
                    chosenDays: 7,
                    active: true
                )
            )
            var preferences = HealthIngestPreferences.initial
            preferences.enabled = true
            preferences.baseURL = "https://example.ts.net"
            return HealthIngestUploader(relaunchFrom: disk, preferences: preferences).publishRelaunchStatus()
        }

        private var fixture: HealthIngestScreenshotFixture { loaded }

        private var screenName: String {
            String(HealthIngestScreenshot.mode.split(separator: "-").first ?? "home")
        }

        private var connectionPhase: HealthIngestConnectionPhase {
            let tested = Date(timeIntervalSince1970: fixture.lastTested ?? fixture.lastSuccess ?? 1_795_718_520)
            switch fixture.connection {
            case "testing": return .testing
            case "notTested": return .notTested
            case "notConfigured": return .notConfigured
            case "timedOut": return .timedOut(testedAt: tested)
            case "tokenRejected": return .tokenRejected(testedAt: tested)
            case "badURL": return .badURL(testedAt: tested)
            case "unreachable": return .unreachable(testedAt: tested)
            default:
                return .connected(milliseconds: fixture.latencyMS, testedAt: tested)
            }
        }

        var body: some View {
            NavigationStack {
                switch screenName {
                case "rejected":
                    HealthIngestRejectedView(groups: groups, onClear: {})
                case "server":
                    HealthIngestServerScreen(
                        baseURL: $baseURL,
                        deviceID: $deviceID,
                        tokenDraft: $tokenDraft,
                        hasToken: fixture.hasToken,
                        phase: connectionPhase,
                        saveServer: {},
                        saveToken: {},
                        removeToken: {},
                        removeServer: {},
                        testConnection: {},
                        showsRemoveServer: fixture.hasToken || !fixture.baseURL.isEmpty
                    )
                case "token":
                    HealthIngestTokenScreen(tokenDraft: $tokenDraft, hasToken: fixture.hasToken, save: {})
                case "sent":
                    HealthIngestSentScreen()
                case "history":
                    HealthIngestHistoryScreen(
                        backfillDays: $backfillDays,
                        choices: HealthIngestBackfillProgress.dayChoices,
                        running: status.backfillRunning,
                        progress: status.backfill,
                        windowDays: status.backfill?.days ?? backfillDays,
                        enabled: fixture.enabled,
                        remember: { _ in },
                        start: {}
                    )
                case "diagnostics":
                    HealthIngestDiagnosticsScreen(status: status, reset: {}, clear: {})
                default:
                    HealthIngestSettingsForm(
                        baseURL: $baseURL,
                        deviceID: $deviceID,
                        tokenDraft: $tokenDraft,
                        backfillDays: $backfillDays,
                        confirmReset: $confirmReset,
                        confirmRemoveServer: $confirmRemoveServer,
                        enabled: fixture.enabled,
                        hasToken: fixture.hasToken,
                        testing: fixture.connection == "testing",
                        phase: connectionPhase,
                        status: status,
                        setEnabled: { _ in },
                        saveServer: {},
                        saveToken: {},
                        removeToken: {},
                        removeServer: {},
                        testConnection: {},
                        startBackfill: {},
                        rememberBackfillDays: { _ in },
                        resetBackfill: {},
                        clearRejections: {},
                        background: appState.trioBackgroundColor(for: .light)
                    )
                }
            }
            .preferredColorScheme(.light)
            .background(LightWindowStyle())
        }

        private static func loadFixture() -> HealthIngestScreenshotFixture {
            guard let url = HealthIngestScreenshot.fixtureURL,
                  let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(HealthIngestScreenshotFixture.self, from: data)
            else { return HealthIngestScreenshotFixture() }
            return decoded
        }

        private var status: HealthIngestStatus {
            if let relaunched {
                var status = relaunched
                status.queueDepth = fixture.queueDepth
                status.priorityDepth = fixture.priorityDepth
                status.backfillDepth = fixture.backfillDepth
                status.hasToken = fixture.hasToken
                status.lastSuccess = fixture.lastSuccess.map { Date(timeIntervalSince1970: $0) }
                status.rejectedCount = fixture.rejectedCount
                status.latestRejectReason = fixture.latestRejectReason
                status.rejectGroups = groups
                return status
            }
            let backfill = fixture.backfillRunning
                ? HealthIngestBackfillProgress(
                    days: fixture.backfillDays,
                    day: fixture.day,
                    rowsSent: fixture.rowsSent,
                    phase: fixture.phase,
                    fraction: fixture.backfillDays > 0 ? Double(fixture.day) / Double(fixture.backfillDays) : 0
                )
                : nil
            let rewriteDays = 90
            let rewrite = fixture.rewriting
                ? HealthIngestBackfillProgress(
                    days: rewriteDays,
                    day: fixture.day,
                    rowsSent: fixture.rowsSent,
                    phase: HealthIngestStatus.rewritingPhase,
                    fraction: rewriteDays > 0 ? Double(max(fixture.day - 1, 0)) / Double(rewriteDays) : 0
                )
                : nil
            return HealthIngestStatus(
                lastSuccess: fixture.lastSuccess.map { Date(timeIntervalSince1970: $0) },
                lastError: fixture.lastError,
                queueDepth: fixture.queueDepth,
                priorityDepth: fixture.priorityDepth,
                backfillDepth: fixture.backfillDepth,
                rejectedCount: fixture.rejectedCount,
                hasToken: fixture.hasToken,
                backfillRunning: fixture.backfillRunning,
                latestRejectReason: fixture.latestRejectReason,
                rejectGroups: groups,
                backfill: backfill,
                rewrite: rewrite
            )
        }

        private var groups: [HealthIngestRejectGroup] {
            fixture.groups.map { row in
                HealthIngestRejectGroup(
                    type: row.type,
                    reason: row.reason,
                    message: row.message,
                    count: row.count,
                    lastSeen: Date(timeIntervalSince1970: row.lastSeen)
                )
            }
        }
    }

    /// Sets the window to light once it exists, so asset colors follow the light mocks.
    private struct LightWindowStyle: UIViewControllerRepresentable {
        func makeUIViewController(context _: Context) -> Controller { Controller() }
        func updateUIViewController(_ controller: Controller, context _: Context) {
            controller.apply()
        }

        final class Controller: UIViewController {
            override func viewDidAppear(_ animated: Bool) {
                super.viewDidAppear(animated)
                apply()
            }

            func apply() {
                view.window?.overrideUserInterfaceStyle = .light
            }
        }
    }

    struct HealthIngestScreenshotFixture: Decodable {
        var enabled = false
        var baseURL = ""
    var deviceID = "trio-iphone"
    var tokenDraft = ""
    var hasToken = false
        var testResult: String?
        var backfillDays = 7
        var queueDepth = 0
        /// Trio rows included in `queueDepth`. Health rows are the remainder.
        var priorityDepth = 0
        var backfillDepth = 0
        var connection = "connected"
        var latencyMS = 84
        var lastTested: TimeInterval?
        var rejectedCount = 0
        var lastSuccess: TimeInterval?
        var lastError: String?
        var backfillRunning = false
        /// Core Data rewrite card. Fake day, rows, and queue come from the other fields.
        var rewriting = false
        var latestRejectReason: String?
        var rowsSent = 0
        var day = 1
        var phase = "Reading Health samples"
        var groups: [HealthIngestScreenshotReject] = []

        private enum CodingKeys: String, CodingKey {
            case enabled
            case baseURL
        case deviceID
        case tokenDraft
        case hasToken
            case testResult
            case backfillDays
            case queueDepth
            case priorityDepth
            case backfillDepth
            case connection
            case latencyMS
            case lastTested
            case rejectedCount
            case lastSuccess
            case lastError
            case backfillRunning
            case rewriting
            case latestRejectReason
            case rowsSent
            case day
            case phase
            case groups
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID) ?? "trio-iphone"
        tokenDraft = try container.decodeIfPresent(String.self, forKey: .tokenDraft) ?? ""
        hasToken = try container.decodeIfPresent(Bool.self, forKey: .hasToken) ?? false
            testResult = try container.decodeIfPresent(String.self, forKey: .testResult)
            backfillDays = try container.decodeIfPresent(Int.self, forKey: .backfillDays) ?? 7
            queueDepth = try container.decodeIfPresent(Int.self, forKey: .queueDepth) ?? 0
            priorityDepth = try container.decodeIfPresent(Int.self, forKey: .priorityDepth) ?? 0
            backfillDepth = try container.decodeIfPresent(Int.self, forKey: .backfillDepth) ?? 0
            connection = try container.decodeIfPresent(String.self, forKey: .connection) ?? "connected"
            latencyMS = try container.decodeIfPresent(Int.self, forKey: .latencyMS) ?? 84
            lastTested = try container.decodeIfPresent(TimeInterval.self, forKey: .lastTested)
            rejectedCount = try container.decodeIfPresent(Int.self, forKey: .rejectedCount) ?? 0
            lastSuccess = try container.decodeIfPresent(TimeInterval.self, forKey: .lastSuccess)
            lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
            backfillRunning = try container.decodeIfPresent(Bool.self, forKey: .backfillRunning) ?? false
            rewriting = try container.decodeIfPresent(Bool.self, forKey: .rewriting) ?? false
            latestRejectReason = try container.decodeIfPresent(String.self, forKey: .latestRejectReason)
            rowsSent = try container.decodeIfPresent(Int.self, forKey: .rowsSent) ?? 0
            day = try container.decodeIfPresent(Int.self, forKey: .day) ?? 1
            phase = try container.decodeIfPresent(String.self, forKey: .phase) ?? "Reading Health samples"
            groups = try container.decodeIfPresent([HealthIngestScreenshotReject].self, forKey: .groups) ?? []
        }
    }

    struct HealthIngestScreenshotReject: Codable {
        var type: String
        var reason: String
        var message: String
        var count: Int
        var lastSeen: TimeInterval
    }
#endif
