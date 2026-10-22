import Foundation

/// How the app authenticates to the API. The API accepts all three; see
/// `verify_authentication` in the API's `dependencies.py`.
public enum AuthMethod: String, Sendable, Codable, CaseIterable, Identifiable {
    /// `X-API-Key`, a per-client scoped key minted from the API's admin endpoints.
    case apiKey
    /// `X-Client-Passphrase`, the legacy shared passphrase (full access).
    case passphrase
    /// `Authorization: Bearer <jwt>` minted by `az account get-access-token`.
    case entraBearer

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .apiKey: return "API key"
        case .passphrase: return "Passphrase"
        case .entraBearer: return "Entra sign-in (az)"
        }
    }
}

/// Where the credential in use came from. The app itself never stores a secret.
public enum CredentialSource: String, Sendable, Codable {
    /// No API key or passphrase: Entra sign-in, or nothing yet.
    case none
    /// `REPORTMATE_API_KEY` or `REPORTMATE_PASSPHRASE`.
    case environment
    /// A configuration profile that manages the app's own domain (`com.github.reportmate.mac`).
    case managedProfile
    /// The runner's `com.github.reportmate` domain (its shared `Passphrase`).
    case runner
}

/// Connection settings for the fleet API.
///
/// Nothing secret is ever written by the app, and the app never reads or writes
/// the Keychain. Entra sign-in (a token minted from the operator's `az login`,
/// kept in memory) is the default and needs no stored secret. The non-secret
/// connection (API URL, auth method, Entra audience, web URL) is kept in the
/// app's preferences. An API key or passphrase, for deployments without Entra,
/// is read only from the environment (`REPORTMATE_API_KEY`,
/// `REPORTMATE_PASSPHRASE`), from a managed profile for the app's domain, or,
/// for the passphrase, from the runner's `com.github.reportmate` domain.
public struct AppConfiguration: Sendable, Equatable {
    public var baseURL: String
    public var authMethod: AuthMethod
    public var apiKey: String
    public var passphrase: String
    public var oidcAudience: String
    /// The web dashboard, used to build links that fall back to the browser.
    public var webBaseURL: String
    /// True when the API URL came from the runner's configuration on this Mac rather than the app's own settings.
    public var inheritedFromRunner = false
    /// Where `apiKey` or `passphrase` came from; secrets are never typed into the app.
    public var credentialSource: CredentialSource = .none

    public static let webBaseURLDefaultsKey = "webBaseURL"
    public static let baseURLDefaultsKey = "apiBaseURL"
    public static let authMethodDefaultsKey = "authMethod"
    public static let oidcAudienceDefaultsKey = "oidcAudience"
    /// The app's own preference domain, which a profile can manage.
    public static let appDomain = "com.github.reportmate.mac"

    public init(baseURL: String = "", authMethod: AuthMethod = .entraBearer, apiKey: String = "", passphrase: String = "", oidcAudience: String = "", webBaseURL: String = "") {
        self.baseURL = baseURL
        self.authMethod = authMethod
        self.apiKey = apiKey
        self.passphrase = passphrase
        self.oidcAudience = oidcAudience
        self.webBaseURL = webBaseURL
    }

    public var normalizedWebURL: URL? {
        var s = webBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty, let url = URL(string: s), url.host != nil else { return nil }
        return url
    }

    public var normalizedBaseURL: String {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        // Accept a URL that already ends in /api/v1 or /api.
        if s.hasSuffix("/api/v1") { s.removeLast("/api/v1".count) }
        if s.hasSuffix("/api") { s.removeLast("/api".count) }
        return s
    }

    public var isConfigured: Bool {
        guard !normalizedBaseURL.isEmpty, URL(string: normalizedBaseURL) != nil else { return false }
        switch authMethod {
        case .apiKey: return !apiKey.isEmpty
        case .passphrase: return !passphrase.isEmpty
        case .entraBearer: return !oidcAudience.isEmpty
        }
    }

    public var credentialSummary: String {
        switch authMethod {
        case .apiKey: return apiKey.isEmpty ? "No API key" : "API key ending …\(apiKey.suffix(4))"
        case .passphrase: return passphrase.isEmpty ? "No passphrase" : "Passphrase set"
        case .entraBearer: return oidcAudience.isEmpty ? "No audience" : "Entra bearer for \(oidcAudience)"
        }
    }

    /// True while the connection still needs the API's `/auth/config` (and `az`) to
    /// settle on a credential: an Entra sign-in with no audience yet, or a passphrase
    /// inherited from the runner that Entra should replace. Requests wait for it, so
    /// none goes out with a credential that is about to be swapped.
    public var needsEntraResolution: Bool {
        guard !normalizedBaseURL.isEmpty else { return false }
        switch authMethod {
        case .entraBearer: return oidcAudience.isEmpty
        case .passphrase: return credentialSource == .runner
        case .apiKey: return false
        }
    }

    // MARK: - Loading

    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppConfiguration {
        load(defaults: .standard, managed: managedSecrets(), runner: fromRunner(), environment: environment)
    }

    /// Build the configuration from its read-only sources. `defaults` holds only
    /// non-secret settings; `managed` carries `ApiKey` / `Passphrase` that a profile
    /// forces in the app's domain.
    public static func load(defaults: UserDefaults, managed: [String: String], runner: AppConfiguration?, environment: [String: String]) -> AppConfiguration {
        func saved(_ key: String) -> String {
            (defaults.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var config = AppConfiguration()
        config.baseURL = saved(baseURLDefaultsKey)
        config.oidcAudience = saved(oidcAudienceDefaultsKey)
        config.webBaseURL = saved(webBaseURLDefaultsKey)
        let savedMethod = AuthMethod(rawValue: saved(authMethodDefaultsKey))

        if let key = managed["ApiKey"], !key.isEmpty { config.apiKey = key; config.credentialSource = .managedProfile }
        if let pass = managed["Passphrase"], !pass.isEmpty { config.passphrase = pass; config.credentialSource = .managedProfile }

        // A Mac whose runner already reports has an API URL (and maybe the shared
        // passphrase) in the runner's domain; the app inherits them so a configured
        // device never says "No API is configured".
        if config.baseURL.isEmpty, let runner {
            config.baseURL = runner.baseURL
            config.inheritedFromRunner = true
        }
        if let runner, config.apiKey.isEmpty, config.passphrase.isEmpty, !runner.passphrase.isEmpty, savedMethod == nil || savedMethod == .passphrase {
            config.passphrase = runner.passphrase
            config.credentialSource = .runner
        }

        if let savedMethod {
            config.authMethod = savedMethod
        } else if !config.apiKey.isEmpty {
            config.authMethod = .apiKey
        } else if !config.passphrase.isEmpty, config.credentialSource != .runner || config.oidcAudience.isEmpty {
            config.authMethod = .passphrase
        } else {
            config.authMethod = .entraBearer
        }

        if let v = environment["REPORTMATE_URL"], !v.isEmpty { config.baseURL = v; config.inheritedFromRunner = false }
        if let v = environment["REPORTMATE_WEB_URL"], !v.isEmpty { config.webBaseURL = v }
        if let v = environment["REPORTMATE_API_KEY"], !v.isEmpty { config.apiKey = v; config.authMethod = .apiKey; config.credentialSource = .environment }
        if let v = environment["REPORTMATE_PASSPHRASE"], !v.isEmpty, environment["REPORTMATE_API_KEY"]?.isEmpty ?? true {
            config.passphrase = v; config.authMethod = .passphrase; config.credentialSource = .environment
        }
        if let v = environment["REPORTMATE_OIDC_AUDIENCE"], !v.isEmpty {
            config.oidcAudience = v
            if config.credentialSource != .environment { config.authMethod = .entraBearer }
        }
        return config
    }

    /// `ApiKey` and `Passphrase` only when a configuration profile forces them in
    /// the app's domain; a value a user wrote there by hand is ignored.
    public static func managedSecrets(domain: String = AppConfiguration.appDomain) -> [String: String] {
        var out: [String: String] = [:]
        for key in ["ApiKey", "Passphrase"] where CFPreferencesAppValueIsForced(key as CFString, domain as CFString) {
            if let v = CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? String {
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out[key] = t }
            }
        }
        return out
    }

    /// The runner's own configuration on this Mac: the `com.github.reportmate`
    /// preference domain, which covers a managed configuration profile and
    /// `/Library/Preferences/com.github.reportmate.plist`. Nil when no API URL is set.
    /// Carries the URL and, when the runner uses one, the shared passphrase.
    public static func fromRunner(domain: String = "com.github.reportmate") -> AppConfiguration? {
        func read(_ key: String) -> String? {
            guard let v = CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? String else { return nil }
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        guard let url = read("ApiUrl") else { return nil }
        var config = AppConfiguration(baseURL: url)
        // The runner's ApiKey is a per-client ingest key that the API refuses for
        // reads with 403, so only the legacy passphrase (full access) is inherited.
        if let pass = read("Passphrase") { config.passphrase = pass; config.authMethod = .passphrase; config.credentialSource = .runner }
        return config
    }

    // MARK: - Saving

    /// Keep the non-secret connection in the app's preferences. Secrets are never
    /// written anywhere: an API key or passphrase stays where it was read from.
    public func save(defaults: UserDefaults = .standard) {
        func put(_ value: String, _ key: String) {
            let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(t, forKey: key) }
        }
        put(inheritedFromRunner ? "" : normalizedBaseURL, AppConfiguration.baseURLDefaultsKey)
        put(authMethod.rawValue, AppConfiguration.authMethodDefaultsKey)
        put(oidcAudience, AppConfiguration.oidcAudienceDefaultsKey)
        put(webBaseURL, AppConfiguration.webBaseURLDefaultsKey)
        exportConnection()
    }

    /// Drop the app's saved connection, so it falls back to the runner and the environment.
    public static func reset(defaults: UserDefaults = .standard) {
        for key in [baseURLDefaultsKey, authMethodDefaultsKey, oidcAudienceDefaultsKey, webBaseURLDefaultsKey] {
            defaults.removeObject(forKey: key)
        }
    }
}

// MARK: - Shared connection for reportmateutil

extension AppConfiguration {
    /// Where the app leaves its non-secret connection for `reportmateutil`, so the
    /// CLI configures itself from the app: the endpoint, the auth method and the
    /// Entra audience. Nothing secret: with Entra sign-in the CLI mints its own token
    /// with `az`; an API key or passphrase reaches it only through `REPORTMATE_*`.
    public static var sharedConnectionURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("ReportMate/connection.json")
    }

    /// The document `reportmateutil` reads. Nothing secret is in it.
    public var sharedConnectionDocument: [String: String] {
        var doc: [String: String] = [:]
        if !normalizedBaseURL.isEmpty { doc["apiUrl"] = normalizedBaseURL }
        doc["authMethod"] = authMethod.rawValue
        if !oidcAudience.isEmpty { doc["oidcAudience"] = oidcAudience }
        if let web = normalizedWebURL?.absoluteString { doc["webUrl"] = web }
        return doc
    }

    /// Write the shared connection; a failure here never affects the app.
    public func exportConnection(to url: URL = AppConfiguration.sharedConnectionURL) {
        guard isConfigured else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: sharedConnectionDocument, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
        }
    }
}

// MARK: - Auth discovery

/// What `/api/v1/auth/config` says a deployment accepts. Public, no secrets.
public struct AuthConfig: Sendable, Equatable {
    public var oidcEnabled: Bool
    public var audience: String?
    public var issuers: [String]

    public init(oidcEnabled: Bool, audience: String?, issuers: [String]) {
        self.oidcEnabled = oidcEnabled; self.audience = audience; self.issuers = issuers
    }

    public init(json: JSONValue) {
        let oidc = json["oidc"]
        oidcEnabled = oidc["enabled"].boolish
        audience = oidc["audience"].nonEmptyString
        issuers = oidc["issuers"].elements.compactMap(\.string)
    }

    /// Fetch the deployment's auth description with no credential.
    public static func discover(baseURL: String, session: URLSession = .shared) async throws -> AuthConfig {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = trimmed.hasSuffix("/api/v1") ? "\(trimmed)/auth/config" : "\(trimmed)/api/v1/auth/config"
        guard let url = URL(string: path) else { throw APIError.transport("Not a valid API URL") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.transport("The API did not answer /auth/config")
        }
        return AuthConfig(json: try JSONValue.parse(data))
    }
}

extension AppConfiguration {
    /// The rule for admin machines: sign in with Entra, never a stored secret.
    /// An Entra configuration with no audience takes the one the API advertises at
    /// `/api/v1/auth/config`. A passphrase inherited from the runner switches to
    /// Entra when the API advertises OIDC and `az` can mint a token. Anything else,
    /// or a deployment without OIDC, is returned unchanged.
    public func resolvingEntra(tokenSource: AzTokenSource = .shared, discover: @Sendable (String) async throws -> AuthConfig = { try await AuthConfig.discover(baseURL: $0) }) async -> AppConfiguration {
        guard needsEntraResolution, Self.isTrustedDiscoveryURL(baseURL) else { return self }
        guard let auth = try? await discover(baseURL), auth.oidcEnabled, let audience = auth.audience,
              Self.isAcceptableAudience(audience) else { return self }
        var out = self
        if authMethod == .passphrase {
            guard (try? await tokenSource.token(forResource: audience)) != nil else { return self }
            out.passphrase = ""
            out.credentialSource = .none
        }
        out.authMethod = .entraBearer
        out.oidcAudience = audience
        return out
    }

    /// Discovery hands the app an audience it then mints an Entra token for, so it
    /// only runs over https (plain http only to this machine, for development).
    public static func isTrustedDiscoveryURL(_ baseURL: String) -> Bool {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces)), let host = url.host?.lowercased() else { return false }
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return host == "localhost" || host == "127.0.0.1" || host == "::1"
        default: return false
        }
    }

    /// An advertised audience must name an app registration: `api://…` or a bare
    /// application ID. Anything else (graph.microsoft.com, management.azure.com,
    /// a vault or storage URL) would have the app mint a token for a first-party
    /// resource and send it to the server that asked for it.
    public static func isAcceptableAudience(_ audience: String) -> Bool {
        let a = audience.trimmingCharacters(in: .whitespaces)
        if UUID(uuidString: a) != nil { return true }
        guard a.lowercased().hasPrefix("api://") else { return false }
        let rest = a.dropFirst("api://".count)
        return !rest.isEmpty && !rest.contains(where: { $0.isWhitespace })
    }
}
