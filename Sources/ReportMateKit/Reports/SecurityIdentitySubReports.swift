import Foundation

// Security › Vulnerabilities and Threat Detections, and Identity › Sign-in & Recovery
// Posture: ports of the web's `src/lib/security/vulnerabilities.ts` and
// `src/lib/identity/posture.ts`. Windows sends MSRC entries with status and severity,
// macOS sends unpatched CVEs with no severity, and only Windows sends individual
// detections; a field that was not collected reads "Not reported", never a guess.

/// How many devices in scope report the list a security report reads.
public struct ReportCoverage: Sendable, Hashable {
    public var devices: Int
    public var reporting: Int
    public var notReporting: Int
    public var unknown: Int
    public var listMayBeIncomplete: Int
    public var devicesWithDetections: Int?

    public init(json: JSONValue) {
        devices = json["devices"].int ?? 0
        reporting = json["reporting"].int ?? 0
        notReporting = json["notReporting"].int ?? 0
        unknown = json["unknown"].int ?? 0
        listMayBeIncomplete = json["listMayBeIncomplete"].int ?? 0
        devicesWithDetections = json["devicesWithDetections"].int
    }

    public var vulnerabilityText: String {
        var s = "\(devices.formatted()) devices in scope: \(reporting.formatted()) report a CVE list"
        if notReporting > 0 { s += ", \(notReporting.formatted()) do not (coverage unknown, not counted as clean)" }
        if unknown > 0 { s += ", \(unknown.formatted()) sent a list that could not be read" }
        s += "."
        if listMayBeIncomplete > 0 { s += " \(listMayBeIncomplete.formatted()) macOS devices reached the client's 50-entry limit, so their lists may be incomplete." }
        return s
    }

    public var detectionText: String {
        var s = "\(devices.formatted()) devices in scope: \(reporting.formatted()) report detections"
        if notReporting > 0 { s += ", \(notReporting.formatted()) do not (macOS clients report no individual detections; not counted as clean)" }
        if unknown > 0 { s += ", \(unknown.formatted()) sent a list that could not be read" }
        s += "."
        if let devicesWithDetections { s += " \(devicesWithDetections.formatted()) devices have matching detections." }
        return s
    }
}

public enum SecurityLabels {
    public static func severity(_ v: String?) -> String { v == nil || v == "not_reported" || v == "" ? "Not reported" : v! }
    public static func exploited(_ v: Bool?) -> String { v.map { $0 ? "Yes" : "No" } ?? "Not reported" }
    public static func status(_ v: String) -> String { v == "unknown" ? "Unknown" : v.prefix(1).uppercased() + v.dropFirst() }
    static func exploitedRank(_ v: Bool?) -> Double { v == true ? 2 : v == false ? 0 : 1 }

    /// A reference link: a known page for a real CVE id, else the collected URL when it is http(s).
    public static func link(cve: String?, url: String?, source: String?) -> URL? {
        if let cve, !cve.isEmpty {
            let base = source == "MSRC" ? "https://msrc.microsoft.com/update-guide/vulnerability/" : "https://nvd.nist.gov/vuln/detail/"
            return URL(string: base + (cve.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cve))
        }
        guard let url, let u = URL(string: url), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { return nil }
        return u
    }

    public static func safeURL(_ url: String?) -> String? {
        guard let url, let u = URL(string: url), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    static let deviceHeaders = ["Device Name", "Serial Number", "Asset Tag", "Platform", "Inventory State", "Archived in ReportMate", "Usage", "Catalog", "Area", "Fleet", "Location", "Room", "Last Seen"]
    static func deviceCells(_ v: ReportDevice) -> [String?] {
        [v.deviceName, v.serialNumber, v.assetTag, v.platform, ReportLabels.inventory(v.inventoryState), v.archived ? "Yes" : "No", v.usage, v.catalog, v.area, v.fleet, v.location, v.room, v.lastSeen]
    }
}

// MARK: - Vulnerabilities

public struct VulnerabilityCatalog: Sendable, Hashable {
    public var cves: [ReportChoice]
    public var severities: [ReportChoice]
    public var options: ReportScopeOptions
    public init?(json: JSONValue) {
        guard let c = json["cves"].array else { return nil }
        cves = c.compactMap { j in j["identifier"].nonEmptyString.map { ReportChoice(value: $0, label: $0, devices: j["devices"].int) } }
        severities = json["severities"].elements.compactMap { j in j["value"].nonEmptyString.map { ReportChoice(value: $0.lowercased(), label: SecurityLabels.severity($0), devices: j["entries"].int) } }
        options = ReportScopeOptions(json: json["options"])
    }
}

public struct CveSummary: Sendable, Hashable, Identifiable {
    public var identifier: String
    public var cve: String?
    public var kbArticle: String?
    public var devices: Int
    public var unpatchedDevices: Int
    public var patchedDevices: Int
    public var activelyExploited: Bool?
    public var severities: [String]
    public var fixedIn: [String]
    public var products: [String]
    public var platforms: [String]
    public var sources: [String]
    public var id: String { identifier }

    public init(json j: JSONValue) {
        identifier = j["identifier"].nonEmptyString ?? j["cve"].nonEmptyString ?? ""
        cve = j["cve"].nonEmptyString
        kbArticle = j["kbArticle"].nonEmptyString
        devices = j["devices"].int ?? 0
        unpatchedDevices = j["unpatchedDevices"].int ?? 0
        patchedDevices = j["patchedDevices"].int ?? 0
        activelyExploited = j["activelyExploited"].bool
        let list: (String) -> [String] = { k in j[k].elements.compactMap(\.nonEmptyString) }
        severities = list("severities"); fixedIn = list("fixedIn"); products = list("products"); platforms = list("platforms"); sources = list("sources")
    }

    public var link: URL? { SecurityLabels.link(cve: cve, url: nil, source: sources.contains("MSRC") ? "MSRC" : sources.first) }
}

public struct VulnerabilityRow: Sendable, Hashable, Identifiable {
    public var device: ReportDevice
    public var identifier: String
    public var cve: String?
    public var kbArticle: String?
    public var label: String?
    public var source: String
    public var status: String
    public var severity: String?
    public var product: String?
    public var affectedVersion: String?
    public var fixedIn: String?
    public var activelyExploited: Bool?
    public var installedDate: String?
    public var url: String?
    public var freshness: ReportFreshness
    public var listMayBeIncomplete: Bool
    public var index: Int
    public var id: Int { index }

    public init(json j: JSONValue, index: Int) {
        device = ReportDevice(json: j)
        identifier = j["identifier"].nonEmptyString ?? j["cve"].nonEmptyString ?? ""
        cve = j["cve"].nonEmptyString
        kbArticle = j["kbArticle"].nonEmptyString
        label = j["label"].nonEmptyString
        source = j["source"].nonEmptyString ?? ""
        status = j["status"].nonEmptyString ?? "unknown"
        severity = j["severity"].nonEmptyString
        product = j["product"].nonEmptyString
        affectedVersion = j["affectedVersion"].nonEmptyString
        fixedIn = j["fixedIn"].nonEmptyString
        activelyExploited = j["activelyExploited"].bool
        installedDate = j["installedDate"].nonEmptyString
        url = j["url"].nonEmptyString
        freshness = ReportFreshness(j["freshness"])
        listMayBeIncomplete = j["listMayBeIncomplete"].bool ?? false
        self.index = index
    }

    public var link: URL? { SecurityLabels.link(cve: cve, url: url, source: source) }
}

public enum VulnerabilitiesReportSpec {
    public static let api = "/security/vulnerabilities"
    public static let pageSize = 5000
    public static let statuses = ["unpatched", "patched", "unknown"]
    public static let exploitedChoices: [(String, String)] = [("all", "All"), ("yes", "Actively exploited"), ("no", "Not exploited"), ("unknown", "Not reported")]
    public static let apiParams = ["cves", "statuses", "severities", "exploited", "freshness", "maxAgeHours"] + ReportScope.keys + ["includeArchived"]
    /// Client-only view state: sorting and the CVE list text filter.
    public static let viewParams = ["sort", "dir", "q"]

    public enum View: String, Sendable { case summary, devices }
    public static func view(_ p: ReportParams) -> View { p["view"] == "devices" ? .devices : .summary }

    public static func apiQuery(_ p: ReportParams, platform: PlatformFilter) -> [String: String] {
        var q = p.picking(apiParams)
        q["platform"] = ReportScope.apiPlatform(platform)
        if view(p) == .summary { q["view"] = "summary" }
        return q
    }

    public static func optionsQuery(_ p: ReportParams, platform: PlatformFilter) -> [String: String] {
        var q = p.picking(["includeArchived"])
        q["platform"] = ReportScope.apiPlatform(platform)
        return q
    }

    /// The summary list narrowed by the CVE filter box (`q`).
    public static func filterSummary(_ rows: [CveSummary], query: String) -> [CveSummary] {
        let n = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !n.isEmpty else { return rows }
        return rows.filter { r in ([r.identifier, r.kbArticle] + r.products.map(Optional.some) + r.fixedIn.map(Optional.some)).contains { $0?.lowercased().contains(n) ?? false } }
    }

    public static let summaryColumns: [ReportColumn<CveSummary>] = [
        ReportColumn("identifier", "CVE", kind: .mono, value: { $0.identifier }, detail: { r in r.cve != nil ? r.kbArticle : nil }),
        ReportColumn("devices", "Devices", kind: .number, value: { String($0.devices) }, sortKey: { .number(Double($0.devices)) }),
        ReportColumn("unpatchedDevices", "Unpatched", kind: .number, value: { String($0.unpatchedDevices) }, sortKey: { .number(Double($0.unpatchedDevices)) }),
        ReportColumn("severities", "Severity", value: { $0.severities.isEmpty ? nil : $0.severities.joined(separator: ", ") }),
        ReportColumn("exploited", "Actively exploited", kind: .state, missing: "Not reported", value: { SecurityLabels.exploited($0.activelyExploited) },
                     sortKey: { .number(SecurityLabels.exploitedRank($0.activelyExploited)) }),
        ReportColumn("fixedIn", "Fixed in", value: { $0.fixedIn.isEmpty ? nil : $0.fixedIn.joined(separator: ", ") }),
        ReportColumn("products", "Affected product", value: { $0.products.isEmpty ? nil : $0.products.joined(separator: ", ") }),
        ReportColumn("platforms", "Platform", value: { $0.platforms.isEmpty ? nil : $0.platforms.joined(separator: ", ") }),
    ]

    public static let deviceColumns: [ReportColumn<VulnerabilityRow>] = [
        ReportColumn("identifier", "CVE", kind: .mono, value: { $0.identifier }, detail: { r in [r.cve != nil ? r.kbArticle : nil, r.label != r.identifier ? r.label : nil].compactMap { $0 }.joined(separator: "\n").nilIfEmpty }),
        ReportColumn("severity", "Severity", missing: "Not reported", value: { $0.severity.map { SecurityLabels.severity($0) } }),
        ReportColumn("product", "Affected product", value: { $0.product }),
        ReportColumn("affectedVersion", "Affected version", kind: .mono, value: { $0.affectedVersion }),
        ReportColumn("fixedIn", "Fixed in", kind: .mono, value: { $0.fixedIn }),
        ReportColumn("exploited", "Actively exploited", kind: .state, value: { SecurityLabels.exploited($0.activelyExploited) },
                     sortKey: { .number(SecurityLabels.exploitedRank($0.activelyExploited)) }),
        ReportColumn("status", "Status", kind: .state, value: { SecurityLabels.status($0.status) }, sortKey: { ReportSortKey.string($0.status) },
                     detail: { $0.listMayBeIncomplete ? "List may be incomplete" : nil }),
        ReportColumn("device", "Device", kind: .device, value: { $0.device.displayName }),
        ReportColumn("platform", "Platform", value: { $0.device.platform }),
        ReportColumn("collectedAt", "Collected", kind: .time, value: { $0.device.collectedAt }, detail: { $0.freshness.label }),
    ]

    public static let summaryCSVHeaders = ["CVE", "Update Article", "Devices", "Unpatched Devices", "Patched Devices", "Severity", "Actively Exploited",
                                           "Fixed In", "Affected Product", "Platforms", "Sources", "Report Generated At", "Report URL"]
    public static func summaryCSVRows(_ rows: [CveSummary], generatedAt: String, reportURL: String) -> [[String?]] {
        rows.map { r in [r.cve ?? r.identifier, r.kbArticle, String(r.devices), String(r.unpatchedDevices), String(r.patchedDevices),
                         r.severities.isEmpty ? "Not reported" : r.severities.joined(separator: "; "), SecurityLabels.exploited(r.activelyExploited),
                         r.fixedIn.joined(separator: "; "), r.products.joined(separator: "; "), r.platforms.joined(separator: "; "), r.sources.joined(separator: "; "),
                         generatedAt, reportURL] }
    }

    public static let deviceCSVHeaders = ["CVE", "Update Article", "Reported Identifier", "Source", "Status", "Severity", "Affected Product", "Affected Version",
                                          "Fixed In", "Actively Exploited", "Installed Date", "Reference URL", "Security Collection Time", "Collection Freshness",
                                          "List May Be Incomplete"] + SecurityLabels.deviceHeaders + ["Report Generated At", "Report URL"]
    public static func deviceCSVRows(_ rows: [VulnerabilityRow], generatedAt: String, reportURL: String) -> [[String?]] {
        rows.map { r in [r.cve, r.kbArticle, r.label, r.source, SecurityLabels.status(r.status), SecurityLabels.severity(r.severity), r.product, r.affectedVersion,
                         r.fixedIn, SecurityLabels.exploited(r.activelyExploited), r.installedDate, SecurityLabels.safeURL(r.url), r.device.collectedAt,
                         r.freshness.rawValue, r.listMayBeIncomplete ? "Yes" : "No"] + SecurityLabels.deviceCells(r.device) + [generatedAt, reportURL] }
    }
}

public struct VulnerabilitySummaryData: Sendable, Hashable {
    public var generatedAt: String
    public var coverage: ReportCoverage
    public var cves: [CveSummary]
    public init?(json: JSONValue) {
        guard let c = json["cves"].array else { return nil }
        generatedAt = json["generatedAt"].nonEmptyString ?? ""
        coverage = ReportCoverage(json: json["coverage"])
        cves = c.map(CveSummary.init(json:))
    }
}

public struct VulnerabilityDevicesData: Sendable, Hashable {
    public var generatedAt: String
    public var coverage: ReportCoverage
    public var total: Int
    public var rows: [VulnerabilityRow]
    public init(envelope e: JSONValue, rows: [JSONValue]) {
        generatedAt = e["generatedAt"].nonEmptyString ?? ""
        coverage = ReportCoverage(json: e["coverage"])
        total = e["total"].int ?? rows.count
        self.rows = rows.enumerated().map { VulnerabilityRow(json: $1, index: $0) }
    }
}

// MARK: - Threat detections

public struct DetectionCatalog: Sendable, Hashable {
    public var vendors: [ReportChoice]
    public var categories: [ReportChoice]
    public var severities: [ReportChoice]
    public var statuses: [ReportChoice]
    public var options: ReportScopeOptions
    public init?(json: JSONValue) {
        guard json["vendors"].array != nil || json["categories"].array != nil else { return nil }
        let parse: (String) -> [ReportChoice] = { k in json[k].elements.compactMap { j in j["value"].nonEmptyString.map { ReportChoice(value: $0.lowercased(), label: SecurityLabels.severity($0), devices: j["devices"].int) } } }
        vendors = parse("vendors"); categories = parse("categories"); severities = parse("severities"); statuses = parse("statuses")
        options = ReportScopeOptions(json: json["options"])
    }
}

public struct DetectionRow: Sendable, Hashable, Identifiable {
    public var device: ReportDevice
    public var threatName: String?
    public var threatId: String?
    public var severity: String?
    public var vendor: String?
    public var category: String?
    public var status: String?
    public var actionTaken: String?
    public var detectedAt: String?
    public var firstSeenAt: String?
    public var lastSeenAt: String?
    public var count: Int?
    public var path: String?
    public var processName: String?
    public var user: String?
    public var index: Int
    public var id: Int { index }

    public init(json j: JSONValue, index: Int) {
        device = ReportDevice(json: j)
        threatName = j["threatName"].nonEmptyString
        threatId = j["threatId"].nonEmptyString
        severity = j["severity"].nonEmptyString
        vendor = j["vendor"].nonEmptyString
        category = j["category"].nonEmptyString
        status = j["status"].nonEmptyString
        actionTaken = j["actionTaken"].nonEmptyString
        detectedAt = j["detectedAt"].nonEmptyString
        firstSeenAt = j["firstSeenAt"].nonEmptyString
        lastSeenAt = j["lastSeenAt"].nonEmptyString
        count = j["count"].int
        path = j["path"].nonEmptyString
        processName = j["processName"].nonEmptyString
        user = j["user"].nonEmptyString
        self.index = index
    }

    public var seenAt: String? { lastSeenAt ?? detectedAt }
}

public struct DetectionsData: Sendable, Hashable {
    public var generatedAt: String
    public var days: Int?
    public var coverage: ReportCoverage
    public var total: Int
    public var rows: [DetectionRow]
    public init(envelope e: JSONValue, rows: [JSONValue]) {
        generatedAt = e["generatedAt"].nonEmptyString ?? ""
        days = e["days"].int
        coverage = ReportCoverage(json: e["coverage"])
        total = e["total"].int ?? rows.count
        self.rows = rows.enumerated().map { DetectionRow(json: $1, index: $0) }
    }
}

public enum DetectionsReportSpec {
    public static let api = "/security/detections"
    public static let pageSize = 5000
    public static let defaultDays = 30
    public static let dayChoices: [(Int, String)] = [(1, "24 hours"), (7, "7 days"), (30, "30 days"), (90, "90 days"), (0, "All collected")]
    public static let apiParams = ["vendors", "categories", "severities", "statuses"] + ReportScope.keys + ["includeArchived"]
    public static let viewParams = ["sort", "dir"]

    public static func days(_ p: ReportParams) -> Int {
        guard let raw = p["days"] else { return defaultDays }
        guard let d = Int(raw), d >= 0, d <= 3650 else { return defaultDays }
        return d
    }

    public static func apiQuery(_ p: ReportParams, platform: PlatformFilter) -> [String: String] {
        var q = p.picking(apiParams)
        q["platform"] = ReportScope.apiPlatform(platform)
        q["days"] = String(days(p))
        return q
    }

    public static func optionsQuery(_ p: ReportParams, platform: PlatformFilter) -> [String: String] {
        var q = p.picking(["includeArchived"])
        q["platform"] = ReportScope.apiPlatform(platform)
        return q
    }

    public static let columns: [ReportColumn<DetectionRow>] = [
        ReportColumn("threatName", "Threat", value: { $0.threatName }, detail: { $0.actionTaken.map { "Action: \($0)" } }),
        ReportColumn("severity", "Severity", value: { $0.severity }),
        ReportColumn("vendor", "Vendor / product", value: { $0.vendor }),
        ReportColumn("category", "Category", value: { $0.category }),
        ReportColumn("status", "Status", value: { $0.status }),
        ReportColumn("lastSeenAt", "Detected", kind: .time, value: { $0.seenAt },
                     detail: { r in r.firstSeenAt != nil && r.firstSeenAt != r.seenAt ? "First \(TimeFormatting.relative(r.firstSeenAt))" : nil }),
        ReportColumn("count", "Count", kind: .number, missing: "Not reported (1 event)", value: { $0.count.map(String.init) }, sortKey: { $0.count.map { .number(Double($0)) } }),
        ReportColumn("path", "Path", kind: .mono, value: { $0.path }, detail: { $0.processName.map { "Process: \($0)" } }),
        ReportColumn("device", "Device", kind: .device, value: { $0.device.displayName }),
        ReportColumn("platform", "Platform", value: { $0.device.platform }),
    ]

    public static let csvHeaders = ["Threat", "Threat ID", "Severity", "Vendor / Product", "Category", "Status", "Action Taken", "Detected At",
                                    "First Seen", "Last Seen", "Count", "Path", "Process", "User"] + SecurityLabels.deviceHeaders + ["Report Generated At", "Report URL"]
    public static func csvRows(_ rows: [DetectionRow], generatedAt: String, reportURL: String) -> [[String?]] {
        rows.map { r in [r.threatName, r.threatId, SecurityLabels.severity(r.severity), r.vendor, r.category, r.status, r.actionTaken, r.detectedAt,
                         r.firstSeenAt, r.lastSeenAt, r.count.map(String.init), r.path, r.processName, r.user] + SecurityLabels.deviceCells(r.device) + [generatedAt, reportURL] }
    }
}

// MARK: - Identity posture

public struct PostureDevice: Sendable, Hashable, Identifiable {
    public var device: ReportDevice
    public var computerName: String?
    public var identityCollectedAt: String?
    public var securityCollectedAt: String?
    public var identityFreshness: ReportFreshness
    public var securityFreshness: ReportFreshness
    /// The values the API derived from what the device reported; read through `PostureReportSpec`.
    public var reported: JSONValue
    public var checks: [String: Bool?]
    public var unreadable: Bool
    public var id: String { device.serialNumber }

    public init(json j: JSONValue) {
        device = ReportDevice(json: j)
        computerName = j["computerName"].nonEmptyString
        identityCollectedAt = j["identityCollectedAt"].nonEmptyString
        securityCollectedAt = j["securityCollectedAt"].nonEmptyString
        identityFreshness = ReportFreshness(j["identityFreshness"])
        securityFreshness = ReportFreshness(j["securityFreshness"])
        reported = j["reported"].object == nil ? .object([:]) : j["reported"]
        var c: [String: Bool?] = [:]
        for (key, _, _) in PostureReportSpec.quickViews { c[key] = ReportLabels.tri(j["checks"][key]) }
        checks = c
        unreadable = j["unreadable"].bool ?? false
    }

    var isMac: Bool { device.platform == "macOS" }
    var isWindows: Bool { device.platform == "Windows" }
}

public struct PostureReportData: Sendable, Hashable {
    public var generatedAt: String
    public var maxAgeHours: Int?
    public var total: Int
    public var summary: [String: Int]
    public var unknown: [String: Int]
    public var options: ReportScopeOptions
    public var devices: [PostureDevice]
    public init(envelope e: JSONValue, rows: [JSONValue]) {
        generatedAt = e["generatedAt"].nonEmptyString ?? ""
        maxAgeHours = e["maxAgeHours"].int
        total = e["total"].int ?? rows.count
        summary = (e["summary"].object ?? [:]).compactMapValues(\.int)
        unknown = (e["unknown"].object ?? [:]).compactMapValues(\.int)
        options = ReportScopeOptions(json: e["options"])
        devices = rows.map(PostureDevice.init(json:))
    }
}

public enum PostureReportSpec {
    public static let api = "/identity/posture"
    public static let pageSize = 500
    /// Quick views: key, label, platform.
    public static let quickViews: [(String, String, String)] = [
        ("noLaps", "No LAPS", "Windows"), ("autoLogin", "Auto-login on", "Windows"),
        ("expiredPssoToken", "Expired Platform SSO token", "macOS"), ("activationLock", "Activation Lock on", "macOS"),
        ("noRecoveryKey", "No FileVault recovery key", "macOS"),
    ]
    public static let apiParams = ["views", "freshness", "maxAgeHours"] + ReportScope.keys + ["includeArchived"]
    public static let viewParams = ["sort", "direction", "columns"]

    /// Columns: key, label, platform scope.
    public static let columnScopes: [(String, String, String)] = [
        ("deviceName", "Device", "all"), ("platform", "Platform", "all"), ("inventoryState", "Inventory", "all"),
        ("laps", "LAPS", "Windows"), ("autoLogin", "Auto-login", "Windows"), ("uac", "UAC", "Windows"),
        ("passwordPolicy", "Password policy", "Windows"), ("hello", "Windows Hello", "Windows"),
        ("credentialGuard", "Credential Guard", "Windows"), ("tpm", "TPM ownership", "Windows"),
        ("failedLogins", "Failed sign-ins (7 days)", "Windows"),
        ("psso", "Platform SSO", "macOS"), ("secureToken", "Secure Token", "macOS"), ("bootstrapToken", "Bootstrap Token", "macOS"),
        ("activationLock", "Activation Lock", "macOS"), ("findMy", "Find My", "macOS"), ("recoveryKey", "FileVault recovery key", "macOS"),
        ("identityCollectedAt", "Identity collection", "all"), ("securityCollectedAt", "Security collection", "macOS"),
        ("lastSeen", "Last seen", "all"),
    ]

    public static func defaultColumns(_ platform: PlatformFilter) -> [String] {
        switch platform {
        case .windows: return ["deviceName", "laps", "autoLogin", "uac", "passwordPolicy", "hello", "credentialGuard", "tpm", "failedLogins", "identityCollectedAt"]
        case .macOS: return ["deviceName", "psso", "secureToken", "bootstrapToken", "activationLock", "findMy", "recoveryKey", "identityCollectedAt", "securityCollectedAt"]
        case .all: return ["deviceName", "platform", "laps", "autoLogin", "psso", "activationLock", "recoveryKey", "inventoryState", "identityCollectedAt"]
        }
    }

    static func platformName(_ p: PlatformFilter) -> String { p == .macOS ? "macOS" : p == .windows ? "Windows" : "all" }

    public static func availableColumns(_ platform: PlatformFilter) -> [String] {
        let name = platformName(platform)
        return columnScopes.filter { $0.2 == "all" || name == "all" || $0.2 == name }.map(\.0)
    }

    public static func quickViews(for platform: PlatformFilter) -> [(String, String, String)] {
        let name = platformName(platform)
        return quickViews.filter { name == "all" || $0.2 == name }
    }

    public static func apiQuery(_ p: ReportParams, platform: PlatformFilter) -> [String: String] {
        var q = p.picking(apiParams)
        q["platform"] = ReportScope.apiPlatform(platform)
        return q
    }

    public static func tri(_ v: JSONValue, _ yes: String = "Yes", _ no: String = "No") -> String {
        ReportLabels.tri(v).map { $0 ? yes : no } ?? "Unknown"
    }

    static func num(_ v: JSONValue, _ unit: String = "") -> String { v.int.map { "\($0)\(unit)" } ?? "Unknown" }

    /// A column's display text, also its sort key and CSV value. nil when the column does not apply to the device's platform.
    public static func text(_ d: PostureDevice, _ column: String) -> String? {
        let r = d.reported
        if let scope = columnScopes.first(where: { $0.0 == column })?.2, scope != "all", scope != d.device.platform { return nil }
        switch column {
        case "deviceName": return d.device.displayName
        case "platform": return d.device.platform
        case "inventoryState": return ReportLabels.inventory(d.device.inventoryState)
        case "laps":
            switch r["laps"].string {
            case "configured": return r["lapsBackupDirectory"].nonEmptyString.map { "Configured (\($0))" } ?? "Configured"
            case "not_configured": return "Not configured"
            default: return "Unknown"
            }
        case "autoLogin":
            if ReportLabels.tri(r["autoLogin"]) == true { return ReportLabels.tri(r["autoLoginStoredPassword"]) == true ? "On, stored password" : "On" }
            return tri(r["autoLogin"], "On", "Off")
        case "uac":
            if ReportLabels.tri(r["uacEnabled"]) == false { return "Off" }
            return r["uacLevel"].nonEmptyString ?? (ReportLabels.tri(r["uacEnabled"]) == true ? "On" : "Unknown")
        case "passwordPolicy":
            return "Min length \(num(r["minPasswordLength"])) · Lockout after \(num(r["lockoutThreshold"])) for \(num(r["lockoutDurationMinutes"], " min"))"
        case "hello":
            let providers: String
            if let list = r["helloProviders"].array { providers = list.isEmpty ? "No providers" : list.compactMap(\.nonEmptyString).joined(separator: ", ") } else { providers = "Providers unknown" }
            return "\(r["helloStatus"].nonEmptyString ?? "Status unknown") · \(providers)"
        case "credentialGuard": return tri(r["credentialGuard"], "On", "Off")
        case "tpm":
            if ReportLabels.tri(r["tpmOwned"]) == true { return ReportLabels.tri(r["tpmReady"]) == false ? "Owned, not ready" : "Owned" }
            return tri(r["tpmOwned"], "Owned", "Not owned")
        case "failedLogins": return num(r["failedLoginsLast7Days"])
        case "psso":
            return ["valid": "Registered, tokens valid", "expired": "Token expired", "not_registered": "Not registered",
                    "no_registered_users": "Device registered, no users"][r["pssoState"].string ?? ""] ?? "Unknown"
        case "secureToken":
            guard let g = r["secureTokenGranted"].int else { return "Unknown" }
            return "\(g) granted · \(num(r["secureTokenMissing"])) missing"
        case "bootstrapToken": return tri(r["bootstrapTokenEscrowed"], "Escrowed", "Not escrowed")
        case "activationLock":
            return ["on": "On", "likely": "Likely on (inferred from Find My)", "off": "Off"][r["activationLock"].string ?? ""] ?? "Unknown"
        case "findMy": return tri(r["findMy"], "On", "Off")
        case "recoveryKey":
            switch r["recoveryKey"].string {
            case "present":
                return [ReportLabels.tri(r["personalRecoveryKey"]) == true ? "Personal" : nil, ReportLabels.tri(r["institutionalRecoveryKey"]) == true ? "Institutional" : nil].compactMap { $0 }.joined(separator: " + ")
            case "none": return "None on device"
            case "filevault_off": return "FileVault off"
            default: return "Unknown"
            }
        case "identityCollectedAt": return d.identityCollectedAt
        case "securityCollectedAt": return d.securityCollectedAt
        case "lastSeen": return d.device.lastSeen
        default: return nil
        }
    }

    static let timeColumns = ["identityCollectedAt", "securityCollectedAt", "lastSeen"]

    public static let columns: [ReportColumn<PostureDevice>] = columnScopes.map { key, label, _ in
        let isTime = timeColumns.contains(key)
        return ReportColumn(key, label, kind: key == "deviceName" ? .device : isTime ? .time : .text, missing: "Not applicable",
                            value: { d in
                                let t = text(d, key)
                                if isTime, t == nil, key != "securityCollectedAt" || d.isMac { return "Unknown" }
                                return t
                            },
                            sortKey: { d in
                                if isTime { return ReportSortKey.time(text(d, key)) }
                                if key == "failedLogins" { return d.reported["failedLoginsLast7Days"].int.map { .number(Double($0)) } }
                                let t = text(d, key)
                                return t == "Unknown" ? nil : ReportSortKey.string(t)
                            },
                            detail: { d in
                                switch key {
                                case "deviceName": return d.unreadable ? "Collected data could not be read" : nil
                                case "identityCollectedAt": return d.identityCollectedAt == nil ? nil : d.identityFreshness.label
                                case "securityCollectedAt": return d.isMac && d.securityCollectedAt != nil ? d.securityFreshness.label : nil
                                case "psso":
                                    let users = d.reported["pssoUsers"].elements.map { u in
                                        let token = u["token"].string == "expired" ? "expired" : u["token"].string == "valid" ? "valid" : "token unknown"
                                        return "\(u["username"].nonEmptyString ?? "Unknown user"): \(token)"
                                    }
                                    return users.isEmpty ? nil : users.joined(separator: "\n")
                                default: return nil
                                }
                            })
    }

    public static let csvPostureKeys = columnScopes.map(\.0).filter { !["deviceName", "platform", "inventoryState", "identityCollectedAt", "securityCollectedAt", "lastSeen"].contains($0) }

    public static var csvHeaders: [String] {
        ["Device Name", "Computer Name", "Serial Number", "Asset Tag", "Platform", "Inventory State", "Archived in ReportMate",
         "Usage", "Catalog", "Area", "Fleet", "Location", "Room"]
            + csvPostureKeys.map { k in columnScopes.first { $0.0 == k }!.1 }
            + ["Platform SSO Users"] + quickViews.map { "Quick View: \($0.1)" }
            + ["Identity Collection Time", "Identity Collection Freshness", "Security Collection Time", "Security Collection Freshness",
               "Last Seen", "Report Generated At", "Report URL"]
    }

    public static func csvRows(_ devices: [PostureDevice], generatedAt: String, reportURL: String) -> [[String?]] {
        devices.map { d in
            let v = d.device
            let users = d.reported["pssoUsers"].elements.map { u in
                "\(u["username"].nonEmptyString ?? "Unknown user"): \(u["token"].string ?? "unknown")\(u["tokenExpiration"].nonEmptyString.map { " (expires \($0))" } ?? "")"
            }.joined(separator: "\n")
            let base: [String?] = [v.deviceName, d.computerName, v.serialNumber, v.assetTag, v.platform, ReportLabels.inventory(v.inventoryState), v.archived ? "Yes" : "No",
                                   v.usage, v.catalog, v.area, v.fleet, v.location, v.room]
            let posture: [String?] = csvPostureKeys.map { text(d, $0) ?? "Not applicable" }
            let quick: [String?] = quickViews.map { key, _, platform in
                platform != v.platform ? "Not applicable" : ((d.checks[key] ?? nil).map { $0 ? "Yes" : "No" } ?? "Unknown")
            }
            let times: [String?] = [d.identityCollectedAt, d.identityFreshness.rawValue, d.securityCollectedAt, d.securityFreshness.rawValue, v.lastSeen, generatedAt, reportURL]
            return base + posture + [users] + quick + times
        }
    }
}
