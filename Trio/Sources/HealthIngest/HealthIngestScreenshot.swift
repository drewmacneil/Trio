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
    private let loaded: HealthIngestScreenshotFixture
    @Environment(AppState.self) private var appState

    init() {
        let loaded = Self.loadFixture()
        self.loaded = loaded
        _baseURL = State(initialValue: loaded.baseURL)
        _deviceID = State(initialValue: loaded.deviceID)
        _backfillDays = State(initialValue: loaded.backfillDays)
        _confirmReset = State(initialValue: HealthIngestScreenshot.mode == "reset")
    }

    private var fixture: HealthIngestScreenshotFixture { loaded }

    var body: some View {
        NavigationStack {
            if HealthIngestScreenshot.mode == "rejected" {
                HealthIngestRejectedView(groups: groups, onClear: {})
            } else {
                HealthIngestSettingsForm(
                    baseURL: $baseURL,
                    deviceID: $deviceID,
                    tokenDraft: $tokenDraft,
                    backfillDays: $backfillDays,
                    confirmReset: $confirmReset,
                    enabled: fixture.enabled,
                    hasToken: fixture.hasToken,
                    testing: false,
                    testResult: fixture.testResult,
                    status: status,
                    categoryOn: { _ in true },
                    setEnabled: { _ in },
                    setCategory: { _, _ in },
                    saveServer: {},
                    saveToken: {},
                    removeToken: {},
                    testConnection: {},
                    startBackfill: {},
                    resetBackfill: {},
                    clearRejections: {},
                    background: appState.trioBackgroundColor(for: .light)
                )
            }
        }
        .preferredColorScheme(.light)
        .onAppear {
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                windowScene.windows.forEach { $0.overrideUserInterfaceStyle = .light }
            }
        }
    }

    private static func loadFixture() -> HealthIngestScreenshotFixture {
        guard let url = HealthIngestScreenshot.fixtureURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(HealthIngestScreenshotFixture.self, from: data)
        else { return HealthIngestScreenshotFixture() }
        return decoded
    }

    private var status: HealthIngestStatus {
        HealthIngestStatus(
            lastSuccess: fixture.lastSuccess.map { Date(timeIntervalSince1970: $0) },
            lastError: fixture.lastError,
            queueDepth: fixture.queueDepth,
            rejectedCount: fixture.rejectedCount,
            hasToken: fixture.hasToken,
            backfillRunning: fixture.backfillRunning,
            latestRejectReason: fixture.latestRejectReason,
            rejectGroups: groups,
            backfill: fixture.backfillRunning
                ? HealthIngestBackfillProgress(
                    days: fixture.backfillDays,
                    day: fixture.day,
                    rowsSent: fixture.rowsSent,
                    phase: fixture.phase,
                    fraction: fixture.backfillDays > 0 ? Double(fixture.day) / Double(fixture.backfillDays) : 0
                )
                : nil
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

struct HealthIngestScreenshotFixture: Codable {
    var enabled = false
    var baseURL = ""
    var deviceID = "trio-iphone"
    var hasToken = false
    var testResult: String?
    var backfillDays = 7
    var queueDepth = 0
    var rejectedCount = 0
    var lastSuccess: TimeInterval?
    var lastError: String?
    var backfillRunning = false
    var latestRejectReason: String?
    var rowsSent = 0
    var day = 1
    var phase = "Reading Health samples"
    var groups: [HealthIngestScreenshotReject] = []
}

struct HealthIngestScreenshotReject: Codable {
    var type: String
    var reason: String
    var message: String
    var count: Int
    var lastSeen: TimeInterval
}
#endif
