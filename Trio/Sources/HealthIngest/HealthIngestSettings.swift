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
        case .insulin: return "Boluses and temp basals"
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
        case .glucose: return [HealthIngestType.glucose]
        case .heart: return [HealthIngestType.heartRate, HealthIngestType.hrv, HealthIngestType.restingHR]
        case .insulin: return [HealthIngestType.bolus, HealthIngestType.tempBasal]
        case .loopCycles: return [HealthIngestType.loopCycle]
        case .profilesAndSettings: return [HealthIngestType.profileSnapshot, HealthIngestType.settingsSnapshot]
        case .pumpEvents: return [HealthIngestType.pumpEvent]
        case .sleep: return [HealthIngestType.sleepStage]
        case .workouts: return [HealthIngestType.workout]
        }
    }
}

struct HealthIngestPreferences: Codable, Equatable {
    var enabled: Bool
    var baseURL: String
    /// Missing keys stay on, so turning the service on uploads every category until one is switched off.
    var categories: [String: Bool]

    static let initial = HealthIngestPreferences(enabled: false, baseURL: "", categories: [:])

    func isOn(_ category: HealthIngestCategory) -> Bool {
        categories[category.rawValue] ?? true
    }

    var requestsHealthData: Bool {
        HealthIngestCategory.allCases.contains { $0.readsHealthKit && isOn($0) }
    }
}

struct HealthIngestStatus: Equatable {
    var lastSuccess: Date?
    var lastError: String?
    var queueDepth: Int = 0
    var hasToken = false
    var backfillRunning = false
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
