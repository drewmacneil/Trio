import ActivityKit
import Foundation

struct LiveActivityAttributes: ActivityAttributes {
    enum LiveActivityItem: String, Hashable, Codable, Equatable {
        case currentGlucoseLarge
        case currentGlucoseLargeUncolored
        case currentGlucose
        case currentGlucoseColored
        case currentGlucoseWide
        case currentGlucoseWideUncolored
        case iob
        case cob
        case updatedLabel
        case totalDailyDose
        case empty
        case wideContinuation

        static let defaultItems: [Self] = [.currentGlucoseLarge, .iob, .cob, .updatedLabel]
    }

    struct SimpleViewStyle: Codable, Hashable {
        let fontSize: LiveActivityFontSize

        static let `default` = SimpleViewStyle(fontSize: .large)
    }

    struct ContentState: Codable, Hashable {
        let unit: String
        let bg: String
        /// Latest glucose reading in mg/dL; nil when no reading is shown.
        let glucose: Decimal?
        let direction: String?
        let change: String
        let date: Date?
        let highGlucose: Decimal
        let lowGlucose: Decimal
        let target: Decimal
        let glucoseColorScheme: String
        let useDetailedViewIOS: Bool
        let useDetailedViewWatchOS: Bool
        let simpleViewStyle: SimpleViewStyle
        let detailedViewState: ContentAdditionalState

        /// true for the first state that is set on the activity
        let isInitialState: Bool
    }

    /// Five-minute chart. Slot 0 is `chartStart`; slot i is that date plus i × 300 seconds.
    static let chartStride: TimeInterval = 300
    static let chartSlotCount = 72

    struct ChartReading: Hashable {
        var date: Date
        var value: Int
    }

    struct ContentAdditionalState: Codable, Hashable {
        /// Time of glucose slot 0. Unix epoch when no chart is sent.
        let chartStart: Date
        /// mg/dL for each 5-minute slot. Nil is a missed reading.
        let chartGlucose: [Int?]
        let rotationDegrees: Double
        let cob: Decimal
        let iob: Decimal
        let tdd: Decimal
        let isOverrideActive: Bool
        let overrideName: String
        let overrideDate: Date
        let overrideDuration: Decimal
        let overrideTarget: Decimal
        let isTempTargetActive: Bool
        let tempTargetName: String
        let tempTargetDate: Date
        let tempTargetDuration: Decimal
        let tempTargetTarget: Decimal
        let widgetItems: [LiveActivityItem]
        let minForecast: [Int]
        let maxForecast: [Int]
        let forecastLines: [ForecastLine]
        let forecastDisplayType: String

        func chartReadings() -> [ChartReading] {
            chartGlucose.enumerated().compactMap { index, mgdl in
                guard let mgdl else { return nil }
                let date = chartStart.addingTimeInterval(TimeInterval(index) * LiveActivityAttributes.chartStride)
                return ChartReading(date: date, value: mgdl)
            }
        }
    }

    struct ForecastLine: Codable, Hashable {
        let type: String
        let values: [Int]
    }

    let startDate: Date
}
