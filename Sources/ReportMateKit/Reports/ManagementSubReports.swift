import Foundation

// Management › Configuration Profiles and Managed Preferences, and the enrollment
// health columns on Device Management Service: ports of the web's
// `src/lib/management/{profiles,enrollment-health}.ts`.

// MARK: - Profiles and preferences

public enum ProfileKind: String, Sendable, Hashable, CaseIterable {
    case profile, preference
    public var tab: String { self == .preference ? "preferences" : "profiles" }
    public var noun: String { self == .preference ? "managed preferences" : "configuration profiles" }
}

public struct ProfileCatalog: Sendable, Hashable {
    public struct Option: Sendable, Hashable, Identifiable {
        public var identifier: String; public var name: String; public var devices: Int; public var platforms: [String]; public var keys: [String]
        public var id: String { identifier }
    }
    public var profiles: [Option]
    public var preferences: [Option]
    public var options: ReportScopeOptions

    public init?(json: JSONValue) {
        guard let p = json["profiles"].array, let m = json["preferences"].array else { return nil }
        func parse(_ j: JSONValue) -> Option? {
            guard let id = j["identifier"].nonEmptyString else { return nil }
            return Option(identifier: id, name: j["name"].nonEmptyString ?? id, devices: j["devices"].int ?? 0,
                          platforms: j["platforms"].elements.compactMap(\.nonEmptyString), keys: j["keys"].elements.compactMap(\.nonEmptyString))
        }
        profiles = p.compactMap(parse)
        preferences = m.compactMap(parse)
        options = ReportScopeOptions(json: json["options"])
    }

    public func options(for kind: ProfileKind, platform: PlatformFilter) -> [Option] {
        let all = kind == .preference ? preferences : profiles
        guard platform != .all else { return all }
        let want = platform == .macOS ? "macos" : "windows"
        return all.filter { $0.platforms.isEmpty || $0.platforms.contains { $0.lowercased() == want } }
    }
}

public struct ProfileRow: Sendable, Hashable, Identifiable {
    public struct Value: Sendable, Hashable { public var scope: String?; public var value: String? }
    public var device: ReportDevice
    public var freshness: ReportFreshness
    public var inventoryCount: Int
    public var state: String
    public var identifier: String
    public var name: String
    public var scope: String?
    public var user: String?
    public var uuid: String?
    public var version: String?
    public var organization: String?
    public var installDate: String?
    public var source: String?
    public var status: String?
    public var verificationState: String?
    public var removalDisallowed: Bool?
    public var payloadCount: Int?
    public var settingCount: Int?
    /// nil when no preference key was asked for; empty when the key is not set.
    public var values: [Value]?
    public var index: Int
    public var id: Int { index }

    public init(json j: JSONValue, index: Int) {
        device = ReportDevice(json: j)
        freshness = ReportFreshness(j["freshness"])
        inventoryCount = j["inventoryCount"].int ?? 0
        state = j["state"].nonEmptyString ?? "unknown"
        identifier = j["identifier"].nonEmptyString ?? ""
        name = j["name"].nonEmptyString ?? identifier
        scope = j["scope"].nonEmptyString
        user = j["user"].nonEmptyString
        uuid = j["uuid"].nonEmptyString
        version = j["version"].nonEmptyString
        organization = j["organization"].nonEmptyString
        installDate = j["installDate"].nonEmptyString
        source = j["source"].nonEmptyString
        status = j["status"].nonEmptyString
        verificationState = j["verificationState"].nonEmptyString
        removalDisallowed = j["removalDisallowed"].bool
        payloadCount = j["payloadCount"].int
        settingCount = j["settingCount"].int
        values = j["values"].array.map { $0.map { Value(scope: $0["scope"].nonEmptyString, value: ReportLabels.text($0["value"])) } }
        self.index = index
    }
}

public struct ProfilesReportData: Sendable, Hashable {
    public var generatedAt: String
    public var kind: ProfileKind
    public var total: Int
    public var summary: [String: Int]
    public var rows: [ProfileRow]
    public init(envelope e: JSONValue, rows: [JSONValue]) {
        generatedAt = e["generatedAt"].nonEmptyString ?? ""
        kind = ProfileKind(rawValue: e["kind"].string ?? "") ?? .profile
        total = e["total"].int ?? rows.count
        summary = (e["summary"].object ?? [:]).compactMapValues(\.int)
        self.rows = rows.enumerated().map { ProfileRow(json: $1, index: $0) }
    }
}

public enum ProfilesReportSpec {
    public static let api = "/management/profiles"
    public static let pageSize = 2000
    public static let maxSelections = 50
    public static let states = ["installed", "missing", "unknown"]
    public static let apiParams = ["identifiers", "preferenceKey", "states", "freshness", "maxAgeHours"] + ReportScope.keys + ["includeArchived"]
    public static let viewParams = ["sort", "direction"]

    public static func stateLabel(_ s: String) -> String { s == "installed" ? "Installed" : s == "missing" ? "Not installed" : "Unknown" }
    public static func scopeLabel(_ s: String?) -> String {
        switch s {
        case "system": return "System"
        case "user": return "User"
        case "system+user": return "System and user"
        default: return "Unknown"
        }
    }

    public static func identifiers(_ p: ReportParams) -> [String] { Array(p.jsonList("identifiers").prefix(maxSelections)) }

    public static func apiQuery(_ p: ReportParams, kind: ProfileKind, platform: PlatformFilter) -> [String: String]? {
        guard !identifiers(p).isEmpty else { return nil }
        var q = p.picking(apiParams)
        if kind != .preference { q["preferenceKey"] = nil }
        q["kind"] = kind.rawValue
        q["platform"] = ReportScope.apiPlatform(platform)
        return q
    }

    public static func optionsQuery(_ p: ReportParams, platform: PlatformFilter) -> [String: String] {
        var q = p.picking(ReportScope.keys + ["includeArchived"])
        q["platform"] = ReportScope.apiPlatform(platform)
        return q
    }

    public static func columns(kind: ProfileKind) -> [ReportColumn<ProfileRow>] {
        let preference = kind == .preference
        return [
            ReportColumn("deviceName", "Device", kind: .device, value: { $0.device.displayName }),
            ReportColumn("state", "State", kind: .state, value: { stateLabel($0.state) },
                         sortKey: { .number(Double(states.firstIndex(of: $0.state) ?? 3)) },
                         detail: { r in r.state == "unknown" ? (r.inventoryCount == 0 ? "No management inventory reported" : "Collection older than maximum age") : nil }),
            ReportColumn("name", preference ? "Domain" : "Profile", value: { $0.name }, detail: { r in
                var lines: [String] = []
                if r.identifier != r.name { lines.append(r.identifier) }
                if let o = r.organization { lines.append(o) }
                if preference, let values = r.values {
                    lines.append(values.isEmpty ? "Key not set in this domain" : values.map { "\($0.scope ?? "Unknown scope"): \($0.value ?? "")" }.joined(separator: "\n"))
                }
                return lines.isEmpty ? nil : lines.joined(separator: "\n")
            }),
            ReportColumn("scope", "Scope", missing: "Not applicable", value: { $0.scope.map(scopeLabel) }, detail: { $0.user }),
            preference
                ? ReportColumn("version", "Settings", missing: "Unknown", value: { $0.settingCount.map { "\($0) settings" } }, sortKey: { $0.settingCount.map { .number(Double($0)) } })
                : ReportColumn("version", "Version", value: { $0.version }, detail: { r in [r.uuid, r.verificationState].compactMap { $0 }.joined(separator: "\n").nilIfEmpty }),
            ReportColumn("installDate", "Installed", kind: .time, missing: preference ? "Not reported" : "Not applicable",
                         value: { r in !preference && r.state == "installed" ? (r.installDate ?? "Unknown") : nil },
                         sortKey: { ReportSortKey.time($0.installDate) }),
            ReportColumn("inventoryState", "Inventory", value: { $0.device.inventoryLabel },
                         detail: { r in [r.device.catalog, r.device.usage, r.device.room].compactMap { $0 }.joined(separator: " · ").nilIfEmpty }),
            ReportColumn("collectedAt", "Collected", kind: .time, value: { $0.device.collectedAt }, detail: { $0.freshness.label }),
        ]
    }

    public static func csvHeaders(kind: ProfileKind) -> [String] {
        ["Device Name", "Serial Number", "Asset Tag", "Platform", "Inventory State", "Archived in ReportMate",
         "Usage", "Catalog", "Area", "Fleet", "Location", "Room",
         kind == .preference ? "Preference Domain" : "Profile Identifier", kind == .preference ? "Domain" : "Profile Name",
         "State", "Scope", "User",
         "Version", "UUID", "Organization", "Install Date", "Source", "Status", "Verification", "Removal Disallowed", "Payload Count",
         "Setting Count", "Preference Values",
         "Management Collection Time", "Collection Freshness", "Last Seen", "Report Generated At", "Report URL"]
    }

    public static func csvRows(_ rows: [ProfileRow], generatedAt: String, reportURL: String) -> [[String?]] {
        rows.map { r in
            let v = r.device
            return [v.deviceName, v.serialNumber, v.assetTag, v.platform, ReportLabels.inventory(v.inventoryState), v.archived ? "Yes" : "No",
                    v.usage, v.catalog, v.area, v.fleet, v.location, v.room,
                    r.identifier, r.name, stateLabel(r.state), r.scope.map(scopeLabel) ?? "", r.user,
                    r.version, r.uuid, r.organization, r.installDate, r.source, r.status, r.verificationState,
                    r.removalDisallowed.map { $0 ? "Yes" : "No" } ?? "", r.payloadCount.map(String.init),
                    r.settingCount.map(String.init), (r.values ?? []).map { "\($0.scope ?? "Unknown scope"): \($0.value ?? "")" }.joined(separator: "\n"),
                    v.collectedAt, r.freshness.rawValue, v.lastSeen, generatedAt, reportURL]
        }
    }
}

// MARK: - Enrollment health

/// Compliance, last MDM sync, MDM certificate expiry and the macOS Apple MDM flags of
/// one `/management` row. A value the device did not collect reads as unknown, never
/// as healthy, and never matches a problem filter.
public struct EnrollmentHealth: Sendable, Hashable {
    public var complianceState: String?
    public var complianceSource: String?
    public var lastMdmSync: String?
    public var mdmCertificateExpires: String?
    public var userApprovedMdm: Bool?
    public var installedFromDep: Bool?
    public var depCapable: Bool?
    public var platform: String?

    public init(json: JSONValue) {
        let c = json["complianceState"].nonEmptyString
        complianceState = c == "compliant" || c == "non_compliant" ? c : nil
        complianceSource = json["complianceSource"].nonEmptyString
        lastMdmSync = json["lastMdmSync"].nonEmptyString
        mdmCertificateExpires = json["mdmCertificateExpires"].nonEmptyString
        userApprovedMdm = json["userApprovedMdm"].bool
        installedFromDep = json["installedFromDep"].bool ?? json["adeInstalled"].bool
        depCapable = json["depCapable"].bool
        platform = json.firstString("platform", "osName")
    }

    public var isMac: Bool { (platform ?? "").range(of: "mac|darwin", options: [.regularExpression, .caseInsensitive]) != nil }

    public var complianceLabel: String { complianceState == "compliant" ? "Compliant" : complianceState == "non_compliant" ? "Not compliant" : "Unknown" }

    /// Days since the last MDM sync; nil when unknown or in the future.
    public func syncAgeDays(now: Date = Date()) -> Double? {
        guard let t = FlexibleDate.parse(lastMdmSync), t <= now else { return nil }
        return now.timeIntervalSince(t) / 86400
    }

    /// Days until the MDM certificate expires (negative once expired); nil when unknown.
    public func certificateDaysLeft(now: Date = Date()) -> Double? {
        FlexibleDate.parse(mdmCertificateExpires).map { $0.timeIntervalSince(now) / 86400 }
    }

    /// Apple MDM flags apply to macOS only: Windows reads "Not applicable", a missing Mac value "Unknown".
    public func appleFlag(_ value: Bool?) -> String {
        guard isMac else { return "Not applicable" }
        return value.map { $0 ? "Yes" : "No" } ?? "Unknown"
    }

    public static func days(_ n: Double) -> String {
        let whole = Int(abs(n).rounded(.down))
        return whole == 1 ? "1 day" : "\(whole) days"
    }

    public func syncText(now: Date = Date()) -> String {
        guard let age = syncAgeDays(now: now) else { return "Unknown" }
        return age < 1 ? "Today" : "\(Self.days(age)) ago"
    }

    public func certificateText(now: Date = Date()) -> String {
        guard let left = certificateDaysLeft(now: now) else { return "Unknown" }
        return left < 0 ? "Expired \(Self.days(left)) ago" : "Expires in \(Self.days(left))"
    }

    public static let csvHeaders = ["Compliance", "Compliance Source", "Last MDM Sync", "MDM Certificate Expires", "User-Approved MDM", "Installed via ADE", "DEP Capable"]

    public var csvValues: [String] {
        [complianceLabel,
         complianceSource == "reported" ? "Reported by device" : complianceSource == "policies" ? "Evaluated policies" : "",
         lastMdmSync ?? "Unknown", mdmCertificateExpires ?? "Unknown",
         appleFlag(userApprovedMdm), appleFlag(installedFromDep), appleFlag(depCapable)]
    }
}

/// The enrollment health problem filters: `compliance=non_compliant`, `syncOlderThan=<days>`, `certExpiring=<days>`.
public struct EnrollmentHealthFilters: Sendable, Hashable {
    public static let params = ["compliance", "syncOlderThan", "certExpiring"]
    public static let syncAgeChoices = [1, 7, 30]
    public static let certificateExpiryDays = 30

    public var nonCompliant = false
    public var syncOlderThanDays: Int?
    public var certExpiringDays: Int?

    public init(nonCompliant: Bool = false, syncOlderThanDays: Int? = nil, certExpiringDays: Int? = nil) {
        self.nonCompliant = nonCompliant
        self.syncOlderThanDays = syncOlderThanDays
        self.certExpiringDays = certExpiringDays
    }

    private static func positive(_ s: String?) -> Int? {
        guard let s, s.allSatisfy(\.isNumber), let n = Int(s), n > 0, n <= 3650 else { return nil }
        return n
    }

    public init(query: [String: String]) {
        nonCompliant = query["compliance"] == "non_compliant"
        syncOlderThanDays = Self.positive(query["syncOlderThan"])
        certExpiringDays = Self.positive(query["certExpiring"])
    }

    public var query: [String: String] {
        var q: [String: String] = [:]
        if nonCompliant { q["compliance"] = "non_compliant" }
        if let syncOlderThanDays { q["syncOlderThan"] = String(syncOlderThanDays) }
        if let certExpiringDays { q["certExpiring"] = String(certExpiringDays) }
        return q
    }

    public var count: Int { (nonCompliant ? 1 : 0) + (syncOlderThanDays == nil ? 0 : 1) + (certExpiringDays == nil ? 0 : 1) }

    public func matches(_ h: EnrollmentHealth, now: Date = Date()) -> Bool {
        if nonCompliant, h.complianceState != "non_compliant" { return false }
        if let days = syncOlderThanDays {
            guard let age = h.syncAgeDays(now: now), age > Double(days) else { return false }
        }
        if let days = certExpiringDays {
            guard let left = h.certificateDaysLeft(now: now), left <= Double(days) else { return false }
        }
        return true
    }

    public var labels: [String] {
        [nonCompliant ? "Not compliant" : nil,
         syncOlderThanDays.map { "MDM sync older than \($0 == 1 ? "1 day" : "\($0) days")" },
         certExpiringDays.map { "MDM certificate expiring within \($0) days" }].compactMap { $0 }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
