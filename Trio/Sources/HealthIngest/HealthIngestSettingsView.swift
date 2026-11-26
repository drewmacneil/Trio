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

    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

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
            clearRejections: { uploader.clearRejections() },
            background: appState.trioBackgroundColor(for: colorScheme)
        )
        .onChange(of: uploader.backfillDayChoice) { _, newValue in
            if !uploader.status.backfillRunning {
                backfillDays = newValue
            }
        }
    }

    private var phase: HealthIngestConnectionPhase {
        if testing { return .testing }
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = HealthIngestOrigin.parse(trimmed) != nil
        let revision = uploader.tokenRevision()
        let matches = storedCheck?.url == trimmed
            && storedCheck?.deviceID == deviceID
            && storedCheck?.tokenRevision == revision
        if let check = storedCheck, matches, check.kind == .badURL {
            return .badURL(testedAt: check.testedAt)
        }
        guard parsed, uploader.status.hasToken else { return .notConfigured }
        guard let check = storedCheck, matches else { return .notTested }
        switch check.kind {
        case .connected:
            return .connected(milliseconds: check.latencyMS ?? 0, testedAt: check.testedAt)
        case .timedOut:
            return .timedOut(testedAt: check.testedAt)
        case .tokenRejected:
            return .tokenRejected(testedAt: check.testedAt)
        case .badURL:
            return .badURL(testedAt: check.testedAt)
        case .http:
            return .http(code: check.httpCode ?? 0, testedAt: check.testedAt)
        case .unreachable:
            return .unreachable(testedAt: check.testedAt)
        }
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
    case connected(milliseconds: Int, testedAt: Date)
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
    var background: LinearGradient

    private let backfillChoices = HealthIngestBackfillProgress.dayChoices

    var body: some View {
        Form {
            hero
            serverRow
            NavigationLink {
                HealthIngestSentScreen()
            } label: {
                LabeledContent("What is sent", value: "All data")
            }
            .listRowBackground(Color.chart)
            if enabled {
                NavigationLink {
                    historyScreen
                } label: {
                    LabeledContent("History", value: "\(windowDays) days")
                }
                .listRowBackground(Color.chart)
                NavigationLink {
                    diagnosticsScreen
                } label: {
                    LabeledContent("Diagnostics", value: diagnosticsValue)
                }
                .listRowBackground(Color.chart)
            }
        }
        .scrollContentBackground(.hidden)
        .background(background)
        .navigationTitle("Health Ingest")
        .navigationBarTitleDisplayMode(.automatic)
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
        status.queueDepth == 0 ? "Nothing waiting" : "\(status.queueDepth.formatted()) waiting"
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
                    Toggle("Health Ingest", isOn: enabledBinding)
                        .labelsHidden()
                }
                if enabled, let host = HealthIngestOrigin.host(baseURL) {
                    Text(host)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if enabled, let progress = status.progressCard {
                    progressBlock(progress)
                }
                if enabled, status.showsLastError, let error = status.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding(.vertical, 2)
            .listRowBackground(Color.chart)
            if enabled {
                LabeledContent("Last success") {
                    Text(status.lastSuccess?.formatted(date: .abbreviated, time: .shortened) ?? "None")
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.chart)
            }
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
                    Spacer()
                    connectionBadge
                }
            }
            .listRowBackground(Color.chart)
        }
    }

    @ViewBuilder private var connectionBadge: some View {
        switch phase {
        case .connected:
            Text("Connected")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.green.opacity(0.14), in: Capsule())
        case .notConfigured:
            Text("Not configured")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        default:
            Text("Not tested")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
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
        case HealthIngestStatus.pausedUntilUnlock: return .orange
        case "Error",
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
                Text(
                    "https address. The device id has to match the token, or the server returns 403. Tap Token to paste one in. It stays in the Keychain and is not shown."
                )
            }

            Section {
                connectionStatus
                if let tested = phase.testedAt {
                    LabeledContent("Last tested") {
                        Text(HealthIngestConnectionPhase.stamp(tested))
                            .foregroundStyle(.secondary)
                    }
                    .fullWidthSeparator()
                }
                Button(phase.repeatsTest ? "Test again" : "Test connection", action: testConnection)
                    .disabled(!phase.canTest)
                    .fullWidthSeparator()
            } header: {
                Text("Connection check")
            } footer: {
                Text(
                    phase.canTest
                        ? "Uses the address, device id, and saved token."
                        : "Add an https address and a token before testing."
                )
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
        .scrollContentBackground(.hidden)
        .navigationTitle("Server")
        .navigationBarTitleDisplayMode(.inline)
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
        case let .connected(milliseconds, _):
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Connected")
                Spacer()
                Text("\(milliseconds) ms")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .fullWidthSeparator()
        case .timedOut:
            failureLine(
                symbol: "clock.badge.exclamationmark",
                title: "Timed out",
                detail: "The server did not answer. Check the address and try again.",
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
                detail: "The address has to be https. A port is allowed.",
                tint: .red
            )
        case let .http(code, _):
            failureLine(
                symbol: "exclamationmark.circle.fill",
                title: "The server returned HTTP \(code).",
                detail: "The check did not succeed.",
                tint: .red
            )
        case .unreachable:
            failureLine(
                symbol: "wifi.slash",
                title: "Could not reach the server",
                detail: "Check the address and try again.",
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
        .scrollContentBackground(.hidden)
        .navigationTitle("Token")
        .navigationBarTitleDisplayMode(.inline)
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
        .scrollContentBackground(.hidden)
        .navigationTitle("What is sent")
        .navigationBarTitleDisplayMode(.inline)
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
                    Spacer(minLength: 8)
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.green)
                        .accessibilityLabel("Included")
                }
                .listRowBackground(Color.chart)
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
                    .listRowBackground(Color.chart)
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
                .listRowBackground(Color.chart)
                if running {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Backfilling…")
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.chart)
                } else {
                    Button("Backfill", action: start)
                        .disabled(!enabled)
                        .listRowBackground(Color.chart)
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
        .scrollContentBackground(.hidden)
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
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
                    .listRowBackground(Color.chart)
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
                    .listRowBackground(Color.chart)
                }
            } header: {
                Text("Waiting")
            } footer: {
                Text(
                    widened
                        ?
                        "A striped tail means that slice was drawn wider than its share so the name fits. The solid part is the real proportion."
                        :
                        "Trio leaves the queue before Apple Health. Backfill is the part of Apple Health still being read from history."
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
                    .listRowBackground(Color.chart)
                    Button("Clear", role: .destructive, action: clear)
                        .listRowBackground(Color.chart)
                } footer: {
                    Text("The phone keeps the last 200 rejects. Clear removes them here. The server keeps its own history.")
                }
            }

            Section {
                Button("Reset backfill", role: .destructive, action: reset)
                    .listRowBackground(Color.chart)
            } footer: {
                Text("Forgets upload progress and resends the selected window. Nothing is deleted. The server skips duplicates.")
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
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

extension View {
    func fullWidthSeparator() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            .listRowBackground(Color.chart)
            .alignmentGuide(.listRowSeparatorLeading) { _ in -16 }
            .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
                dimensions[.trailing] + 16
            }
    }
}

extension HealthIngestConnectionPhase {
    static func stamp(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "Today at \(date.formatted(date: .omitted, time: .shortened))"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

struct HealthIngestRejectedView: View {
    var groups: [HealthIngestRejectGroup]
    var onClear: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    var body: some View {
        let types = grouped
        Form {
            if types.isEmpty {
                Section {
                    Text("No rejected records.")
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.chart)
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
                    .listRowBackground(Color.chart)
                }
            }
            Section {
                Button("Clear", role: .destructive, action: onClear)
            } footer: {
                Text("The phone keeps the last 200 rejects. The server keeps the full history.")
            }
            .listRowBackground(Color.chart)
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Rejected")
        .navigationBarTitleDisplayMode(.automatic)
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
