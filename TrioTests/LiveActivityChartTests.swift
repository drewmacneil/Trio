import Foundation
import Testing

@testable import Trio

@Suite("Live Activity chart") struct LiveActivityChartTests {
    @Test func worstCaseContentStateStaysUnderThirtyFiveHundredBytes() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000.123456)
        let longName = String(repeating: "OverrideName", count: 4)
        let lines = ["iob", "cob", "uam", "zt"].map {
            LiveActivityAttributes.ForecastLine(type: $0, values: Array(repeating: 400, count: 24))
        }
        let state = LiveActivityAttributes.ContentState(
            unit: "mg/dL",
            bg: "400",
            glucose: 400,
            direction: "↑↑↑",
            change: "+99",
            date: now,
            highGlucose: 180,
            lowGlucose: 70,
            target: 100,
            glucoseColorScheme: "dynamicColor",
            useDetailedViewIOS: true,
            useDetailedViewWatchOS: true,
            simpleViewStyle: LiveActivityAttributes.SimpleViewStyle(fontSize: .extraLarge),
            detailedViewState: LiveActivityAttributes.ContentAdditionalState(
                chartStart: now.addingTimeInterval(-71 * LiveActivityAttributes.chartStride),
                chartGlucose: Array(repeating: 400 as Int?, count: LiveActivityAttributes.chartSlotCount),
                rotationDegrees: -90,
                cob: 999,
                iob: Decimal(string: "25.55")!,
                tdd: Decimal(string: "180.75")!,
                isOverrideActive: true,
                overrideName: longName,
                overrideDate: now,
                overrideDuration: 1440,
                overrideTarget: 180,
                isTempTargetActive: true,
                tempTargetName: longName,
                tempTargetDate: now,
                tempTargetDuration: 1440,
                tempTargetTarget: 180,
                widgetItems: [
                    .currentGlucoseWideUncolored,
                    .wideContinuation,
                    .currentGlucoseLargeUncolored,
                    .currentGlucoseLarge
                ],
                minForecast: [],
                maxForecast: [],
                forecastLines: lines,
                forecastDisplayType: "lines"
            ),
            isInitialState: false
        )
        let encoded = try JSONEncoder().encode(state)
        print("worst-case ContentState bytes: \(encoded.count)")
        #expect(encoded.count < 3_500)
        #expect(state.detailedViewState.chartGlucose.count == 72)
    }

    @Test func slotDatesSurviveAGapAndARoundTrip() throws {
        let stride = LiveActivityAttributes.chartStride
        let newest = Date(timeIntervalSince1970: 1_700_000_100)
        let missing = newest.addingTimeInterval(-stride)
        let older = newest.addingTimeInterval(-2 * stride)
        let outside = newest.addingTimeInterval(-80 * stride)
        let readings = [
            GlucoseData(glucose: 180, date: newest, direction: nil),
            GlucoseData(glucose: 181, date: newest.addingTimeInterval(30), direction: nil),
            GlucoseData(glucose: 150, date: older, direction: nil),
            GlucoseData(glucose: 90, date: outside, direction: nil)
        ]
        let slots = LiveActivityAttributes.chartSlots(from: readings)
        #expect(slots.glucose.count == 72)
        #expect(slots.glucose[71] == 181)
        #expect(slots.glucose[70] == nil)
        #expect(slots.glucose[69] == 150)
        #expect(!slots.glucose.contains(90))

        let state = contentState(start: slots.start, glucose: slots.glucose, now: newest)
        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(LiveActivityAttributes.ContentState.self, from: encoded)
        let back = decoded.detailedViewState.chartReadings()
        #expect(back.first { $0.value == 181 }?.date == newest)
        #expect(back.first { $0.value == 150 }?.date == older)
        #expect(back.contains { $0.date == missing } == false)
    }

    private func contentState(
        start: Date,
        glucose: [Int?],
        now: Date
    ) -> LiveActivityAttributes.ContentState {
        LiveActivityAttributes.ContentState(
            unit: "mg/dL",
            bg: "180",
            glucose: 180,
            direction: "→",
            change: "+0",
            date: now,
            highGlucose: 180,
            lowGlucose: 70,
            target: 100,
            glucoseColorScheme: "staticColor",
            useDetailedViewIOS: true,
            useDetailedViewWatchOS: false,
            simpleViewStyle: .default,
            detailedViewState: LiveActivityAttributes.ContentAdditionalState(
                chartStart: start,
                chartGlucose: glucose,
                rotationDegrees: 0,
                cob: 0,
                iob: 0,
                tdd: 0,
                isOverrideActive: false,
                overrideName: "Override",
                overrideDate: now,
                overrideDuration: 0,
                overrideTarget: 0,
                isTempTargetActive: false,
                tempTargetName: "Temp Target",
                tempTargetDate: now,
                tempTargetDuration: 0,
                tempTargetTarget: 0,
                widgetItems: [],
                minForecast: [],
                maxForecast: [],
                forecastLines: [],
                forecastDisplayType: "cone"
            ),
            isInitialState: false
        )
    }
}
