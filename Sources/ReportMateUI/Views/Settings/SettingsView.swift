import SwiftUI
import ReportMateKit

struct SettingsView: View {
    @State private var fleet = FleetSettingsStore()

    var body: some View {
        TabView {
            ConnectionSettingsView()
                .tabItem { Label("Connection", systemImage: "network") }
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "textformat.size") }
            ForEach(FleetSettingsView.Section.allCases) { section in
                FleetSettingsView(section: section, store: fleet)
                    .tabItem { Label(section.rawValue, systemImage: section.systemImage) }
            }
        }
        .frame(width: 880)
        .frame(minHeight: 520)
    }
}

struct ConnectionSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var draft = AppConfiguration()
    @State private var testing = false
    @State private var testResult: String?
    @State private var testFailed = false

    var body: some View {
        Form {
            Section {
                TextField("API URL", text: $draft.baseURL, prompt: Text("https://reportmate.example.com"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                TextField("Web dashboard URL", text: $draft.webBaseURL, prompt: Text("https://reportmate.example.com"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                Text("Optional. Copy Link then produces web links that open in this app when it is installed and in the browser otherwise.")
                    .appFont(.caption).foregroundStyle(.secondary)
                Picker("Authentication", selection: $draft.authMethod) {
                    ForEach(AuthMethod.allCases) { Text($0.displayName).tag($0) }
                }
                switch draft.authMethod {
                case .apiKey:
                    LabeledContent("API key", value: draft.apiKey.isEmpty ? "Not provided" : "Ending …\(draft.apiKey.suffix(4))")
                    Text("For deployments without Entra sign-in. The app stores no secrets: the key is read from REPORTMATE_API_KEY or from a configuration profile that sets ApiKey in com.github.reportmate.mac.")
                        .appFont(.caption).foregroundStyle(.secondary)
                case .passphrase:
                    LabeledContent("Passphrase", value: draft.passphrase.isEmpty ? "Not provided" : "Set (\(sourceName(draft.credentialSource)))")
                    Text("The legacy shared passphrase. The app stores no secrets: it is read from REPORTMATE_PASSPHRASE, a configuration profile that sets Passphrase in com.github.reportmate.mac, or the runner's com.github.reportmate domain. Prefer Entra sign-in.")
                        .appFont(.caption).foregroundStyle(.secondary)
                case .entraBearer:
                    HStack {
                        TextField("Entra audience (app id or api:// URI)", text: $draft.oidcAudience)
                            .autocorrectionDisabled()
                        Button("Discover") { Task { await discoverAudience() } }
                            .disabled(draft.baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
                            .help("Ask the API which Entra audience it accepts")
                    }
                    .task(id: draft.baseURL) { if draft.oidcAudience.isEmpty { await discoverAudience() } }
                    Text("Tokens are minted from your local `az login` session; nothing is stored on this Mac.")
                        .appFont(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("ReportMate API")
            }

            Section {
                HStack {
                    Button(testing ? "Testing…" : "Test Connection") { Task { await test() } }
                        .disabled(testing || !draft.isConfigured)
                    if let testResult {
                        Label(testResult, systemImage: testFailed ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(testFailed ? .red : .green)
                            .appFont(.callout)
                            .lineLimit(3)
                    }
                    Spacer()
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!draft.isConfigured || draft == appState.configuration)
                }
            }

            Section {
                LabeledContent("Credential", value: appState.configuration.credentialSummary)
                if appState.configuration.inheritedFromRunner {
                    LabeledContent("Source") {
                        Text(appState.configuration.isConfigured ? "Inherited from the ReportMate runner's configuration on this Mac (com.github.reportmate). Save keeps your own URL and sign-in choice; secrets are never stored." : "The API URL comes from the ReportMate runner's configuration on this Mac. The runner's own key is an ingest credential the API refuses for reads, so choose Entra sign-in.")
                            .appFont(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                }
                LabeledContent("Environment overrides") {
                    Text("REPORTMATE_URL, REPORTMATE_API_KEY, REPORTMATE_PASSPHRASE, REPORTMATE_OIDC_AUDIENCE")
                        .appFont(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
                Button("Reset Connection", role: .destructive) {
                    AppConfiguration.reset()
                    draft = AppConfiguration.load()
                    appState.update(configuration: draft)
                }
                .help("Forget the URL and sign-in choice saved in this app; the environment, profiles and the runner still apply")
            }
        }
        .formStyle(.grouped)
        .onAppear { draft = appState.configuration }
    }

    /// Fill the audience from the deployment's /auth/config.
    private func discoverAudience() async {
        guard let auth = try? await AuthConfig.discover(baseURL: draft.baseURL), auth.oidcEnabled, let audience = auth.audience else {
            if draft.oidcAudience.isEmpty { testResult = "This API does not advertise Entra sign-in"; testFailed = true }
            return
        }
        guard AppConfiguration.isTrustedDiscoveryURL(draft.baseURL), AppConfiguration.isAcceptableAudience(audience) else {
            testResult = "The API advertised \(audience), which is not an api:// audience; enter it by hand if it is right"
            testFailed = true
            return
        }
        draft.oidcAudience = audience
        testResult = nil
    }

    private func test() async {
        testing = true
        testResult = nil
        defer { testing = false }
        let api = appState.preview(configuration: draft)
        do {
            let total = try await api.testConnection()
            testFailed = false
            testResult = "Connected, \(total) devices"
        } catch {
            testFailed = true
            testResult = error.localizedDescription
        }
    }

    private func save() {
        // A URL typed here is the app's own, no longer the runner's.
        if draft.normalizedBaseURL != appState.configuration.normalizedBaseURL { draft.inheritedFromRunner = false }
        appState.update(configuration: draft)
    }

    private func sourceName(_ source: CredentialSource) -> String {
        switch source {
        case .environment: return "environment"
        case .managedProfile: return "configuration profile"
        case .runner: return "runner"
        case .none: return "unknown"
        }
    }
}

