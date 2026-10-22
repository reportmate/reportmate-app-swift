import Foundation

/// `GET /api/v1/dashboard/insights`: the twelve dashboard cards in one cached
/// document, computed by the API in SQL (reportmate-api `dashboard_insights.py`).
/// Each card holds counts and short top-N lists, never device rows, and every
/// item carries `link: {path, params}`, the report and filter it opens. A card
/// the server could not compute is `{"error": "..."}`; the rest still render.
public struct DashboardInsightsDocument: Sendable, Hashable {
    /// The card keys, in the spec's order (1 Reboot & Update Debt … 12 Connectivity Problems).
    public static let cardKeys = [
        "rebootDebt", "protectionGaps", "unmanagedDevices", "hardwareAtRisk",
        "installHealth", "checkinGaps", "osCurrency", "softwareRisk",
        "expiringCertificates", "localAdminExposure", "unusedSoftware", "connectivityProblems",
    ]

    public let generatedAt: Date?
    public let platform: String
    public let includeArchived: Bool
    public let cards: [String: InsightCardData]

    public init(json: JSONValue) {
        generatedAt = FlexibleDate.parse(json["generatedAt"])
        platform = json["platform"].string ?? "all"
        includeArchived = json["includeArchived"].boolish
        var cards: [String: InsightCardData] = [:]
        for (key, value) in json["cards"].object ?? [:] { cards[key] = InsightCardData(json: value) }
        self.cards = cards
    }

    public func card(_ key: String) -> InsightCardData? { cards[key] }

    /// The `platform` query value for the app's platform toggle.
    public static func platformParameter(_ filter: PlatformFilter) -> String {
        switch filter {
        case .all: return "all"
        case .macOS: return "macOS"
        case .windows: return "Windows"
        }
    }
}

/// One card's section of the document.
public struct InsightCardData: Sendable, Hashable {
    public let json: JSONValue

    public init(json: JSONValue) { self.json = json }

    /// The server's message when this card failed.
    public var error: String? { json["error"].nonEmptyString }

    public func int(_ key: String) -> Int? { json[key].int }
    public func bool(_ key: String) -> Bool { json[key].boolish }
    /// A named figure such as `uptime30dPlus` or `withErrors`.
    public func item(_ key: String) -> InsightItem? { json[key].object == nil ? nil : InsightItem(json: json[key]) }
    /// A list such as `gaps`, `topFailing` or `lagging`.
    public func items(_ key: String) -> [InsightItem] { json[key].elements.map(InsightItem.init(json:)) }
}

/// A figure or list entry: whatever the card shows, plus the link it opens.
public struct InsightItem: Sendable, Hashable, Identifiable {
    public let json: JSONValue

    public init(json: JSONValue) { self.json = json }

    public var id: String { key ?? name ?? label ?? link?.url.absoluteString ?? json.prettyPrinted }
    public var key: String? { json["key"].nonEmptyString }
    public var label: String? { json["label"].nonEmptyString }
    /// The item's own name: an install item, app, certificate, reason, version or device.
    public var name: String? { json.firstString("name", "commonName", "reason", "version", "platform") }
    /// The headline number: `count`, else `devices`.
    public var count: Int { json["count"].int ?? json["devices"].int ?? 0 }
    public func int(_ key: String) -> Int? { json[key].int }
    public func double(_ key: String) -> Double? { json[key].double }
    public func string(_ key: String) -> String? { json[key].nonEmptyString }

    /// The server's `{path, params}` as an app link.
    public var link: DeepLink? { InsightItem.deepLink(json["link"]) }

    /// `{"path": "/management", "params": {"enrolled": "0"}}` → `reportmate://management?enrolled=0`.
    /// The path arrives percent-encoded (`/applications/usage/Adobe%20Photoshop`).
    public static func deepLink(_ link: JSONValue) -> DeepLink? {
        guard let path = link["path"].nonEmptyString else { return nil }
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let parts = trimmed.split(separator: "/", maxSplits: 1).map(String.init)
        var comps = URLComponents()
        comps.scheme = DeepLink.scheme
        comps.host = parts.first ?? "dashboard"
        if parts.count > 1 { comps.percentEncodedPath = "/" + parts[1] }
        let params = (link["params"].object ?? [:]).compactMap { k, v in v.string.map { URLQueryItem(name: k, value: $0) } }.sorted { $0.name < $1.name }
        if !params.isEmpty { comps.queryItems = params }
        return comps.url.flatMap(DeepLink.init(url:))
    }
}
