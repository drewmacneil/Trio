import Foundation

extension UserDefaults {
    private enum Keys {
        static let liveActivityOrder = "liveActivityOrder"
    }

    func loadLiveActivityOrderFromUserDefaults() -> [LiveActivityAttributes.LiveActivityItem]? {
        if let itemStrings = stringArray(forKey: Keys.liveActivityOrder) {
            return itemStrings.map { string in
                if string == "" {
                    return .empty
                } else {
                    return LiveActivityAttributes.LiveActivityItem(rawValue: string) ?? .empty
                }
            }
        }
        return nil
    }
}

extension LiveActivityAttributes.SimpleViewStyle {
    init(settings: TrioSettings) {
        self.init(fontSize: settings.liveActivitySimpleFontSize)
    }
}

extension LiveActivityAttributes {
    /// Places readings into fixed 5-minute slots ending at the newest reading's slot.
    /// A slot with no reading stays nil, so a gap does not move the dots after it.
    /// Two readings in one slot keep the later one. Readings outside the 72-slot window are dropped.
    static func chartSlots(from readings: [GlucoseData]) -> (start: Date, glucose: [Int?]) {
        guard let newest = readings.map(\.date).max() else {
            return (Date(timeIntervalSince1970: 0), [])
        }
        let newestBin = floor(newest.timeIntervalSince1970 / chartStride) * chartStride
        let start = Date(timeIntervalSince1970: newestBin - TimeInterval(chartSlotCount - 1) * chartStride)
        var slots = [Int?](repeating: nil, count: chartSlotCount)
        var slotDates = [Date?](repeating: nil, count: chartSlotCount)
        for reading in readings {
            let bin = floor(reading.date.timeIntervalSince1970 / chartStride) * chartStride
            let index = Int(((bin - start.timeIntervalSince1970) / chartStride).rounded())
            guard slots.indices.contains(index) else { continue }
            if let existing = slotDates[index], existing >= reading.date { continue }
            slots[index] = reading.glucose
            slotDates[index] = reading.date
        }
        return (start, slots)
    }
}

extension LiveActivityAttributes.ContentState {
    static func calculateChange(chart: [GlucoseData], units: GlucoseUnits) -> String {
        guard chart.count >= 2 else { return "" }

        let lastGlucose = Decimal(chart.first?.glucose ?? 0)
        let secondLastGlucose = Decimal(chart.dropFirst().first?.glucose ?? 0)
        return (lastGlucose - secondLastGlucose).formattedDelta(for: units)
    }

    init(
        new bg: GlucoseData,
        prev _: GlucoseData?,
        units: GlucoseUnits,
        chart: [GlucoseData],
        settings: TrioSettings,
        determination: DeterminationData?,
        iob: Decimal?,
        override: OverrideData?,
        tempTarget: TempTargetData?,
        widgetItems: [LiveActivityAttributes.LiveActivityItem]?
    ) {
        let glucose = bg.glucose
        let formattedBG = glucose.formatted(for: units)
        var rotationDegrees = 0.0

        switch bg.direction {
        case .doubleUp,
             .singleUp,
             .tripleUp:
            rotationDegrees = -90
        case .fortyFiveUp:
            rotationDegrees = -45
        case .flat:
            rotationDegrees = 0
        case .fortyFiveDown:
            rotationDegrees = 45
        case .doubleDown,
             .singleDown,
             .tripleDown:
            rotationDegrees = 90
        case nil,
             .notComputable,
             .rateOutOfRange:
            rotationDegrees = 0
        default:
            rotationDegrees = 0
        }

        let trendString = bg.direction?.symbol as? String
        let change = Self.calculateChange(chart: chart, units: units)

        // Only ship chart/forecast data when a Detailed surface will actually
        // draw it. History is 72 fixed 5-minute slots (6h), not one date per point,
        // so the full window stays under ActivityKit's content-state limit.
        let needsChart = settings.lockScreenView == .detailed || settings.smartStackView == .detailed
        let slots = needsChart
            ? LiveActivityAttributes.chartSlots(from: chart)
            : (start: Date(timeIntervalSince1970: 0), glucose: [Int?]())
        let includeForecasts = needsChart && settings.displayGlucoseForecasts

        let detailedState = LiveActivityAttributes.ContentAdditionalState(
            chartStart: slots.start,
            chartGlucose: slots.glucose,
            rotationDegrees: rotationDegrees,
            cob: Decimal(determination?.cob ?? 0),
            iob: iob ?? 0 as Decimal,
            tdd: determination?.tdd ?? 0 as Decimal,
            isOverrideActive: override?.isActive ?? false,
            overrideName: override?.overrideName ?? "Override",
            overrideDate: override?.date ?? Date(),
            overrideDuration: override?.duration ?? 0,
            overrideTarget: override?.target ?? 0,
            isTempTargetActive: tempTarget?.isActive ?? false,
            tempTargetName: tempTarget?.tempTargetName ?? "Temp Target",
            tempTargetDate: tempTarget?.date ?? Date(),
            tempTargetDuration: tempTarget?.duration ?? 0,
            tempTargetTarget: tempTarget?.target ?? 0,
            widgetItems: widgetItems ?? [], // set empty array here to silence compiler; this can never be nil
            minForecast: includeForecasts && settings.forecastDisplayType == .cone
                ? (determination?.minForecast ?? []) : [],
            maxForecast: includeForecasts && settings.forecastDisplayType == .cone
                ? (determination?.maxForecast ?? []) : [],
            forecastLines: includeForecasts && settings.forecastDisplayType == .lines
                ? (determination?.forecastLines ?? [])
                .map { LiveActivityAttributes.ForecastLine(type: $0.type, values: $0.values) }
                : [],
            forecastDisplayType: settings.forecastDisplayType.rawValue
        )

        self.init(
            unit: settings.units.rawValue,
            bg: formattedBG,
            glucose: Decimal(glucose),
            direction: trendString,
            change: change,
            date: determination?.date ?? nil,
            highGlucose: settings.high,
            lowGlucose: settings.low,
            target: determination?.target ?? 100 as Decimal,
            glucoseColorScheme: settings.glucoseColorScheme.rawValue,
            useDetailedViewIOS: settings.lockScreenView == .detailed,
            useDetailedViewWatchOS: settings.smartStackView == .detailed,
            simpleViewStyle: LiveActivityAttributes.SimpleViewStyle(settings: settings),
            detailedViewState: detailedState,
            isInitialState: false
        )
    }
}
