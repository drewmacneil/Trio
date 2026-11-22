import SwiftUI
import Swinject

/// Private ingest server settings. Off until the upload switch is turned on.
/// The token is written to the Keychain and is not shown again.
struct HealthIngestSettingsView: View {
    @ObservedObject private var uploader: HealthIngestUploader
    @State private var baseURL: String
    @State private var deviceID: String
    @State private var tokenDraft = ""
    @State private var testResult: String?
    @State private var testing = false
    @State private var backfillDays = 7
    @State private var confirmReset = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    private let backfillChoices = [1, 3, 7, 14, 30, 90]

    init(resolver: Resolver) {
        let uploader = resolver.resolve(HealthIngestUploader.self)!
        _uploader = ObservedObject(wrappedValue: uploader)
        _baseURL = State(initialValue: uploader.preferences.baseURL)
        _deviceID = State(initialValue: uploader.preferences.deviceID)
    }

    var body: some View {
        HealthIngestSettingsForm(
            baseURL: $baseURL,
            deviceID: $deviceID,
            tokenDraft: $tokenDraft,
            backfillDays: $backfillDays,
            confirmReset: $confirmReset,
            enabled: uploader.preferences.enabled,
            hasToken: uploader.status.hasToken,
            testing: testing,
            testResult: testResult,
            status: uploader.status,
            categoryOn: { uploader.preferences.isOn($0) },
            setEnabled: { uploader.setEnabled($0, baseURL: baseURL, deviceID: deviceID) },
            setCategory: { uploader.setCategory($0, enabled: $1) },
            saveServer: { uploader.setServer(baseURL: baseURL, deviceID: deviceID) },
            saveToken: saveToken,
            removeToken: {
                uploader.clearToken()
                tokenDraft = ""
            },
            testConnection: runTest,
            startBackfill: { uploader.backfill(days: backfillDays) },
            resetBackfill: { uploader.resetBackfill(days: backfillDays) },
            clearRejections: { uploader.clearRejections() },
            background: appState.trioBackgroundColor(for: colorScheme)
        )
    }

    private func saveToken() {
        uploader.setServer(baseURL: baseURL, deviceID: deviceID)
        uploader.setToken(tokenDraft)
        tokenDraft = ""
    }

    private func runTest() {
        testing = true
        testResult = nil
        let url = baseURL
        let device = deviceID
        Task {
            let result = await uploader.testConnection(baseURL: url, deviceID: device)
            testResult = result
            testing = false
        }
    }
}

struct HealthIngestSettingsForm: View {
    @Binding var baseURL: String
    @Binding var deviceID: String
    @Binding var tokenDraft: String
    @Binding var backfillDays: Int
    @Binding var confirmReset: Bool

    var enabled: Bool
    var hasToken: Bool
    var testing: Bool
    var testResult: String?
    var status: HealthIngestStatus
    var categoryOn: (HealthIngestCategory) -> Bool
    var setEnabled: (Bool) -> Void
    var setCategory: (HealthIngestCategory, Bool) -> Void
    var saveServer: () -> Void
    var saveToken: () -> Void
    var removeToken: () -> Void
    var testConnection: () -> Void
    var startBackfill: () -> Void
    var resetBackfill: () -> Void
    var clearRejections: () -> Void
    var background: LinearGradient

    private let backfillChoices = [1, 3, 7, 14, 30, 90]

    var body: some View {
        Form {
            headerSection
            serverSection
            if enabled {
                statusSection
                dataSection
                backfillSection
                troubleshootingSection
            }
        }
        .scrollContentBackground(.hidden)
        .background(background)
        .navigationTitle("Health Ingest")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Reset backfill?", isPresented: $confirmReset) {
            Button("Reset and resend", role: .destructive) { resetBackfill() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Trio will resend up to \(backfillDays) days of Health data from scratch. The current backfill will stop. Nothing is deleted."
            )
        }
    }

    private var headerSection: some View {
        Section {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(enabled ? Color.green : Color.secondary.opacity(0.45))
                            .frame(width: 10, height: 10)
                        Text("Private server upload")
                            .font(.headline)
                    }
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("Private server upload", isOn: enabledBinding)
                    .labelsHidden()
            }
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if !enabled {
                    Text("Turn on to start uploading. You can still set the server and test the connection.")
                }
                Text("Off by default. The address and token stay on this phone.")
            }
        }
        .listRowBackground(Color.chart)
    }

    private var serverSection: some View {
        Section {
            TextField("https://server.example:8443", text: $baseURL)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .onSubmit { saveServer() }
            TextField("trio-iphone", text: $deviceID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { saveServer() }
            SecureField(hasToken ? "Token saved in Keychain" : "Bearer token", text: $tokenDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save token", action: saveToken)
                .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(testing ? "Testing…" : "Test connection", action: testConnection)
                .disabled(testing)
            if let testResult {
                connectionResult(testResult)
            }
            if hasToken {
                Button("Remove token", role: .destructive, action: removeToken)
            }
        } header: {
            Text("Server")
        } footer: {
            Text(
                "https origin. A port such as 8443 is allowed. Device id must match the token, or the server returns 403. The token is stored in the Keychain."
            )
        }
        .listRowBackground(Color.chart)
    }

    private var statusSection: some View {
        Section {
            stateRow
            if status.backfillRunning, let progress = status.backfill {
                VStack(alignment: .leading, spacing: 6) {
                    Text(progress.phase)
                    Text("Day \(progress.day) of \(progress.days)")
                        .foregroundStyle(.secondary)
                    ProgressView(value: progress.fraction)
                    Text("\(progress.rowsSent.formatted()) rows sent")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            labeledRow("Last success", status.lastSuccess?.formatted(date: .abbreviated, time: .shortened) ?? "None")
            VStack(alignment: .leading, spacing: 2) {
                labeledRow("Queue", status.queueDepth.formatted())
                Text("Rows waiting to upload.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            NavigationLink {
                HealthIngestRejectedView(groups: status.rejectGroups, onClear: clearRejections)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Rejected")
                        Spacer()
                        Text(status.rejectedCount.formatted())
                            .foregroundStyle(.secondary)
                    }
                    if let reason = status.latestRejectReason, status.rejectedCount > 0 {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        } header: {
            Text("Status")
        }
        .listRowBackground(Color.chart)
    }

    private var dataSection: some View {
        Section {
            ForEach(HealthIngestCategory.allCases) { category in
                Toggle(category.title, isOn: Binding(
                    get: { categoryOn(category) },
                    set: { setCategory(category, $0) }
                ))
            }
        } header: {
            Text("Data")
        } footer: {
            Text("Each category is included once upload is on. Turn one off to leave it on the phone.")
        }
        .listRowBackground(Color.chart)
    }

    private var backfillSection: some View {
        Section {
            Picker("Days", selection: $backfillDays) {
                ForEach(backfillChoices, id: \.self) { days in
                    Text("\(days)").tag(days)
                }
            }
            .pickerStyle(.menu)
            .disabled(status.backfillRunning)
            Button(action: startBackfill) {
                if status.backfillRunning {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Backfilling…")
                    }
                } else {
                    Text("Backfill")
                }
            }
            .disabled(!enabled || status.backfillRunning)
        } header: {
            Text("Backfill")
        } footer: {
            Text(
                "Glucose, insulin, carbs, and loop results stay on the phone for about 90 days. Overrides and prediction curves are kept for less time, so leave upload on to catch them. The first Health sync is the last day; Backfill reads older Health samples."
            )
        }
        .listRowBackground(Color.chart)
    }

    private var troubleshootingSection: some View {
        Section {
            Button("Reset backfill", role: .destructive) { confirmReset = true }
                .disabled(!enabled)
        } header: {
            Text("Troubleshooting")
        } footer: {
            Text("Forgets upload progress and resends the selected window. Nothing is deleted; the server skips duplicates.")
        }
        .listRowBackground(Color.chart)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { enabled }, set: { setEnabled($0) })
    }

    private var subtitle: String {
        guard enabled else { return "Off, nothing leaves this phone" }
        if let host = HealthIngestOrigin.host(baseURL) {
            return "On, uploading to \(host)"
        }
        return "On"
    }

    @ViewBuilder private var stateRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(stateColor)
                .frame(width: 10, height: 10)
            Text(stateTitle)
                .font(.headline)
            Spacer()
            if status.backfillRunning {
                ProgressView()
            }
        }
        if !status.backfillRunning, let error = status.lastError, !error.isEmpty, stateTitle == "Error" {
            Text(error)
                .font(.subheadline)
                .foregroundStyle(.red)
        }
    }

    private var stateTitle: String {
        if status.backfillRunning { return "Backfilling" }
        if let error = status.lastError, !error.isEmpty { return "Error" }
        return "Up to date"
    }

    private var stateColor: Color {
        switch stateTitle {
        case "Backfilling": return .blue
        case "Error": return .red
        default: return .green
        }
    }

    private func labeledRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    private func connectionResult(_ text: String) -> some View {
        let ok = text.hasPrefix("Connected")
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? Color.green : Color.red)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(ok ? Color.primary : Color.red)
        }
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
                                        .font(.headline)
                                    Spacer()
                                    Text(row.count.formatted())
                                        .foregroundStyle(.secondary)
                                }
                                if row.message != row.reason {
                                    Text(row.message)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Text(Self.seen(row.lastSeen))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text(HealthIngestType.displayName(bucket.type))
                    }
                    .listRowBackground(Color.chart)
                }
            }
            Section {
                Text("The phone keeps the last 200 rejects. The server keeps the full history.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            Section {
                Button("Clear", role: .destructive, action: onClear)
            }
            .listRowBackground(Color.chart)
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Rejected")
        .navigationBarTitleDisplayMode(.inline)
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
