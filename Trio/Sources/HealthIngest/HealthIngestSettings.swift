import Foundation

/// One switch in Settings. Record types that travel together share a category.
enum HealthIngestCategory: String, CaseIterable, Identifiable, Codable {
    case glucose
    case insulin
    case carbs
    case adjustments
    case pumpEvents
    case profilesAndSettings
    case loopCycles
    case workouts
    case heart
    case sleep
    case activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .glucose: return "Glucose"
        case .insulin: return "Boluses, SMBs, and temp basals"
        case .carbs: return "Carbs"
        case .adjustments: return "Overrides and temp targets"
        case .pumpEvents: return "Pump events"
        case .profilesAndSettings: return "Profiles and settings"
        case .loopCycles: return "Loop cycles"
        case .workouts: return "Workouts"
        case .heart: return "Heart rate, resting heart rate, and HRV"
        case .sleep: return "Sleep"
        case .activity: return "Active energy and exercise minutes"
        }
    }

    var readsHealthKit: Bool {
        switch self {
        case .activity,
             .heart,
             .sleep,
             .workouts:
            return true
        case .adjustments,
             .carbs,
             .glucose,
             .insulin,
             .loopCycles,
             .profilesAndSettings,
             .pumpEvents:
            return false
        }
    }

    var recordTypes: Set<String> {
        switch self {
        case .activity: return [HealthIngestType.activeEnergy, HealthIngestType.exerciseMinutes]
        case .adjustments: return [HealthIngestType.override, HealthIngestType.tempTarget]
        case .carbs: return [HealthIngestType.carbs]
        case .glucose: return [HealthIngestType.glucose, HealthIngestType.cgmEvent]
        case .heart: return [HealthIngestType.heartRate, HealthIngestType.hrv, HealthIngestType.restingHR]
        case .insulin: return [
                HealthIngestType.bolus,
                HealthIngestType.bolusDecision,
                HealthIngestType.bolusFailure,
                HealthIngestType.smb,
                HealthIngestType.tempBasal
            ]
        case .loopCycles: return [
                HealthIngestType.loopCycle,
                HealthIngestType.loopStat,
                HealthIngestType.effectiveProfile,
                HealthIngestType.tzChange
            ]
        case .profilesAndSettings: return [
                HealthIngestType.profileSnapshot,
                HealthIngestType.settingsSnapshot,
                HealthIngestType.profileSwitch,
                HealthIngestType.deletion
            ]
        case .pumpEvents: return [HealthIngestType.pumpEvent]
        case .sleep: return [HealthIngestType.sleepStage]
        case .workouts: return [HealthIngestType.workout]
        }
    }
}

struct HealthIngestPreferences: Codable, Equatable {
    var enabled: Bool
    var baseURL: String
    /// Must match the token's device id or the server returns 403.
    var deviceID: String
    /// Missing keys stay on, so turning the service on uploads every category until one is switched off.
    var categories: [String: Bool]

    static let initial = HealthIngestPreferences(
        enabled: false,
        baseURL: "",
        deviceID: HealthIngestWire.defaultDeviceID,
        categories: [:]
    )

    var normalizedDeviceID: String {
        let trimmed = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? HealthIngestWire.defaultDeviceID : trimmed
    }

    func isOn(_ category: HealthIngestCategory) -> Bool {
        categories[category.rawValue] ?? true
    }

    var requestsHealthData: Bool {
        HealthIngestCategory.allCases.contains { $0.readsHealthKit && isOn($0) }
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case baseURL
        case deviceID
        case categories
    }

    init(enabled: Bool, baseURL: String, deviceID: String, categories: [String: Bool]) {
        self.enabled = enabled
        self.baseURL = baseURL
        self.deviceID = deviceID
        self.categories = categories
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID) ?? HealthIngestWire.defaultDeviceID
        categories = try container.decodeIfPresent([String: Bool].self, forKey: .categories) ?? [:]
        if deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            deviceID = HealthIngestWire.defaultDeviceID
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(categories, forKey: .categories)
    }
}

struct HealthIngestRejectEvent: Codable, Equatable, Identifiable {
    var type: String
    var reason: String
    var message: String
    var at: Date

    var id: String { "\(type)|\(reason)|\(at.timeIntervalSinceReferenceDate)" }
}

/// One reason inside a record type, for the rejection detail screen.
struct HealthIngestRejectGroup: Equatable, Identifiable {
    var type: String
    var reason: String
    var message: String
    var count: Int
    var lastSeen: Date

    var id: String { "\(type)\n\(reason)" }
}

struct HealthIngestBackfillProgress: Equatable {
    var days: Int
    var day: Int
    var rowsSent: Int
    /// Shown under the state line while a backfill is running.
    var phase: String
    /// 0...1 across the selected day window.
    var fraction: Double

    /// Where this pass has read to. A missing cursor has not advanced, so the window
    /// start is used. Using "now" made a fresh 90-day pass display as day 90 before any row was sent.
    static func frontier(start: Date, cursor: Date?, resume: Date?) -> Date {
        if let cursor, let resume {
            return min(cursor, resume)
        }
        return cursor ?? resume ?? start
    }

    static func measure(start: Date, frontier: Date, days: Int, rowsSent: Int, phase: String) -> HealthIngestBackfillProgress {
        let elapsed = max(0, frontier.timeIntervalSince(start))
        let total = Double(max(days, 1)) * 24 * 3600
        let day = min(max(days, 1), max(1, Int(elapsed / (24 * 3600)) + 1))
        let fraction = min(1, elapsed / total)
        return HealthIngestBackfillProgress(
            days: days,
            day: day,
            rowsSent: rowsSent,
            phase: phase,
            fraction: fraction
        )
    }

    /// Picker values. A cursor only moves forward from the window start, so its age is a
    /// lower bound on which of these windows could still be in progress.
    static let dayChoices = [1, 3, 7, 14, 30, 90]

    /// Progress for a backfill that resumed with cursors but no saved window. The smallest
    /// choice that still reaches the earliest cursor becomes the window, and that cursor
    /// is the frontier inside it. A 68-day-old cursor can only be a 90-day pass.
    static func recover(earliestCursor: Date, now: Date, choices: [Int] = dayChoices) -> (days: Int, windowStart: Date) {
        let age = max(0, now.timeIntervalSince(earliestCursor))
        let sorted = choices.sorted()
        let days = sorted.first { Double($0) * 24 * 3600 >= age } ?? sorted.last ?? 90
        let start = now.addingTimeInterval(-Double(days) * 24 * 3600)
        return (days, start)
    }
}

/// Days, window start, and accepted-row count for the backfill that is running.
/// `chosenDays` is the picker value used once that pass is finished.
struct HealthIngestPersistedBackfill: Codable, Equatable {
    var days: Int
    var windowStart: Date
    var rowsSent: Int
    var chosenDays: Int
    var active: Bool
}

enum HealthIngestBackfillRestore {
    struct State: Equatable {
        var days: Int
        var windowStart: Date
        var rowsSent: Int
        var chosenDays: Int
        var active: Bool
    }

    /// Pending cursors keep a saved pass. With no saved pass, the earliest cursor
    /// supplies the window. A finished pass drops the counts and keeps the picker value.
    static func resolve(
        stored: HealthIngestPersistedBackfill?,
        pending: Bool,
        earliestCursor: Date?,
        now: Date
    ) -> State {
        let savedChoice = stored?.chosenDays
        guard pending else {
            return State(
                days: 0,
                windowStart: Date(timeIntervalSince1970: 0),
                rowsSent: 0,
                chosenDays: savedChoice ?? 7,
                active: false
            )
        }
        if let stored, stored.active, stored.days > 0 {
            return State(
                days: stored.days,
                windowStart: stored.windowStart,
                rowsSent: stored.rowsSent,
                chosenDays: stored.chosenDays,
                active: true
            )
        }
        let cursor = earliestCursor ?? now
        let recovered = HealthIngestBackfillProgress.recover(earliestCursor: cursor, now: now)
        return State(
            days: recovered.days,
            windowStart: recovered.windowStart,
            rowsSent: 0,
            chosenDays: savedChoice ?? recovered.days,
            active: true
        )
    }
}

struct HealthIngestStatus: Equatable {
    var lastSuccess: Date?
    var lastError: String?
    /// Trio rows plus Health rows still waiting.
    var queueDepth: Int = 0
    /// Trio rows included in `queueDepth`. These leave the queue before HealthKit backfill.
    var priorityDepth: Int = 0

    var healthDepth: Int { max(0, queueDepth - priorityDepth) }
    var rejectedCount: Int = 0
    var hasToken = false
    var backfillRunning = false
    var latestRejectReason: String?
    var rejectGroups: [HealthIngestRejectGroup] = []
    var backfill: HealthIngestBackfillProgress?
    /// Set while stored Trio rows are being reread. This is not a HealthKit backfill,
    /// so the Health day counter stays off.
    var trioHistoryPhase: String? = nil

    static let resendingTrioHistory = "Resending stored Trio history"

    /// Shown instead of a red error while HealthKit cannot read because the iPhone is locked.
    static let pausedUntilUnlock = "Paused until iPhone is unlocked"

    /// The locked-device line. Older builds stored `heart_rate: Protected health data is inaccessible`.
    static func isPausedUntilUnlock(_ message: String?) -> Bool {
        guard let message, !message.isEmpty else { return false }
        if message == pausedUntilUnlock { return true }
        return message.hasSuffix("Protected health data is inaccessible")
    }

    var isPausedUntilUnlock: Bool { Self.isPausedUntilUnlock(lastError) }

    /// A server or network error stays on screen while a backfill is running.
    /// A locked iPhone is `isPausedUntilUnlock`, not this row.
    var showsLastError: Bool {
        guard let lastError, !lastError.isEmpty else { return false }
        return !isPausedUntilUnlock
    }

    /// The Trio reread line stays on screen while a Health backfill is running.
    var showsTrioHistoryPhase: Bool {
        guard let trioHistoryPhase else { return false }
        return !trioHistoryPhase.isEmpty
    }

    /// The dot's title. Backfill keeps this title when `lastError` is set;
    /// the error is its own row. A locked iPhone stays on this title during a
    /// backfill and shows the pause line instead of a red error.
    var stateTitle: String {
        if backfillRunning { return "Backfilling" }
        if isPausedUntilUnlock { return "Paused" }
        if showsLastError { return "Error" }
        return "Up to date"
    }
}

/// Upload preferences live in UserDefaults. The bearer token lives only in the Keychain.
final class HealthIngestSettingsStore {
    static let tokenKey = "HealthIngest.token"
    private let defaultsKey = "HealthIngest.preferences"
    private let defaults: UserDefaults
    private let keychain: Keychain

    init(defaults: UserDefaults = .standard, keychain: Keychain) {
        self.defaults = defaults
        self.keychain = keychain
    }

    func load() -> HealthIngestPreferences {
        guard let data = defaults.data(forKey: defaultsKey),
              let preferences = try? JSONDecoder().decode(HealthIngestPreferences.self, from: data)
        else { return .initial }
        return preferences
    }

    func save(_ preferences: HealthIngestPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    func hasToken() -> Bool {
        guard case let .success(value) = keychain.getValue(String.self, forKey: Self.tokenKey) else { return false }
        return !(value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func token() -> String? {
        guard case let .success(value) = keychain.getValue(String.self, forKey: Self.tokenKey) else { return nil }
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func setToken(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            keychain.removeObject(forKey: Self.tokenKey)
        } else {
            keychain.setValue(trimmed, forKey: Self.tokenKey)
        }
    }
}
