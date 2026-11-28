import SwiftUI
import Swinject
import UIKit

/// Private ingest server settings. Off until the upload switch is turned on.
/// The token is written to the Keychain and is not shown again.
struct HealthIngestSettingsView: View {
    @ObservedObject private var uploader: HealthIngestUploader
    @State private var baseURL: String
    @State private var deviceID: String
    @State private var tokenDraft = ""
    @State private var testing = false
    @State private var backfillDays: Int
    @State private var confirmReset = false
    @State private var confirmRemoveServer = false
    @State private var storedCheck: HealthIngestConnectionCheck?

    init(resolver: Resolver) {
        let uploader = resolver.resolve(HealthIngestUploader.self)!
        _uploader = ObservedObject(wrappedValue: uploader)
        _baseURL = State(initialValue: uploader.preferences.baseURL)
        _deviceID = State(initialValue: uploader.preferences.deviceID)
        _backfillDays = State(initialValue: uploader.backfillDayChoice)
        _storedCheck = State(initialValue: uploader.connectionCheck())
    }

    var body: some View {
        HealthIngestSettingsForm(
            baseURL: $baseURL,
            deviceID: $deviceID,
            tokenDraft: $tokenDraft,
            backfillDays: $backfillDays,
            confirmReset: $confirmReset,
            confirmRemoveServer: $confirmRemoveServer,
            enabled: uploader.preferences.enabled,
            hasToken: uploader.status.hasToken,
            testing: testing,
            phase: phase,
            status: uploader.status,
            setEnabled: { uploader.setEnabled($0, baseURL: baseURL, deviceID: deviceID) },
            saveServer: { uploader.setServer(baseURL: baseURL, deviceID: deviceID) },
            saveToken: saveToken,
            removeToken: {
                uploader.clearToken()
                tokenDraft = ""
            },
            removeServer: removeServer,
            testConnection: runTest,
            startBackfill: { uploader.backfill(days: backfillDays) },
            rememberBackfillDays: { uploader.rememberBackfillDays($0) },
            resetBackfill: {
                let days = uploader.status.backfillRunning ? (uploader.status.backfill?.days ?? backfillDays) : backfillDays
                uploader.resetBackfill(days: days)
            },
            clearRejections: { uploader.clearRejections() }
        )
        .onChange(of: uploader.backfillDayChoice) { _, newValue in
            if !uploader.status.backfillRunning {
                backfillDays = newValue
            }
        }
        .onChange(of: uploader.status.lastSuccess) { _, _ in
            storedCheck = uploader.connectionCheck()
        }
        .onChange(of: uploader.status.lastError) { _, _ in
            storedCheck = uploader.connectionCheck()
        }
    }

    private var phase: HealthIngestConnectionPhase {
        HealthIngestConnectionResolver.phase(
            check: storedCheck,
            url: baseURL,
            deviceID: deviceID,
            hasToken: uploader.status.hasToken,
            tokenRevision: uploader.tokenRevision(),
            testing: testing
        )
    }

    private func saveToken() {
        let draft = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        uploader.setServer(baseURL: baseURL, deviceID: deviceID)
        uploader.setToken(draft)
        tokenDraft = ""
    }

    private func removeServer() {
        baseURL = ""
        deviceID = HealthIngestWire.defaultDeviceID
        tokenDraft = ""
        uploader.setServer(baseURL: "", deviceID: HealthIngestWire.defaultDeviceID)
        uploader.clearToken()
        uploader.clearConnectionCheck()
        storedCheck = nil
    }

    private func runTest() {
        testing = true
        let url = baseURL
        let device = deviceID
        Task {
            let result = await uploader.testConnection(baseURL: url, deviceID: device)
            let revision = uploader.tokenRevision()
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            let check = HealthIngestConnectionCheck(
                url: trimmed,
                deviceID: device,
                tokenRevision: revision,
                testedAt: Date(),
                kind: result.kind,
                latencyMS: result.latencyMS,
                httpCode: result.httpCode
            )
            if result != .missingToken {
                uploader.rememberConnection(check)
                storedCheck = check
            }
            testing = false
        }
    }
}

enum HealthIngestConnectionPhase: Equatable {
    case notConfigured
    case notTested
    case testing
    case connected(milliseconds: Int?, testedAt: Date)
    case timedOut(testedAt: Date)
    case tokenRejected(testedAt: Date)
    case badURL(testedAt: Date)
    case http(code: Int, testedAt: Date)
    case unreachable(testedAt: Date)

    var testedAt: Date? {
        switch self {
        case .notConfigured,
             .notTested,
             .testing:
            return nil
        case let
            .badURL(date),
             let .connected(_, date),
             let
                 .http(_, date),
             let
                 .timedOut(date),
             let
                 .tokenRejected(date),
             let
                 .unreachable(date):
            return date
        }
    }

    var canTest: Bool {
        switch self {
        case .notConfigured,
             .testing: return false
        default: return true
        }
    }

    var repeatsTest: Bool {
        switch self {
        case .badURL,
             .connected,
             .http,
             .timedOut,
             .tokenRejected,
             .unreachable: return true
        default: return false
        }
    }
}

private extension HealthIngestProbe {
    var kind: HealthIngestConnectionCheck.Kind {
        switch self {
        case .badURL: return .badURL
        case .missingToken: return .unreachable
        case .connected: return .connected
        case .tokenRejected: return .tokenRejected
        case .timedOut: return .timedOut
        case .http: return .http
        case .unreachable: return .unreachable
        }
    }

    var latencyMS: Int? {
        if case let .connected(milliseconds) = self { return milliseconds }
        return nil
    }

    var httpCode: Int? {
        if case let .http(code) = self { return code }
        return nil
    }
}

struct HealthIngestSettingsForm: View {
    @Binding var baseURL: String
    @Binding var deviceID: String
    @Binding var tokenDraft: String
    @Binding var backfillDays: Int
    @Binding var confirmReset: Bool
    @Binding var confirmRemoveServer: Bool

    var enabled: Bool
    var hasToken: Bool
    var testing: Bool
    var phase: HealthIngestConnectionPhase
    var status: HealthIngestStatus
    var setEnabled: (Bool) -> Void
    var saveServer: () -> Void
    var saveToken: () -> Void
    var removeToken: () -> Void
    var removeServer: () -> Void
    var testConnection: () -> Void
    var startBackfill: () -> Void
    var rememberBackfillDays: (Int) -> Void
    var resetBackfill: () -> Void
    var clearRejections: () -> Void

    private let backfillChoices = HealthIngestBackfillProgress.dayChoices

    var body: some View {
        Form {
            hero
            serverRow
            if enabled {
                Section {
                    NavigationLink {
                        historyScreen
                    } label: {
                        LabeledContent("History", value: "\(windowDays) days")
                    }
                    NavigationLink {
                        diagnosticsScreen
                    } label: {
                        LabeledContent("Diagnostics", value: diagnosticsValue)
                    }
                } footer: {
                    Text("History reads older samples. Diagnostics shows what is waiting and what was rejected.")
                }
            }
            Section {
                NavigationLink {
                    HealthIngestSentScreen()
                } label: {
                    Text("What's uploaded")
                }
            } footer: {
                HealthIngestWrappingFooter(HealthIngestServerCopy.homeRowsFooter)
            }
        }
        .healthIngestPage(title: "Data Upload", largeTitle: true)
        .alert("Reset backfill?", isPresented: $confirmReset) {
            Button("Reset and resend", role: .destructive) { resetBackfill() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Trio will resend up to \(windowDays) days of Health data from scratch. The current backfill will stop. Nothing is deleted."
            )
        }
        .alert("Remove server?", isPresented: $confirmRemoveServer) {
            Button("Remove", role: .destructive) { removeServer() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The address, device id, and token are removed from this phone. The server is left as it is.")
        }
    }

    private var diagnosticsValue: String {
        if status.rejectedCount > 0 {
            return "\(status.rejectedCount.formatted()) rejected"
        }
        return status.queueDepth == 0 ? "Nothing waiting" : "\(status.queueDepth.formatted()) waiting"
    }

    private var hero: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(heroColor)
                        .frame(width: 10, height: 10)
                    Text(heroTitle)
                    Spacer(minLength: 8)
                    if enabled, status.showsStatusSpinner {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Toggle("Data Upload", isOn: enabledBinding)
                        .labelsHidden()
                }
                if enabled, status.showsProgressPhase, let progress = status.progressCard {
                    progressBlock(progress)
                }
                if enabled {
                    statusDetail
                }
                if enabled, let action = status.cardAction {
                    Text(action)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
        } footer: {
            Text(
                enabled
                    ? "Off by default. The address and token stay on this phone."
                    :
                    "Turn on to start uploading. You can still set the server and test the connection.\n\nOff by default. The address and token stay on this phone."
            )
        }
    }

    private var serverRow: some View {
        Section {
            NavigationLink {
                serverScreen
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Server")
                        Text(HealthIngestOrigin.host(baseURL) ?? "Add a server")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var statusDetail: some View {
        VStack(alignment: .leading, spacing: 2) {
            if status.isPausedUntilUnlock {
                Text("Resumes when iPhone is unlocked")
                    .fixedSize(horizontal: false, vertical: true)
            }
            HealthIngestLastSuccessLine(date: status.lastSuccess)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var serverScreen: some View {
        HealthIngestServerScreen(
            baseURL: $baseURL,
            deviceID: $deviceID,
            tokenDraft: $tokenDraft,
            hasToken: hasToken,
            phase: phase,
            saveServer: saveServer,
            saveToken: saveToken,
            removeToken: removeToken,
            removeServer: { confirmRemoveServer = true },
            testConnection: testConnection,
            showsRemoveServer: hasToken || !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    private var historyScreen: some View {
        HealthIngestHistoryScreen(
            backfillDays: $backfillDays,
            choices: backfillChoices,
            running: status.backfillRunning,
            progress: status.backfill,
            windowDays: windowDays,
            enabled: enabled,
            remember: rememberBackfillDays,
            start: startBackfill
        )
    }

    private var diagnosticsScreen: some View {
        HealthIngestDiagnosticsScreen(
            status: status,
            reset: { confirmReset = true },
            clear: clearRejections
        )
    }

    private func progressBlock(_ progress: HealthIngestBackfillProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if status.showsProgressPhase {
                Text(progress.phase)
            }
            ProgressView(value: progress.fraction)
            HStack {
                Text("Day \(progress.day) of \(progress.days)")
                Spacer()
                if let line = status.rowsSentLine {
                    Text(line)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var windowDays: Int {
        if status.backfillRunning, let days = status.backfill?.days {
            return days
        }
        return backfillDays
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { enabled }, set: { setEnabled($0) })
    }

    private var heroTitle: String {
        enabled ? status.stateTitle : "Off"
    }

    private var heroColor: Color {
        guard enabled else { return Color.secondary.opacity(0.45) }
        switch status.stateTitle {
        case "Backfilling",
             HealthIngestStatus.rewritingTitle: return .blue
        case HealthIngestStatus.pausedTitle: return .orange
        case HealthIngestStatus.cantReachTitle,
             HealthIngestStatus.serverErrorTitle,
             HealthIngestStatus.readFailedTitle,
             HealthIngestStatus.queueOpenTitle,
             HealthIngestStatus.encodeTitle,
             HealthIngestStatus.oversizedTitle,
             HealthIngestStatus.deviceIdRejectedTitle,
             HealthIngestStatus.tokenRejectedTitle:
            return .red
        default: return .green
        }
    }
}

struct HealthIngestServerScreen: View {
    @Binding var baseURL: String
    @Binding var deviceID: String
    @Binding var tokenDraft: String
    var hasToken: Bool
    var phase: HealthIngestConnectionPhase
    var saveServer: () -> Void
    var saveToken: () -> Void
    var removeToken: () -> Void
    var removeServer: () -> Void
    var testConnection: () -> Void
    var showsRemoveServer: Bool

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("URL")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField(
                        "",
                        text: $baseURL,
                        prompt: Text("https://server.example:8443").foregroundStyle(.tertiary)
                    )
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .onSubmit { saveServer() }
                }
                .fullWidthSeparator()
                LabeledContent("Device") {
                    TextField("trio-iphone", text: $deviceID)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { saveServer() }
                }
                .fullWidthSeparator()
                NavigationLink {
                    HealthIngestTokenScreen(
                        tokenDraft: $tokenDraft,
                        hasToken: hasToken,
                        save: saveToken
                    )
                } label: {
                    HStack {
                        Text("Token")
                        Spacer()
                        Text(hasToken ? "••••••••" : "None")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(hasToken ? "Saved in Keychain" : "No token")
                    }
                }
                .fullWidthSeparator()
            } header: {
                Text("Server")
            } footer: {
                HealthIngestWrappingFooter(HealthIngestServerCopy.inputsFooter(hasToken: hasToken, phase: phase))
            }

            Section {
                connectionStatus
                Button(phase.repeatsTest ? "Test again" : "Test connection", action: testConnection)
                    .disabled(!phase.canTest)
                    .fullWidthSeparator()
            } header: {
                Text("Connection check")
            } footer: {
                HealthIngestWrappingFooter(HealthIngestServerCopy.connectionFooter(phase: phase))
            }

            if showsRemoveServer || hasToken {
                Section {
                    if hasToken {
                        Button("Remove token", role: .destructive, action: removeToken)
                            .fullWidthSeparator()
                    }
                    if showsRemoveServer {
                        Button("Remove server", role: .destructive, action: removeServer)
                            .fullWidthSeparator()
                    }
                } footer: {
                    Text(
                        "Remove token deletes the Keychain item. Remove server also clears the address and device id on this phone. The server is left as it is."
                    )
                }
            }
        }
        .healthIngestPage(title: "Server")
    }

    @ViewBuilder private var connectionStatus: some View {
        switch phase {
        case .notConfigured:
            statusLine(symbol: "circle.dashed", title: "Not configured", tint: Color(uiColor: .tertiaryLabel))
        case .notTested:
            statusLine(symbol: "questionmark.circle", title: "Not tested", tint: .secondary)
        case .testing:
            HStack(spacing: 10) {
                ProgressView()
                Text("Testing…")
            }
            .fullWidthSeparator()
        case let .connected(milliseconds, testedAt):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connected")
                    Text(testedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let milliseconds {
                    Text("\(milliseconds) ms")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .fullWidthSeparator()
        case .timedOut:
            failureLine(
                symbol: "clock.badge.exclamationmark",
                title: HealthIngestStatus.cantReachTitle,
                detail: "Still failing after a retry.",
                tint: .orange
            )
        case .tokenRejected:
            failureLine(
                symbol: "xmark.circle.fill",
                title: "Token rejected",
                detail: HealthIngestStatus.tokenRejectedError,
                tint: .red
            )
        case .badURL:
            failureLine(
                symbol: "exclamationmark.circle.fill",
                title: "Enter an https URL.",
                detail: HealthIngestServerCopy.badURLDetail(address: baseURL),
                tint: .red
            )
        case let .http(code, _):
            failureLine(
                symbol: "exclamationmark.circle.fill",
                title: code == 403 ? HealthIngestStatus.deviceIdRejectedTitle : HealthIngestStatus.serverErrorTitle,
                detail: code == 403
                    ? HealthIngestStatus.deviceIdRejectedError
                    : "The server returned HTTP \(code).",
                tint: .red
            )
        case .unreachable:
            failureLine(
                symbol: "wifi.slash",
                title: HealthIngestStatus.cantReachTitle,
                detail: "Still failing after a retry.",
                tint: .red
            )
        }
    }

    private func statusLine(symbol: String, title: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(title)
            Spacer(minLength: 0)
        }
        .fullWidthSeparator()
    }

    private func failureLine(symbol: String, title: String, detail: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(tint)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .fullWidthSeparator()
    }
}

struct HealthIngestTokenScreen: View {
    @Binding var tokenDraft: String
    var hasToken: Bool
    var save: () -> Void

    private var draftIsEmpty: Bool {
        tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            if hasToken {
                Section {
                    LabeledContent("Saved") {
                        Text("••••••••")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Saved in Keychain")
                    }
                    .fullWidthSeparator()
                } footer: {
                    Text("This is the token in the Keychain. It is not shown.")
                }
            }
            Section {
                SecureField(hasToken ? "New token" : "Bearer token", text: $tokenDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.password)
                    .fullWidthSeparator()
            } header: {
                Text(hasToken ? "Replacement" : "Token")
            } footer: {
                Text("Tap and hold the field to paste. Save stores it in the Keychain, and it is not shown again.")
            }
            Section {
                Button(action: save) {
                    Text("Save")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(draftIsEmpty)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
        }
        .healthIngestPage(title: "Token")
    }
}

struct HealthIngestSentScreen: View {
    var body: some View {
        Form {
            sentSection(
                "Trio",
                kinds: HealthIngestSentKind.trio,
                footer: "Loop cycles include statistics, the effective profile, and time zone changes."
            )
            sentSection(
                "Apple Health",
                kinds: HealthIngestSentKind.health,
                footer: "Upload on sends every category. There is no per-type switch."
            )
        }
        .healthIngestPage(title: "What's uploaded")
    }

    private func sentSection(_ title: String, kinds: [HealthIngestSentKind], footer: String) -> some View {
        Section {
            ForEach(kinds) { kind in
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: kind.symbol)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(kind.tint)
                        .frame(width: 32, height: 32)
                        .background(kind.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.title)
                        Text(kind.subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
    }
}

struct HealthIngestHistoryScreen: View {
    @Binding var backfillDays: Int
    var choices: [Int]
    var running: Bool
    var progress: HealthIngestBackfillProgress?
    var windowDays: Int
    var enabled: Bool
    var remember: (Int) -> Void
    var start: () -> Void

    var body: some View {
        Form {
            if running, let progress {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Circle().fill(Color.blue).frame(width: 10, height: 10)
                            Text("Backfilling")
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                        Text(progress.phase)
                        ProgressView(value: progress.fraction)
                        HStack {
                            Text("Day \(progress.day) of \(progress.days)")
                            Spacer()
                            Text("\(progress.rowsSent.formatted()) rows sent")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("This pass")
                }
            }
            Section {
                Picker("Days", selection: daysSelection) {
                    ForEach(choices, id: \.self) { days in
                        Text("\(days)").tag(days)
                    }
                }
                .pickerStyle(.menu)
                .disabled(running)
                if running {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Backfilling…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button("Backfill", action: start)
                        .disabled(!enabled)
                }
            } header: {
                Text("Window")
            } footer: {
                Text(
                    running
                        ?
                        "Glucose, insulin, carbs, and loop results stay on the phone for about 90 days. The first Health sync is the last day. History reads older Health samples. The day count stays locked until this pass finishes."
                        :
                        "Glucose, insulin, carbs, and loop results stay on the phone for about 90 days. Overrides and prediction curves are kept for less time, so leave upload on to catch them. The first Health sync is the last day. History reads older Health samples."
                )
            }
        }
        .healthIngestPage(title: "History")
    }

    private var daysSelection: Binding<Int> {
        Binding(
            get: { running ? windowDays : backfillDays },
            set: { newValue in
                if !running {
                    backfillDays = newValue
                    remember(newValue)
                }
            }
        )
    }
}

private struct HealthIngestStripeKey: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

struct HealthIngestDiagnosticsScreen: View {
    var status: HealthIngestStatus
    var reset: () -> Void
    var clear: () -> Void
    @State private var widened = false

    var body: some View {
        let parts = queueParts
        Form {
            Section {
                if status.queueDepth == 0 {
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("Nothing waiting")
                            .font(.title3.weight(.semibold))
                        Text("The queue is clear.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(status.queueDepth.formatted())
                                .font(.system(size: 48, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text("Waiting to upload")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        HealthIngestQueueLegend(parts: parts)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Waiting")
            } footer: {
                HealthIngestWrappingFooter(
                    HealthIngestServerCopy.waitingFooter(empty: status.queueDepth == 0, widened: widened)
                )
            }

            if status.rejectedCount > 0 {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title3)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(status.rejectedCount.formatted()) rejected")
                                .font(.body.weight(.semibold))
                            if let reason = status.latestRejectReason {
                                Text("Most recent · \(reason)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    ForEach(status.rejectGroups) { group in
                        HStack {
                            Text(group.reason)
                            Spacer()
                            Text(group.count.formatted())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Clear", role: .destructive, action: clear)
                } footer: {
                    HealthIngestWrappingFooter(
                        "The phone keeps the last 200 rejects. Clear removes them here. The server keeps its own history."
                    )
                }
            }

            Section {
                Button("Reset backfill", role: .destructive, action: reset)
            } footer: {
                Text("Forgets upload progress and resends the selected window. Nothing is deleted. The server skips duplicates.")
            }
        }
        .healthIngestPage(title: "Diagnostics")
        .onPreferenceChange(HealthIngestStripeKey.self) { widened = $0 }
    }

    private var queueParts: [HealthIngestQueuePart] {
        [
            HealthIngestQueuePart(name: "Trio", count: status.priorityDepth, color: .blue),
            HealthIngestQueuePart(name: "Apple Health", count: status.healthLiveDepth, color: .pink),
            HealthIngestQueuePart(name: "Backfill", count: status.backfillDepth, color: .indigo)
        ].filter { $0.count > 0 }
    }
}

struct HealthIngestQueuePart: Identifiable {
    var name: String
    var count: Int
    var color: Color
    var id: String { name }
}

struct HealthIngestQueueSlice {
    var part: HealthIngestQueuePart
    var display: CGFloat
    var solid: CGFloat
}

enum HealthIngestQueueLegendLayout {
    static let gap: CGFloat = 3

    static func labelWidth(_ part: HealthIngestQueuePart) -> CGFloat {
        let nameFont = UIFont.preferredFont(forTextStyle: .caption2)
        let countFont = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let name = (part.name as NSString).size(withAttributes: [.font: nameFont]).width
        let count = ("\(part.count)" as NSString).size(withAttributes: [.font: countFont]).width
        return ceil(max(name, count)) + 14
    }

    static func layout(_ parts: [HealthIngestQueuePart], width: CGFloat) -> [HealthIngestQueueSlice] {
        guard !parts.isEmpty else { return [] }
        let usable = max(width - gap * CGFloat(parts.count - 1), 1)
        let total = CGFloat(max(parts.reduce(0) { $0 + $1.count }, 1))
        let minimums = parts.map { labelWidth($0) }
        let fair = parts.map { usable * CGFloat($0.count) / total }
        var display = fair
        for _ in 0 ..< 6 {
            for index in display.indices where display[index] < minimums[index] {
                display[index] = minimums[index]
            }
            let overflow = display.reduce(0, +) - usable
            guard overflow > 0.5 else { break }
            let slack = display.indices.map { max(0, display[$0] - minimums[$0]) }
            let slackSum = slack.reduce(0, +)
            guard slackSum > 0 else { break }
            for index in display.indices {
                display[index] -= overflow * slack[index] / slackSum
            }
        }
        return zip(parts.indices, parts).map { index, part in
            HealthIngestQueueSlice(part: part, display: display[index], solid: min(display[index], fair[index]))
        }
    }
}

struct HealthIngestQueueLegend: View {
    var parts: [HealthIngestQueuePart]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let slices = HealthIngestQueueLegendLayout.layout(parts, width: geo.size.width)
                let stripe = slices.contains { $0.display - $0.solid > 8 }
                HStack(spacing: HealthIngestQueueLegendLayout.gap) {
                    ForEach(Array(slices.enumerated()), id: \.offset) { _, slice in
                        HealthIngestProportionSegment(slice: slice)
                    }
                }
                .preference(key: HealthIngestStripeKey.self, value: stripe)
            }
            .frame(height: 10)
            GeometryReader { geo in
                let slices = HealthIngestQueueLegendLayout.layout(parts, width: geo.size.width)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(slices.enumerated()), id: \.offset) { index, slice in
                        let start = slices.prefix(index).reduce(CGFloat(0)) { $0 + $1.display }
                            + HealthIngestQueueLegendLayout.gap * CGFloat(index)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(slice.part.name)
                                .font(.caption2)
                                .foregroundStyle(slice.part.color)
                                .lineLimit(1)
                            Text(slice.part.count.formatted())
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                        }
                        .frame(width: max(slice.display, 1), alignment: .leading)
                        .offset(x: start)
                    }
                }
            }
            .frame(height: 30)
        }
    }
}

private struct HealthIngestProportionSegment: View {
    var slice: HealthIngestQueueSlice

    var body: some View {
        let widened = slice.display - slice.solid > 8
        let solidWidth = widened ? min(max(slice.solid, 4), slice.display - 6) : slice.display
        HStack(spacing: 0) {
            Rectangle()
                .fill(slice.part.color)
                .frame(width: solidWidth)
            if widened {
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 1.5)
                HealthIngestStripeFill(color: slice.part.color)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(width: slice.display, height: 10)
        .clipShape(Capsule())
    }
}

private struct HealthIngestStripeFill: View {
    var color: Color

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(0.22)))
            var path = Path()
            let step: CGFloat = 4
            var x = -size.height
            while x < size.width + size.height {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += step
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.2))
        }
    }
}

private struct HealthIngestSentKind: Identifiable {
    var title: String
    var subtitle: String
    var symbol: String
    var tint: Color
    var id: String { title }

    static let trio: [HealthIngestSentKind] = [
        .init(
            title: "Glucose",
            subtitle: "Readings and CGM status",
            symbol: "drop.fill",
            tint: Color(red: 0.85, green: 0.22, blue: 0.28)
        ),
        .init(
            title: "Boluses, SMBs, and temp basals",
            subtitle: "Boluses, SMBs, temp basals, and failures",
            symbol: "syringe.fill",
            tint: Color(red: 0.12, green: 0.45, blue: 0.95)
        ),
        .init(title: "Carbs", subtitle: "Meal entries", symbol: "fork.knife", tint: Color(red: 0.95, green: 0.55, blue: 0.15)),
        .init(
            title: "Overrides and temp targets",
            subtitle: "Overrides and temporary targets",
            symbol: "target",
            tint: Color(red: 0.55, green: 0.35, blue: 0.85)
        ),
        .init(
            title: "Pump events",
            subtitle: "Site changes, alarms, and reservoir events",
            symbol: "gauge.with.dots.needle.67percent",
            tint: Color(red: 0.20, green: 0.55, blue: 0.65)
        ),
        .init(
            title: "Profiles and settings",
            subtitle: "Snapshots, switches, and deletions",
            symbol: "slider.horizontal.3",
            tint: Color(red: 0.35, green: 0.40, blue: 0.50)
        ),
        .init(
            title: "Loop cycles",
            subtitle: "Cycles, statistics, effective profile, time zone",
            symbol: "arrow.triangle.2.circlepath",
            tint: Color(red: 0.15, green: 0.55, blue: 0.40)
        )
    ]

    static let health: [HealthIngestSentKind] = [
        .init(
            title: "Workouts",
            subtitle: "Workout sessions",
            symbol: "figure.run",
            tint: Color(red: 0.15, green: 0.60, blue: 0.35)
        ),
        .init(
            title: "Heart rate, resting heart rate, and HRV",
            subtitle: "Heart rate, resting heart rate, and HRV",
            symbol: "heart.fill",
            tint: Color(red: 0.90, green: 0.25, blue: 0.35)
        ),
        .init(
            title: "Sleep",
            subtitle: "Sleep stages",
            symbol: "bed.double.fill",
            tint: Color(red: 0.35, green: 0.35, blue: 0.75)
        ),
        .init(
            title: "Active energy and exercise minutes",
            subtitle: "Active energy and exercise minutes",
            symbol: "flame.fill",
            tint: Color(red: 0.90, green: 0.40, blue: 0.15)
        )
    ]
}

enum HealthIngestServerCopy {
    static let homeRowsFooter = "Upload on sends every category. There is no per-type switch."
    static let stripeFooter =
        "A striped tail means that slice was drawn wider than its share so the name fits. The solid part is the real proportion."
    static let emptyQueueFooter = "Trio data uploads first when something is queued."
    static let queueOrderFooter =
        "Trio leaves the queue before Apple Health. Backfill is the part of Apple Health still being read from history."

    static func inputsFooter(hasToken: Bool, phase: HealthIngestConnectionPhase) -> String {
        switch phase {
        case .notConfigured, .notTested, .testing:
            if hasToken {
                return "Tap Token to paste a replacement. The saved token stays in the Keychain and is not shown."
            }
            return "Tap Token to paste one in. It stays in the Keychain and is not shown."
        default:
            return "https address. The device id has to match the token, or the server returns 403. The token stays in the Keychain."
        }
    }

    static func connectionFooter(phase: HealthIngestConnectionPhase) -> String {
        switch phase {
        case .notConfigured:
            return "Add an https address and a token before testing."
        case .timedOut:
            return "Nothing was changed. Try again when the server can be reached."
        case .tokenRejected:
            return "The device id has to be the one in the token."
        case .badURL:
            return "The address has to be https. A port is allowed."
        default:
            return "Uses the address, device id, and saved token."
        }
    }

    static func badURLDetail(address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = trimmed.isEmpty ? "That address" : trimmed
        return "\(shown) is not an https address."
    }

    static func waitingFooter(empty: Bool, widened: Bool) -> String {
        if empty { return emptyQueueFooter }
        if widened { return stripeFooter }
        return queueOrderFooter
    }
}

/// One line when it fits. Otherwise "Last success" and the time are each their own line,
/// and the time uses non-breaking spaces so "min ago" cannot sit alone.
struct HealthIngestLastSuccessLine: View {
    var date: Date?
    var now: Date = Date()

    var body: some View {
        if let date {
            let time = HealthIngestStatus.relativeSuccess(from: date, now: now)
                .replacingOccurrences(of: " ", with: "\u{00a0}")
            ViewThatFits(in: .horizontal) {
                Text("Last success · \(time)")
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Last success")
                    Text(time)
                }
            }
        } else {
            Text("No successful upload yet")
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct HealthIngestWrappingFooter: View {
    var text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// System grouped page and inset cells, the same chrome as the approved mocks.
    func healthIngestPage(title: String, largeTitle: Bool = false) -> some View {
        scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .listStyle(.insetGrouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(largeTitle ? .large : .inline)
    }

    func fullWidthSeparator() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            .alignmentGuide(.listRowSeparatorLeading) { _ in -16 }
            .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
                dimensions[.trailing] + 16
            }
    }
}

struct HealthIngestRejectedView: View {
    var groups: [HealthIngestRejectGroup]
    var onClear: () -> Void

    var body: some View {
        let types = grouped
        Form {
            if types.isEmpty {
                Section {
                    Text("No rejected records.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(types, id: \.type) { bucket in
                    Section {
                        ForEach(bucket.rows) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(row.reason)
                                    Spacer()
                                    Text(row.count.formatted())
                                        .foregroundColor(.secondary)
                                }
                                if row.message != row.reason {
                                    Text(row.message)
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                }
                                Text(Self.seen(row.lastSeen))
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                    } header: {
                        Text(HealthIngestType.displayName(bucket.type))
                    }
                }
            }
            Section {
                Button("Clear", role: .destructive, action: onClear)
            } footer: {
                Text("The phone keeps the last 200 rejects. The server keeps the full history.")
            }
        }
        .healthIngestPage(title: "Rejected", largeTitle: true)
    }

    private var grouped: [(type: String, rows: [HealthIngestRejectGroup])] {
        var order: [String] = []
        var buckets: [String: [HealthIngestRejectGroup]] = [:]
        for group in groups {
            if buckets[group.type] == nil { order.append(group.type) }
            buckets[group.type, default: []].append(group)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    private static func seen(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "Today at \(date.formatted(date: .omitted, time: .shortened))"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

extension HealthIngestOrigin {
    static func host(_ baseURL: String) -> String? {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty
        else { return nil }
        return host
    }
}
