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
        var trioVersion: String?
    }

    /// Nested under `settings_snapshot.payload.values.version`. No timestamp:
    /// the record's `start` is when this content was first observed.
    static func object(_ input: Input) -> HealthIngestJSON {
        let preferences = input.preferences
        let mode = dynamicIsfMode(preferences)
        return .object([
            "trioVersion": input.trioVersion.map { .string($0) },
            "activeProfileName": input.activeProfileName.map { .string($0) },
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
            "basalSchedule": schedule(input.profile?.basal ?? [], unit: "U/hr"),
            "carbRatioSchedule": schedule(input.profile?.carbRatio ?? [], unit: "g/U"),
            "isfSchedule": schedule(input.profile?.sensitivity ?? [], unit: "mg/dL/U"),
            "targetSchedule": targetSchedule(input.profile?.target ?? []),
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
                    "maxBolus": number(input.maxBolus),
                    "maxBasal": number(input.maxBasal)
                ]),
                "profile": rawProfile(input.profile)
            ])
        ])
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
