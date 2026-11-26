import Foundation

/// One saved settings version: the profile and preferences Trio already stores
/// for oref. Built by reading those values. It does not run or alter dosing.
enum HealthIngestSettingsVersion {
    struct Input {
        var preferences: Preferences
        var profile: TrioTherapyProfile?
        var activeProfileName: String?
        var diaHours: Double?
        var maxBolus: Double?
        var maxBasal: Double?
        var pumpModel: String? = nil
        var supportedBasalRates: [Double] = []
        var trioVersion: String?
        var gitSha: String? = nil
    }

    /// Nested under `settings_snapshot.payload.values.version`. No timestamp:
    /// the record's `start` is when this content was first observed.
    static func object(_ input: Input) -> HealthIngestJSON {
        let preferences = input.preferences
        let mode = dynamicIsfMode(preferences)
        let incomplete = schedulesArePlaceholder(input.profile)
        return .object([
            "incomplete": incomplete ? .bool(true) : nil,
            "trioVersion": input.trioVersion.map { .string($0) },
            "gitSha": input.gitSha.flatMap { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : .string(trimmed)
            },
            "activeProfileName": .string(Self.profileName(input.activeProfileName)),
            "units": .object([
                "basal": .string("U/hr"),
                "carbRatio": .string("g/U"),
                "isf": .string("mg/dL/U"),
                "target": .string("mg/dL"),
                "dia": .string("h"),
                "insulinPeak": .string("min"),
                "threshold": .string("mg/dL"),
                "halfBasalExerciseTarget": .string("mg/dL"),
                "maxBolus": .string("U"),
                "maxBasal": .string("U/hr"),
                "maxIOB": .string("U"),
                "maxCOB": .string("g")
            ]),
            "basalSchedule": incomplete ? nil : schedule(input.profile?.basal ?? [], unit: "U/hr"),
            "carbRatioSchedule": incomplete ? nil : schedule(input.profile?.carbRatio ?? [], unit: "g/U"),
            "isfSchedule": incomplete ? nil : schedule(input.profile?.sensitivity ?? [], unit: "mg/dL/U"),
            "targetSchedule": incomplete ? nil : targetSchedule(input.profile?.target ?? []),
            "diaHours": number(input.diaHours),
            "insulinCurve": .string(preferences.curve.rawValue),
            "useCustomPeakTime": .bool(preferences.useCustomPeakTime),
            "insulinPeakMinutes": .number(double(preferences.insulinPeakTime)),
            "maxIOB": .number(double(preferences.maxIOB)),
            "maxBolus": number(input.maxBolus),
            "maxBasal": number(input.maxBasal),
            "maxCOB": .number(double(preferences.maxCOB)),
            "thresholdMgdl": .number(double(preferences.threshold_setting)),
            "smb": .object([
                "enableAlways": .bool(preferences.enableSMBAlways),
                "enableWithCOB": .bool(preferences.enableSMBWithCOB),
                "enableWithTempTarget": .bool(preferences.enableSMBWithTemptarget),
                "enableAfterCarbs": .bool(preferences.enableSMBAfterCarbs),
                "enableHighBg": .bool(preferences.enableSMB_high_bg),
                "allowWithHighTempTarget": .bool(preferences.allowSMBWithHighTemptarget),
                "highBgTargetMgdl": .number(double(preferences.enableSMB_high_bg_target)),
                "maxSmbBasalMinutes": .number(double(preferences.maxSMBBasalMinutes)),
                "maxUamBasalMinutes": .number(double(preferences.maxUAMSMBBasalMinutes)),
                "deliveryRatio": .number(double(preferences.smbDeliveryRatio)),
                "intervalMinutes": .number(double(preferences.smbInterval)),
                "maxAllowedRise": .number(double(preferences.maxDeltaBGthreshold))
            ]),
            "uamEnabled": .bool(preferences.enableUAM),
            "autosensMin": .number(double(preferences.autosensMin)),
            "autosensMax": .number(double(preferences.autosensMax)),
            "dynamicIsf": .object([
                "mode": .string(mode),
                "useNewFormula": .bool(preferences.useNewFormula),
                "sigmoid": .bool(preferences.sigmoid),
                "adjustmentFactor": .number(double(preferences.adjustmentFactor)),
                "adjustmentFactorSigmoid": .number(double(preferences.adjustmentFactorSigmoid)),
                "useWeightedAverage": .bool(preferences.useWeightedAverage),
                "weightPercentage": .number(double(preferences.weightPercentage)),
                "adjustBasal": .bool(preferences.tddAdjBasal)
            ]),
            "targetBehavior": .object([
                "highTempTargetRaisesSensitivity": .bool(preferences.highTemptargetRaisesSensitivity),
                "lowTempTargetLowersSensitivity": .bool(preferences.lowTemptargetLowersSensitivity),
                "sensitivityRaisesTarget": .bool(preferences.sensitivityRaisesTarget),
                "resistanceLowersTarget": .bool(preferences.resistanceLowersTarget),
                "advTargetAdjustments": .bool(preferences.advTargetAdjustments),
                "exerciseMode": .bool(preferences.exerciseMode),
                "halfBasalExerciseTarget": .number(double(preferences.halfBasalExerciseTarget)),
                "wideBGTargetRange": .bool(preferences.wideBGTargetRange)
            ]),
            "safety": .object([
                "maxDailySafetyMultiplier": .number(double(preferences.maxDailySafetyMultiplier)),
                "currentBasalSafetyMultiplier": .number(double(preferences.currentBasalSafetyMultiplier)),
                "noisyCGMTargetMultiplier": .number(double(preferences.noisyCGMTargetMultiplier))
            ]),
            "min5mCarbImpact": .number(double(preferences.min5mCarbimpact)),
            "remainingCarbsFraction": .number(double(preferences.remainingCarbsFraction)),
            "remainingCarbsCap": .number(double(preferences.remainingCarbsCap)),
            "raw": .object([
                "preferences": HealthIngestWire.jsonValue(preferences),
                "pumpSettings": .object([
                    "insulin_action_curve": number(input.diaHours),
                    "diaHours": number(input.diaHours),
                    "maxBolus": number(input.maxBolus),
                    "maxBasal": number(input.maxBasal),
                    "pumpModel": input.pumpModel.flatMap { value in
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.isEmpty ? nil : .string(trimmed)
                    },
                    "supportedBasalRates": input.supportedBasalRates.isEmpty
                        ? nil
                        : .array(input.supportedBasalRates.map { .number($0) })
                ]),
                "profile": incomplete ? .object([:]) : rawProfile(input.profile)
            ])
        ])
    }

    static func profileName(_ name: String?) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? TrioTherapyProfile.defaultName : trimmed
    }

    /// A missing profile, or the single 0 U/hr basal with no CR, ISF, or target, is not a saved schedule.
    static func schedulesArePlaceholder(_ profile: TrioTherapyProfile?) -> Bool {
        guard let profile else { return true }
        let othersEmpty = profile.carbRatio.isEmpty && profile.sensitivity.isEmpty && profile.target.isEmpty
        guard othersEmpty else { return false }
        if profile.basal.isEmpty { return true }
        guard profile.basal.count == 1, profile.basal[0].seconds == 0 else { return false }
        return double(profile.basal[0].value) == 0
    }

    /// `off` when dynamic ISF is disabled, otherwise `sigmoid` or `log`.
    static func dynamicIsfMode(_ preferences: Preferences) -> String {
        guard preferences.useNewFormula else { return "off" }
        return preferences.sigmoid ? "sigmoid" : "log"
    }

    private static func schedule(_ entries: [TherapyScheduleEntry], unit: String) -> HealthIngestJSON {
        .array(entries.map { entry in
            .object([
                "startMinuteOfDay": .number(Double(entry.seconds / 60)),
                "value": .number(double(entry.value)),
                "unit": .string(unit)
            ])
        })
    }

    private static func targetSchedule(_ entries: [TherapyTargetEntry]) -> HealthIngestJSON {
        .array(entries.map { entry in
            let low = double(entry.low)
            let high = double(entry.high)
            return .object([
                "startMinuteOfDay": .number(Double(entry.seconds / 60)),
                "low": .number(low),
                "high": .number(high),
                // oref doses to the low target. `value` is that number.
                "value": .number(low),
                "unit": .string("mg/dL")
            ])
        })
    }

    /// Schedules in the names `Profile` uses when it is handed to oref.
    private static func rawProfile(_ profile: TrioTherapyProfile?) -> HealthIngestJSON {
        guard let profile else { return .object([:]) }
        return .object([
            "basalprofile": .array(profile.basal.map { entry in
                .object([
                    "start": .string(HealthIngestCanonicalJSON.clock(seconds: entry.seconds)),
                    "minutes": .number(Double(entry.seconds / 60)),
                    "rate": .number(double(entry.value))
                ])
            }),
            "carb_ratios": .array(profile.carbRatio.map { entry in
                .object([
                    "start": .string(HealthIngestCanonicalJSON.clock(seconds: entry.seconds)),
                    "offset": .number(Double(entry.seconds / 60)),
                    "ratio": .number(double(entry.value))
                ])
            }),
            "isfProfile": .array(profile.sensitivity.map { entry in
                .object([
                    "start": .string(HealthIngestCanonicalJSON.clock(seconds: entry.seconds)),
                    "offset": .number(Double(entry.seconds / 60)),
                    "sensitivity": .number(double(entry.value))
                ])
            }),
            "bg_targets": .array(profile.target.map { entry in
                .object([
                    "start": .string(HealthIngestCanonicalJSON.clock(seconds: entry.seconds)),
                    "offset": .number(Double(entry.seconds / 60)),
                    "low": .number(double(entry.low)),
                    "high": .number(double(entry.high))
                ])
            })
        ])
    }

    private static func double(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }

    private static func number(_ value: Double?) -> HealthIngestJSON? {
        guard let value, value.isFinite else { return nil }
        return .number(value)
    }
}

/// The basal, carb ratio, ISF, and target files the loop is already using.
/// A stored therapy-profile row can be name-only at launch; these files are the schedules.
enum HealthIngestLiveProfile {
    static func read(_ storage: FileStorage) -> TrioTherapyProfile? {
        let basal = storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self)
        let carbRatios = storage.retrieve(OpenAPS.Settings.carbRatios, as: CarbRatios.self)
        let sensitivities = storage.retrieve(OpenAPS.Settings.insulinSensitivities, as: InsulinSensitivities.self)
        let targets = storage.retrieve(OpenAPS.Settings.bgTargets, as: BGTargets.self)
        if basal == nil, carbRatios == nil, sensitivities == nil, targets == nil { return nil }
        return TrioTherapyProfile(
            name: TrioTherapyProfile.defaultName,
            basalProfile: basal ?? [],
            carbRatios: carbRatios ?? CarbRatios(units: .grams, schedule: []),
            insulinSensitivities: sensitivities ?? InsulinSensitivities(
                units: .mgdL,
                userPreferredUnits: .mgdL,
                sensitivities: []
            ),
            bgTargets: targets ?? BGTargets(units: .mgdL, userPreferredUnits: .mgdL, targets: [])
        )
    }

    /// Prefer a live schedule that is not the 0 U/hr placeholder. Keep the stored profile name.
    static func resolved(
        stored: StoredTherapyProfiles?,
        live: TrioTherapyProfile?
    ) -> (profile: TrioTherapyProfile?, name: String) {
        let name = HealthIngestSettingsVersion.profileName(
            stored?.activeProfileName ?? stored?.activeProfileValues?.name
        )
        if let live, !HealthIngestSettingsVersion.schedulesArePlaceholder(live) {
            return (live.renamed(name), name)
        }
        if let storedProfile = stored?.activeProfileValues,
           !HealthIngestSettingsVersion.schedulesArePlaceholder(storedProfile)
        {
            return (storedProfile.renamed(name), name)
        }
        let fallback = live ?? stored?.activeProfileValues
        return (fallback?.renamed(name), name)
    }
}
