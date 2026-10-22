import Foundation

/// `GET /api/v1/dashboard/insights`: the twelve dashboard cards in one cached
/// document, computed by the API in SQL (reportmate-api `dashboard_insights.py`).
/// Each card holds counts and short top-N lists, never device rows, and every
/// item carries `link: {path, params}`, the report and filter it opens. A card
/// the server could not compute is `{"error": "..."}`; the rest still render.
public struct DashboardInsightsDocument: Sendable, Hashable {
    /// The card keys the API serves at `/dashboard/insights/{card}` and in the combined document.
    public static let cardKeys = [
        "installHealth", "rebootDebt", "protectionGaps", "managementToolLogs", "storage",
        "checkinGaps", "osCurrency", "softwareRisk", "expiringCertificates", "directoryServices", "connectivityProblems",
    ]
    /// App Usage has its own endpoint, `/dashboard/insights/appUsage`, because it takes filters.
    public static let appUsageKey = "appUsage"

    /// The card in a per-card answer: `{card, platform, includeArchived, generatedAt, data}`,
    /// where `data` is the card or `{"error": …}`. A bare card is taken as it is.
    public static func card(fromEnvelope json: JSONValue) -> InsightCardData {
        if json["data"].object != nil { return InsightCardData(json: json["data"]) }
        return InsightCardData(json: json)
    }

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
        // A server from before the rename: its cards answer under their current keys.
        for (current, old) in DashboardInsightsDocument.renamedKeys where cards[current] == nil {
            if let card = cards[old] { cards[current] = card }
        }
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
    /// A nested figure (`sampleDevice`, `pending`) or list (`byPlatform`, `segments`).
    public func item(_ key: String) -> InsightItem? { json[key].object == nil ? nil : InsightItem(json: json[key]) }
    public func items(_ key: String) -> [InsightItem] { json[key].elements.map(InsightItem.init(json:)) }

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

/// The Management Tools Logs card's lists, made safe against an older API that
/// counted the MDM agent's own logs and listed one message several times.
public enum ManagementToolMessages {
    /// `<ts> -<n>:<n> [ERR] Device registration failed` → `Device registration failed`.
    public static func normalize(_ message: String) -> String {
        var m = message.trimmingCharacters(in: .whitespaces)
        let prefixes = [
            #"^(<ts>|\d{4}-\d{2}-\d{2}[T ][\d:.,]+Z?)\s*"#,
            #"^[+-]?(<n>|\d{1,2}):?(<n>|\d{2})\s+"#,
            #"^\[(ERR|ERROR|WARN|WARNING|INFO|DEBUG|E|W|I|D)\]\s*"#,
            #"^(ERROR|WARN|WARNING|ERR)[:\s]+"#,
        ]
        for pattern in prefixes {
            if let r = m.range(of: pattern, options: [.regularExpression, .caseInsensitive]) { m.removeSubrange(r) }
        }
        return m.trimmingCharacters(in: .whitespaces)
    }

    /// The MDM agent's own logs are out of scope; the API tags that root `mdm`.
    public static func isMDMAgent(_ tool: String?) -> Bool { (tool ?? "").lowercased() == "mdm" }

    /// Tools without the MDM agent.
    public static func tools(_ card: InsightCardData) -> [InsightItem] {
        card.items("tools").filter { !isMDMAgent($0.string("tool")) }
    }

    /// Top errors grouped by tool and normalised message, devices and lines summed,
    /// most devices first. The first entry's links stand for the group.
    public static func topErrors(_ card: InsightCardData) -> [(message: String, item: InsightItem, devices: Int, lines: Int)] {
        var order: [String] = []
        var groups: [String: (message: String, item: InsightItem, devices: Int, lines: Int)] = [:]
        for e in card.items("topErrors") where !isMDMAgent(e.string("tool")) {
            let message = normalize(e.string("message") ?? "")
            let key = "\(e.string("tool") ?? "")|\(message.lowercased())"
            if var g = groups[key] {
                g.devices += e.int("devices") ?? 0
                g.lines += e.int("lines") ?? 0
                groups[key] = g
            } else {
                groups[key] = (message, e, e.int("devices") ?? 0, e.int("lines") ?? 0)
                order.append(key)
            }
        }
        return order.compactMap { groups[$0] }.sorted { $0.devices != $1.devices ? $0.devices > $1.devices : $0.lines > $1.lines }
    }
}

extension DashboardInsightsDocument {
    /// A card under its current key, or the key it had before the API renamed it.
    public static let renamedKeys: [String: String] = ["managementToolLogs": "managementToolErrors", "directoryServices": "directoryJoin"]
}
