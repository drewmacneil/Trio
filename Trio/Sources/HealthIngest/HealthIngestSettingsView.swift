import SwiftUI
import Swinject

/// Private ingest server settings. Off until the upload switch is turned on.
/// The token is written to the Keychain and is not shown again.
struct HealthIngestSettingsView: View {
    @ObservedObject private var uploader: HealthIngestUploader
    @State private var baseURL: String
    @State private var tokenDraft = ""
    @State private var testResult: String?
    @State private var testing = false
    @State private var backfillDays = 7

    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    private let backfillChoices = [1, 3, 7, 14, 30, 90]

    init(resolver: Resolver) {
        let uploader = resolver.resolve(HealthIngestUploader.self)!
        _uploader = ObservedObject(wrappedValue: uploader)
        _baseURL = State(initialValue: uploader.preferences.baseURL)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Upload to private server", isOn: enabledBinding)
            } footer: {
                Text("Off by default. Nightscout is unchanged. The address and token stay on this phone.")
            }
            .listRowBackground(Color.chart)

            Section {
                TextField("https://example.ts.net", text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .onSubmit { uploader.setBaseURL(baseURL) }
                SecureField(uploader.status.hasToken ? "Token saved in Keychain" : "Bearer token", text: $tokenDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save token") { saveToken() }
                    .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if uploader.status.hasToken {
                    Button("Remove token", role: .destructive) {
                        uploader.clearToken()
                        tokenDraft = ""
                    }
                }
            } header: {
                Text("Server")
            } footer: {
                Text("Use the server origin, including https. The token is stored in the Keychain.")
            }
            .listRowBackground(Color.chart)

            Section {
                Button(testing ? "Testing…" : "Test connection") { runTest() }
                    .disabled(testing)
                if let testResult {
                    Text(testResult).font(.footnote).foregroundStyle(.secondary)
                }
                statusRow("Last success", uploader.status.lastSuccess?.formatted(date: .abbreviated, time: .shortened) ?? "None")
                statusRow("Queue", "\(uploader.status.queueDepth)")
                if uploader.status.backfillRunning {
                    Text("Backfill is still reading Health samples.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let error = uploader.status.lastError, !error.isEmpty {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("Status")
            }
            .listRowBackground(Color.chart)

            Section {
                ForEach(HealthIngestCategory.allCases) { category in
                    Toggle(category.title, isOn: categoryBinding(category))
                }
            } header: {
                Text("Data")
            } footer: {
                Text("Each category is included once upload is on. Turn one off to leave it on the phone.")
            }
            .listRowBackground(Color.chart)

            Section {
                Picker("Days", selection: $backfillDays) {
                    ForEach(backfillChoices, id: \.self) { days in
                        Text("\(days)").tag(days)
                    }
                }
                Button("Backfill") { uploader.backfill(days: backfillDays) }
                    .disabled(!uploader.preferences.enabled)
            } header: {
                Text("Backfill")
            } footer: {
                Text(
                    "Glucose, insulin, carbs, and loop results stay on the phone for about 90 days. Overrides and prediction curves are kept for less time, so leave upload on to catch them. The first Health sync is the last day; Backfill reads older Health samples."
                )
            }
            .listRowBackground(Color.chart)
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Health Ingest")
        .navigationBarTitleDisplayMode(.automatic)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { uploader.preferences.enabled },
            set: { uploader.setEnabled($0, baseURL: baseURL) }
        )
    }

    private func categoryBinding(_ category: HealthIngestCategory) -> Binding<Bool> {
        Binding(
            get: { uploader.preferences.isOn(category) },
            set: { uploader.setCategory(category, enabled: $0) }
        )
    }

    private func statusRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    private func saveToken() {
        uploader.setToken(tokenDraft)
        tokenDraft = ""
    }

    private func runTest() {
        testing = true
        testResult = nil
        let url = baseURL
        Task {
            let result = await uploader.testConnection(baseURL: url)
            testResult = result
            testing = false
        }
    }
}
