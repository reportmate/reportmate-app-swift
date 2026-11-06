import Foundation

// System › Services, Updates, Background and Extensions: ports of the web's
// `src/lib/system/{services,services-view,services-export,updates,item-reports,
// background,extensions}.ts`, over `/api/v1/system/<report>[/filters]`.

// MARK: - Services

public struct ServiceCatalog: Sendable, Hashable {
    public struct Service: Sendable, Hashable { public var name: String; public var displayName: String?; public var devices: Int; public var startups: [String] }
    public struct Application: Sendable, Hashable { public var name: String; public var devices: Int; public var versions: [String] }
    public var services: [Service]
    public var applications: [Application]
    public var options: ReportScopeOptions

    /// nil when the body is not a service catalog.
    public init?(json: JSONValue) {
        guard let s = json["services"].array, let a = json["applications"].array else { return nil }
        services = s.compactMap { j in j["name"].nonEmptyString.map { Service(name: $0, displayName: j["displayName"].nonEmptyString, devices: j["devices"].int ?? 0, startups: j["startups"].elements.compactMap(\.nonEmptyString)) } }
        applications = a.compactMap { j in j["name"].nonEmptyString.map { Application(name: $0, devices: j["devices"].int ?? 0, versions: j["versions"].elements.compactMap(\.nonEmptyString)) } }
        options = ReportScopeOptions(json: json["options"])
    }
}

public struct ServiceDevice: Sendable, Hashable, Identifiable {
    public struct Entry: Sendable, Hashable { public var name: String?; public var displayName: String?; public var status: String?; public var startType: String?; public var path: String? }
    public struct App: Sendable, Hashable { public var name: String; public var version: String?; public var path: String? }
    public var device: ReportDevice
    public var services: [Entry]
    public var applications: [App]
    public var state: String
    public var reportedState: String
    public var freshness: ReportFreshness
    public var applicationsFreshness: ReportFreshness
    public var applicationsCollectedAt: String?
    /// The report's snapshot time, for check-in age.
    public var generatedAt: String
    public var id: String { device.serialNumber }

    public init(json: JSONValue, generatedAt: String) {
        device = ReportDevice(json: json)
        services = json["services"].elements.map { Entry(name: $0["name"].nonEmptyString, displayName: $0["displayName"].nonEmptyString, status: $0["status"].nonEmptyString, startType: $0["startType"].nonEmptyString, path: $0["path"].nonEmptyString) }
        applications = json["applications"].elements.compactMap { j in j["name"].nonEmptyString.map { App(name: $0, version: j["version"].nonEmptyString, path: j["path"].nonEmptyString) } }
        state = json["state"].nonEmptyString ?? "unknown"
        reportedState = json["reportedState"].nonEmptyString ?? "unknown"
        freshness = ReportFreshness(json["freshness"])
        applicationsFreshness = ReportFreshness(json["applicationsFreshness"])
        applicationsCollectedAt = json["applicationsCollectedAt"].nonEmptyString
        self.generatedAt = generatedAt
    }

    /// Hours since the device last checked in, at the report snapshot; nil when unknown or in the future.
    public var checkinAgeHours: Double? { ServicesReportSpec.checkinAgeHours(device.lastSeen, generatedAt: generatedAt) }
}

public struct ServicesReportData: Sendable, Hashable {
    public var generatedAt: String
    public var total: Int
    public var summary: [String: Int]
    public var options: ReportScopeOptions
    public var devices: [ServiceDevice]

    public init(envelope: JSONValue, rows: [JSONValue]) {
        generatedAt = envelope["generatedAt"].nonEmptyString ?? ""
        total = envelope["total"].int ?? rows.count
        summary = (envelope["summary"].object ?? [:]).compactMapValues(\.int)
        options = ReportScopeOptions(json: envelope["options"])
        devices = rows.map { ServiceDevice(json: $0, generatedAt: envelope["generatedAt"].nonEmptyString ?? "") }
    }
}

public enum ServicesReportSpec {
    public static let api = "/system/services"
    public static let states = ["running", "stopped", "mixed", "missing", "unknown"]
    public static let apiParams = ["service", "application", "serviceNames", "applicationNames", "versions", "states", "startups", "freshness", "maxAgeHours"] + ReportScope.keys + ["includeArchived"]
    public static let viewParams = ["evidence", "checkin", "checkinAgeHours", "sort", "direction", "columns"]
    public static let evidenceChoices: [(String, String)] = [("all", "All devices"), ("any", "Any matching evidence"), ("services", "Matching services"), ("applications", "Matching applications"), ("none", "No matching evidence")]
    public static let checkinChoices: [(String, String)] = [("all", "All"), ("recent", "Within maximum age"), ("stale", "Older"), ("unknown", "Unknown")]
    public static let defaultColumns = ["deviceName", "state", "services", "applications", "inventoryState", "collectedAt", "lastSeen"]

    public static func stateLabel(_ value: String) -> String {
        switch value {
        case "missing": return "Not found"
        case "unknown": return "Unknown"
        default: return value.prefix(1).uppercased() + value.dropFirst()
        }
    }

    public static func selectedServices(_ p: ReportParams, catalog: ServiceCatalog?) -> [String] {
        if p.has("serviceNames") { return p.jsonList("serviceNames", commaFallback: true) }
        guard let q = p["service"]?.lowercased() else { return [] }
        return (catalog?.services ?? []).filter { "\($0.name) \($0.displayName ?? "")".lowercased().contains(q) }.map(\.name)
    }

    public static func selectedApplications(_ p: ReportParams, catalog: ServiceCatalog?) -> [String] {
        if p.has("applicationNames") { return p.jsonList("applicationNames", commaFallback: true) }
        guard let q = p["application"]?.lowercased() else { return [] }
        return (catalog?.applications ?? []).filter { $0.name.lowercased().contains(q) }.map(\.name)
    }

    public static func hasQuery(_ p: ReportParams) -> Bool { p.has("serviceNames") || p.has("service") }
    public static func hasApplication(_ p: ReportParams) -> Bool { p.has("applicationNames") || p.has("application") }

    /// The API request, or nil while no service is chosen.
    public static func apiQuery(_ p: ReportParams, platform: PlatformFilter) -> [String: String]? {
        guard hasQuery(p) else { return nil }
        var q = p.picking(apiParams)
        q["platform"] = ReportScope.apiPlatform(platform)
        return q
    }

    public static func optionsQuery(_ p: ReportParams, platform: PlatformFilter) -> [String: String] {
        var q = p.picking(ReportScope.keys + ["includeArchived"])
        q["platform"] = ReportScope.apiPlatform(platform)
        return q
    }

    public static func checkinAgeHours(_ lastSeen: String?, generatedAt: String) -> Double? {
        guard let seen = FlexibleDate.parse(lastSeen), let snap = FlexibleDate.parse(generatedAt), seen <= snap else { return nil }
        return snap.timeIntervalSince(seen) / 3600
    }

    public static func checkinState(_ age: Double?, maximumHours: Int) -> String {
        guard let age else { return "unknown" }
        return age <= Double(maximumHours) ? "recent" : "stale"
    }

    public static func evidence(_ p: ReportParams) -> String {
        let e = evidenceChoices.first { $0.0 == p["evidence"] }?.0 ?? "all"
        return e == "applications" && !hasApplication(p) ? "all" : e
    }
    public static func checkin(_ p: ReportParams) -> String { checkinChoices.first { $0.0 == p["checkin"] }?.0 ?? "all" }
    public static func checkinMaximum(_ p: ReportParams) -> Int {
        guard let h = Int(p["checkinAgeHours"] ?? ""), h > 0 else { return 168 }
        return min(h, 87600)
    }

    public static func matchesEvidence(_ d: ServiceDevice, _ evidence: String) -> Bool {
        switch evidence {
        case "any": return !d.services.isEmpty || !d.applications.isEmpty
        case "services": return !d.services.isEmpty
        case "applications": return !d.applications.isEmpty
        case "none": return d.services.isEmpty && d.applications.isEmpty
        default: return true
        }
    }

    /// The visible rows: evidence, check-in and the device search, without refetching.
    public static func filter(_ devices: [ServiceDevice], params p: ReportParams) -> [ServiceDevice] {
        let evidence = evidence(p), checkin = checkin(p), max = checkinMaximum(p), search = p["search"] ?? ""
        return devices.filter { d in
            matchesEvidence(d, evidence) && (checkin == "all" || checkinState(d.checkinAgeHours, maximumHours: max) == checkin) && d.device.matches(search)
        }
    }

    private static func when(_ s: String?) -> String? { s }

    public static func columns(hasApplication: Bool) -> [ReportColumn<ServiceDevice>] {
        var cols: [ReportColumn<ServiceDevice>] = [
            ReportColumn("deviceName", "Device", kind: .device, value: { $0.device.displayName }),
            ReportColumn("serialNumber", "Serial number", kind: .mono, value: { $0.device.serialNumber }),
            ReportColumn("assetTag", "Asset tag", value: { $0.device.assetTag }),
            ReportColumn("platform", "Platform", value: { $0.device.platform }),
            ReportColumn("state", "Service state", kind: .state, value: { stateLabel($0.state) },
                         detail: { $0.state == "unknown" && $0.reportedState != "unknown" ? "Last reported: \(stateLabel($0.reportedState))" : nil }),
            ReportColumn("services", "Matching services", value: { d in
                let s = d.services.map { e in "\(e.displayName ?? e.name ?? "Unknown")\(e.status.map { ": \($0)" } ?? "")" }.joined(separator: "\n")
                return s.isEmpty ? nil : s
            }, sortKey: { ReportSortKey.string($0.services.map { $0.name ?? $0.displayName ?? "" }.sorted().joined(separator: "; ")) }),
            ReportColumn("applications", "Application versions", value: { d in
                let s = d.applications.map { "\($0.name) \($0.version ?? "Version not reported")" }.joined(separator: "\n")
                return s.isEmpty ? nil : s
            }),
            ReportColumn("inventoryState", "Inventory", value: { $0.device.inventoryLabel }),
            ReportColumn("usage", "Usage", value: { $0.device.usage }),
            ReportColumn("catalog", "Catalog", value: { $0.device.catalog }),
            ReportColumn("area", "Area", value: { $0.device.area }),
            ReportColumn("fleet", "Fleet", value: { $0.device.fleet }),
            ReportColumn("location", "Location", value: { $0.device.location }),
            ReportColumn("room", "Room", value: { $0.device.room }),
            ReportColumn("collectedAt", "Service collection", kind: .time, value: { $0.device.collectedAt }, detail: { $0.freshness.label }),
            ReportColumn("applicationsCollectedAt", "Application collection", kind: .time, value: { $0.applicationsCollectedAt }, detail: { $0.applicationsFreshness.label }),
            ReportColumn("lastSeen", "Last seen", kind: .time, value: { $0.device.lastSeen }),
            ReportColumn("checkinAge", "Check-in age", kind: .number, missing: "Unknown", value: { d in d.checkinAgeHours.map { TimeFormatting.hours($0) } },
                         sortKey: { d in d.checkinAgeHours.map { .number($0) } }),
        ]
        if !hasApplication { cols.removeAll { $0.key == "applications" || $0.key == "applicationsCollectedAt" } }
        return cols
    }

    public static let csvHeaders = [
        "Device Name", "Hostname", "Serial Number", "Asset Tag", "Platform", "Inventory State", "Archived in ReportMate",
        "Usage", "Catalog", "Area", "Fleet", "Location", "Room", "Service State", "Last Reported Service State",
        "Matching Services", "Reported Service States", "Startup Types", "Executable Paths", "Application Versions",
        "Service Collection Time", "Service Collection Freshness", "Application Collection Time", "Application Collection Freshness",
        "Last Seen", "Report Generated At", "Report URL",
        "Matching Service Reported", "Matching Application Reported", "Application Paths",
        "ReportMate Check-in Age (Hours)", "ReportMate Check-in Freshness", "Maximum Check-in Age (Hours)",
    ]

    /// Every field for the filtered, sorted devices, as the web's `servicesCsv`.
    public static func csvRows(_ devices: [ServiceDevice], generatedAt: String, reportURL: String, maximumCheckinHours: Int) -> [[String?]] {
        devices.map { d in
            let v = d.device
            let name: (ServiceDevice.Entry) -> String = { $0.name ?? $0.displayName ?? "" }
            return [
                v.deviceName ?? v.serialNumber, v.hostname, v.serialNumber, v.assetTag, v.platform, ReportLabels.inventory(v.inventoryState), v.archived ? "Yes" : "No",
                v.usage, v.catalog, v.area, v.fleet, v.location, v.room, stateLabel(d.state), stateLabel(d.reportedState),
                d.services.map(name).joined(separator: "\n"),
                d.services.map { "\(name($0)): \($0.status ?? "Unknown")" }.joined(separator: "\n"),
                d.services.map { "\(name($0)): \($0.startType ?? "Unknown")" }.joined(separator: "\n"),
                d.services.map { "\(name($0)): \($0.path ?? "Not reported")" }.joined(separator: "\n"),
                d.applications.map { "\($0.name): \($0.version ?? "Version not reported")" }.joined(separator: "\n"),
                v.collectedAt, d.freshness.rawValue, d.applicationsCollectedAt, d.applicationsFreshness.rawValue,
                v.lastSeen, generatedAt, reportURL,
                d.services.isEmpty ? "No" : "Yes", d.applications.isEmpty ? "No" : "Yes",
                d.applications.map { "\($0.name): \($0.path ?? "Not reported")" }.joined(separator: "\n"),
                d.checkinAgeHours.map { String(format: "%.2f", $0) },
                checkinState(d.checkinAgeHours, maximumHours: maximumCheckinHours), String(maximumCheckinHours),
            ]
        }
    }
}

// MARK: - Updates

public struct UpdateCatalog: Sendable, Hashable {
    public struct Update: Sendable, Hashable {
        public var key: String; public var platform: String; public var kb: String?; public var title: String?
        public var category: String?; public var isSecurity: Bool; public var pendingDevices: Int; public var installedDevices: Int; public var cves: [String]
        public var label: String {
            let t = title ?? kb ?? key
            if let kb, !t.contains(kb) { return "\(kb) \(t)" }
            return t
        }
    }
    public var updates: [Update]
    public var cves: [ReportChoice]
    public var options: ReportScopeOptions

    public init?(json: JSONValue) {
        guard let u = json["updates"].array, let c = json["cves"].array else { return nil }
        updates = u.compactMap { j in j["key"].nonEmptyString.map {
            Update(key: $0, platform: j["platform"].nonEmptyString ?? "", kb: j["kb"].nonEmptyString, title: j["title"].nonEmptyString, category: j["category"].nonEmptyString,
                   isSecurity: j["isSecurity"].bool ?? false, pendingDevices: j["pendingDevices"].int ?? 0, installedDevices: j["installedDevices"].int ?? 0,
                   cves: j["cves"].elements.compactMap(\.nonEmptyString))
        } }
        cves = c.compactMap { j in j["cve"].nonEmptyString.map { ReportChoice(value: $0, label: $0, devices: j["devices"].int) } }
        options = ReportScopeOptions(json: json["options"])
    }
}

public struct UpdateRow: Sendable, Hashable, Identifiable {
    public var device: ReportDevice
    public var osVersion: String?
    public var freshness: ReportFreshness
    public var collectionValid: Bool
    public var pendingCount: Int?
    public var updateKey: String?
    public var title: String?
    public var kb: String?
    public var productKey: String?
    public var category: String?
    public var severity: String?
    public var cves: [String]
    public var isSecurity: Bool?
    public var mandatory: Bool?
    public var downloaded: Bool?
    public var rebootRequired: Bool?
    public var deferred: Bool?
    public var deferredUntil: String?
    public var firstOfferedAt: String?
    public var releaseDate: String?
    public var installDate: String?
    public var version: String?
    public var buildVersion: String?
    public var updateType: String?
    public var ageDays: Int?
    public var ageSource: String?
    public var reportedState: String
    public var state: String
    public var id: String { "\(device.serialNumber)|\(updateKey ?? "")|\(reportedState)" }

    public init(json j: JSONValue) {
        device = ReportDevice(json: j)
        osVersion = j["osVersion"].nonEmptyString
        freshness = ReportFreshness(j["freshness"])
        collectionValid = j["collectionValid"].bool ?? false
        pendingCount = j["pendingCount"].int
        updateKey = j["updateKey"].nonEmptyString
        title = j["title"].nonEmptyString
        kb = j["kb"].nonEmptyString
        productKey = j["productKey"].nonEmptyString
        category = j["category"].nonEmptyString
        severity = j["severity"].nonEmptyString
        cves = j["cves"].elements.compactMap(\.nonEmptyString)
        isSecurity = j["isSecurity"].bool
        mandatory = j["mandatory"].bool
        downloaded = j["downloaded"].bool
        rebootRequired = j["rebootRequired"].bool
        deferred = j["deferred"].bool
        deferredUntil = j["deferredUntil"].nonEmptyString
        firstOfferedAt = j["firstOfferedAt"].nonEmptyString
        releaseDate = j["releaseDate"].nonEmptyString
        installDate = j["installDate"].nonEmptyString
        version = j["version"].nonEmptyString
        buildVersion = j["buildVersion"].nonEmptyString
        updateType = j["updateType"].nonEmptyString
        ageDays = j["ageDays"].int
        ageSource = j["ageSource"].nonEmptyString
        reportedState = j["reportedState"].nonEmptyString ?? "unknown"
        state = j["state"].nonEmptyString ?? "unknown"
    }

    public var flags: [String] {
        [isSecurity == true ? "Security" : nil, mandatory == true ? "Mandatory" : nil, downloaded == true ? "Downloaded" : nil,
         rebootRequired == true ? "Restart required" : nil, deferred == true ? "Deferred" : nil].compactMap { $0 }
    }
}

public struct UpdatesReportData: Sendable, Hashable {
    public var generatedAt: String
    public var total: Int
    public var summary: [String: Int]
    public var rows: [UpdateRow]
    public init(envelope: JSONValue, rows: [JSONValue]) {
        generatedAt = envelope["generatedAt"].nonEmptyString ?? ""
        total = envelope["total"].int ?? rows.count
        summary = (envelope["summary"].object ?? [:]).compactMapValues(\.int)
        self.rows = rows.map(UpdateRow.init(json:))
    }
}

public enum UpdatesReportSpec {
    public static let api = "/system/updates"
    public static let pageSize = 1000
    public static let states = ["pending", "installed", "not_reported", "none", "unknown"]
    public static let apiParams = ["updates", "cves", "states", "securityOnly", "deferred", "rebootRequired", "minAgeDays", "freshness", "maxAgeHours"] + ReportScope.keys + ["includeArchived"]
    public static let viewParams = ["sort", "direction", "columns"]
    public static let defaultColumns = ["deviceName", "state", "title", "category", "severity", "cves", "flags", "ageDays", "collectedAt"]

    public static func stateLabel(_ s: String) -> String {
        switch s {
        case "pending": return "Pending"
        case "installed": return "Installed"
        case "not_reported": return "Not reported"
        case "none": return "None pending reported"
        case "missing": return "No collection"
        default: return "Unknown"
        }
    }

    public static func hasSelection(_ p: ReportParams) -> Bool { !p.jsonList("updates", commaFallback: true).isEmpty || !p.jsonList("cves", commaFallback: true).isEmpty }

    /// The state choices: per-update states with a selection, the pending list otherwise.
    public static func stateChoices(_ p: ReportParams) -> [String] {
        hasSelection(p) ? states.filter { $0 != "none" } : states.filter { $0 != "installed" && $0 != "not_reported" }
    }

    public static func apiQuery(_ p: ReportParams, platform: PlatformFilter) -> [String: String] {
        var q = p.picking(apiParams)
        q["platform"] = ReportScope.apiPlatform(platform)
        return q
    }

    public static func optionsQuery(_ p: ReportParams, platform: PlatformFilter) -> [String: String] {
        var q = p.picking(["includeArchived"])
        q["platform"] = ReportScope.apiPlatform(platform)
        return q
    }

    public static let columns: [ReportColumn<UpdateRow>] = [
        ReportColumn("deviceName", "Device", kind: .device, value: { $0.device.displayName }),
        ReportColumn("serialNumber", "Serial number", kind: .mono, value: { $0.device.serialNumber }),
        ReportColumn("assetTag", "Asset tag", value: { $0.device.assetTag }),
        ReportColumn("platform", "Platform", value: { $0.device.platform }),
        ReportColumn("osVersion", "OS version", value: { $0.osVersion }),
        ReportColumn("state", "State", kind: .state, value: { stateLabel($0.state) },
                     detail: { r in r.state == "unknown" ? (!r.collectionValid ? "No valid update collection" : "Last reported: \(stateLabel(r.reportedState))") : nil }),
        ReportColumn("title", "Update", value: { r in
            guard r.updateKey != nil else {
                return r.state == "none" ? "Empty pending list reported" : r.state == "not_reported" ? "Selection not reported pending or installed" : "No update data"
            }
            return r.title ?? r.kb
        }, sortKey: { ReportSortKey.string($0.title ?? $0.kb) },
           detail: { r in let s = [r.kb, r.productKey, r.buildVersion].compactMap { $0 }.joined(separator: " · "); return r.updateKey == nil || s.isEmpty ? nil : s }),
        ReportColumn("category", "Category", value: { $0.category }),
        ReportColumn("severity", "Severity", value: { $0.severity }),
        ReportColumn("cves", "CVEs", kind: .mono, value: { $0.cves.isEmpty ? nil : $0.cves.joined(separator: " ") }),
        ReportColumn("flags", "Flags", value: { $0.flags.isEmpty ? nil : $0.flags.joined(separator: ", ") }),
        ReportColumn("version", "Version", value: { $0.version }),
        ReportColumn("ageDays", "Age (days)", kind: .number, value: { $0.ageDays.map(String.init) }, sortKey: { $0.ageDays.map { .number(Double($0)) } },
                     detail: { r in r.ageDays == nil ? nil : r.ageSource == "offered" ? "Since first offered" : "Since released" }),
        ReportColumn("deferredUntil", "Deferred until", kind: .time, missing: "-", value: { $0.deferredUntil }),
        ReportColumn("installDate", "Installed", kind: .time, missing: "-", value: { $0.installDate }),
        ReportColumn("inventoryState", "Inventory", value: { $0.device.inventoryLabel }),
        ReportColumn("usage", "Usage", value: { $0.device.usage }),
        ReportColumn("catalog", "Catalog", value: { $0.device.catalog }),
        ReportColumn("area", "Area", value: { $0.device.area }),
        ReportColumn("fleet", "Fleet", value: { $0.device.fleet }),
        ReportColumn("location", "Location", value: { $0.device.location }),
        ReportColumn("room", "Room", value: { $0.device.room }),
        ReportColumn("collectedAt", "Update collection", kind: .time, value: { $0.device.collectedAt }, detail: { $0.freshness.label }),
        ReportColumn("lastSeen", "Last seen", kind: .time, value: { $0.device.lastSeen }),
    ]

    public static let csvHeaders = [
        "Device Name", "Hostname", "Serial Number", "Asset Tag", "Platform", "OS Version", "Inventory State",
        "Archived in ReportMate", "Usage", "Catalog", "Area", "Fleet", "Location", "Room",
        "State", "Last Reported State", "Update", "KB", "Product Key", "Category", "Severity", "CVEs", "Security",
        "Mandatory", "Downloaded", "Restart Required", "Deferred", "Deferred Until", "First Offered", "Released",
        "Installed", "Version", "Build", "Update Type", "Age (Days)", "Age Measured From",
        "Pending Updates Reported", "Update Collection Valid", "Update Collection Time", "Update Collection Freshness",
        "Last Seen", "Report Generated At", "Report URL",
    ]

    public static func csvRows(_ rows: [UpdateRow], generatedAt: String, reportURL: String) -> [[String?]] {
        rows.map { r in
            let v = r.device
            let flag: (Bool?) -> String? = { r.updateKey == nil ? nil : ReportLabels.yesNo($0) }
            return [v.deviceName ?? v.serialNumber, v.hostname, v.serialNumber, v.assetTag, v.platform, r.osVersion, ReportLabels.inventory(v.inventoryState),
                    v.archived ? "Yes" : "No", v.usage, v.catalog, v.area, v.fleet, v.location, v.room,
                    stateLabel(r.state), stateLabel(r.reportedState), r.title, r.kb, r.productKey, r.category, r.severity, r.cves.joined(separator: " "),
                    flag(r.isSecurity), flag(r.mandatory), flag(r.downloaded), flag(r.rebootRequired), flag(r.deferred),
                    r.deferredUntil, r.firstOfferedAt, r.releaseDate, r.installDate, r.version, r.buildVersion, r.updateType,
                    r.ageDays.map(String.init), r.ageSource, r.pendingCount.map(String.init), r.collectionValid ? "Yes" : "No",
                    v.collectedAt, r.freshness.rawValue, v.lastSeen, generatedAt, reportURL]
        }
    }
}

// MARK: - Background items and extensions

public struct ItemCatalog: Sendable, Hashable {
    public struct Item: Sendable, Hashable { public var kind: String; public var key: String; public var label: String?; public var devices: Int
        public var value: String { "\(kind):\(key)" } }
    public var applicable: Bool?
    public var items: [Item]
    public var options: ReportScopeOptions
    public var team: [ReportChoice]

    public init?(json: JSONValue) {
        guard let items = json["items"].array else { return nil }
        applicable = json["applicable"].bool
        self.items = items.compactMap { j in
            guard let kind = j["kind"].nonEmptyString, let key = j["key"].nonEmptyString else { return nil }
            return Item(kind: kind, key: key, label: j["label"].nonEmptyString, devices: j["devices"].int ?? 0)
        }
        options = ReportScopeOptions(json: json["options"])
        team = json["team"].elements.compactMap { j in j["value"].nonEmptyString.map { ReportChoice(value: $0, label: $0, devices: j["devices"].int) } }
    }
}

public struct ItemRow: Sendable, Hashable, Identifiable {
    public var device: ReportDevice
    public var freshness: ReportFreshness
    public var kind: String
    public var key: String?
    public var name: String?
    /// The whole row, for the report-specific fields.
    public var json: JSONValue
    public var index: Int
    public var id: Int { index }

    public init(json: JSONValue, index: Int) {
        device = ReportDevice(json: json)
        freshness = ReportFreshness(json["freshness"])
        kind = json["kind"].nonEmptyString ?? "unknown"
        key = json["key"].nonEmptyString
        name = json["name"].nonEmptyString
        self.json = json
        self.index = index
    }

    public func text(_ field: String) -> String? { ReportLabels.text(json[field]) }
}

public struct ItemReportData: Sendable, Hashable {
    public var generatedAt: String
    public var queryRequired: Bool
    public var applicable: Bool?
    public var total: Int
    public var devicesInScope: Int?
    public var devicesWithoutInventory: Int?
    public var devicesReporting: Int?
    public var summary: [String: Int]
    public var rows: [ItemRow]

    public init(envelope e: JSONValue, rows: [JSONValue]) {
        generatedAt = e["generatedAt"].nonEmptyString ?? ""
        queryRequired = e["queryRequired"].bool ?? false
        applicable = e["applicable"].bool
        total = e["total"].int ?? rows.count
        devicesInScope = e["devicesInScope"].int
        devicesWithoutInventory = e["devicesWithoutInventory"].int
        devicesReporting = e["devicesReporting"].int
        summary = (e["summary"].object ?? [:]).compactMapValues(\.int)
        self.rows = rows.enumerated().map { ItemRow(json: $1, index: $0) }
    }
}

/// One choice filter on an item report (`enabled`, `lastRuns`, `activations`, …).
public struct ItemChoiceFilter: Sendable, Hashable {
    public var param: String
    public var label: String
    /// Prefix of the API summary counter for each choice (`lastRun:failed`).
    public var summaryKey: String?
    public var choices: [ReportChoice]
    /// Choices come from the catalog's collected team ids.
    public var fromTeamCatalog = false
}

/// Background or Extensions, described as data the way the web's `ItemReportConfig` is.
public struct ItemReportSpec: @unchecked Sendable {
    public var tab: String
    public var api: String
    public var csvName: String
    public var description: String
    public var footnote: String
    public var prompt: String
    public var kinds: [ReportChoice]
    public var filters: [ItemChoiceFilter]
    public var columns: [ReportColumn<ItemRow>]
    public var defaultColumns: [String]
    public var runsWithout: (ReportParams) -> Bool
    public var macOnly = false

    public static let pageSize = 2000
    public static let maxRows = 60000
    public static let viewParams = ["sort", "direction", "columns"]

    public var apiParams: [String] { ["items", "kinds"] + filters.map(\.param) + ["freshness", "maxAgeHours"] + ReportScope.keys + ["includeArchived"] }

    public func selectedItems(_ p: ReportParams) -> [String] { p.jsonList("items").filter { $0.contains(":") } }
    public func hasQuery(_ p: ReportParams) -> Bool { !selectedItems(p).isEmpty || runsWithout(p) }

    /// The API request, or nil while nothing is chosen (or the report does not apply).
    public func apiQuery(_ p: ReportParams, platform: PlatformFilter) -> [String: String]? {
        guard hasQuery(p), !(macOnly && platform == .windows) else { return nil }
        var q = p.picking(apiParams)
        q["platform"] = ReportScope.apiPlatform(platform)
        return q
    }

    public func optionsQuery(_ p: ReportParams, platform: PlatformFilter) -> [String: String] {
        var q = p.picking(ReportScope.keys + ["includeArchived"])
        q["platform"] = ReportScope.apiPlatform(platform)
        return q
    }

    public func kindLabel(_ kind: String) -> String { kinds.first { $0.value == kind }?.label ?? kind }

    public var csvHeaders: [String] { columns.map(\.label) + ["Hostname", "Asset Tag", "Area", "Fleet", "Location", "Report Generated At", "Report URL"] }

    public func csvRows(_ rows: [ItemRow], generatedAt: String, reportURL: String) -> [[String?]] {
        rows.map { r in columns.map { $0.value(r) } + [r.device.hostname, r.device.assetTag, r.device.area, r.device.fleet, r.device.location, generatedAt, reportURL] }
    }

    // Columns every item report starts and ends with.
    static let leading: [ReportColumn<ItemRow>] = [
        ReportColumn("deviceName", "Device", kind: .device, value: { $0.device.displayName }),
        ReportColumn("serialNumber", "Serial number", kind: .mono, value: { $0.device.serialNumber }),
        ReportColumn("platform", "Platform", value: { $0.device.platform }),
    ]
    static let trailing: [ReportColumn<ItemRow>] = [
        ReportColumn("inventoryState", "Inventory", value: { $0.device.inventoryLabel }),
        ReportColumn("usage", "Usage", value: { $0.device.usage }),
        ReportColumn("catalog", "Catalog", value: { $0.device.catalog }),
        ReportColumn("room", "Room", value: { $0.device.room }),
        ReportColumn("collectedAt", "System collection", kind: .time, value: { $0.device.collectedAt }),
        ReportColumn("freshness", "Collection age", kind: .state, value: { $0.freshness.label }),
        ReportColumn("lastSeen", "Last seen", kind: .time, value: { $0.device.lastSeen }),
    ]

    /// A column that describes only some item kinds; other rows read "Not applicable".
    static func only(_ kinds: [String], _ column: ReportColumn<ItemRow>) -> ReportColumn<ItemRow> {
        ReportColumn(column.key, column.label, kind: column.kind, missing: column.missing,
                     value: { kinds.contains($0.kind) ? column.value($0) : "Not applicable" },
                     sortKey: { kinds.contains($0.kind) ? column.sortKey($0) : nil })
    }

    private static func labelled(_ labels: [(String, String)], _ fallback: String) -> (String?) -> String {
        { v in labels.first { $0.0 == v }?.1 ?? fallback }
    }

    /// Task Scheduler reports 1999-11-30 for a task that never ran and 1899-12-30 when no run is scheduled.
    public static func taskTime(_ value: String?, sentinel: String) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if let year = Int(value.prefix(4)), year > 0, year < 2000 { return sentinel }
        return value
    }

    public static let backgroundKinds = [("task", "Scheduled task"), ("launchd", "launchd job"), ("loginItem", "Open at Login")]
    public static let lastRunLabels = [("succeeded", "Succeeded"), ("failed", "Failed"), ("running", "Running"), ("notRun", "Has not run"),
                                       ("informational", "Informational"), ("unknown", "Unknown"), ("notApplicable", "Not applicable")]
    public static let originLabels = [("builtIn", "Built in"), ("thirdParty", "Third party"), ("unknown", "Unknown")]
    public static let enabledLabels = [("enabled", "Enabled"), ("disabled", "Disabled"), ("unknown", "Unknown")]

    private static func yesNo(_ v: JSONValue) -> String { ReportLabels.yesNo(v.bool) }

    public static let background: ItemReportSpec = {
        let kindLabel = labelled(backgroundKinds, "")
        return ItemReportSpec(
            tab: "background", api: "/system/background", csvName: "background-items-report",
            description: "Scheduled tasks, launchd jobs and Open at Login items across devices.",
            footnote: "Services covers Windows services and the launchd jobs macOS reports as loaded, with running state. This tab covers what Services does not: launchd jobs configured on disk, Open at Login items and Windows scheduled tasks. Rows list reported items only; a device that does not list an item is not proof the item is absent.",
            prompt: "Choose scheduled tasks, launchd jobs or Open at Login items from Selections, or show failed scheduled tasks across the fleet.",
            kinds: [ReportChoice(value: "task", label: "Scheduled tasks"), ReportChoice(value: "launchd", label: "launchd jobs"), ReportChoice(value: "loginItem", label: "Open at Login")],
            filters: [
                ItemChoiceFilter(param: "enabled", label: "Enabled", summaryKey: "enabledState", choices: enabledLabels.map { ReportChoice(value: $0.0, label: $0.1) }),
                ItemChoiceFilter(param: "lastRuns", label: "Task last result", summaryKey: "lastRun", choices: lastRunLabels.filter { $0.0 != "notApplicable" }.map { ReportChoice(value: $0.0, label: $0.1) }),
                ItemChoiceFilter(param: "origins", label: "Source", summaryKey: "origin", choices: originLabels.map { ReportChoice(value: $0.0, label: $0.1) }),
            ],
            columns: leading + [
                ReportColumn("kind", "Kind", value: { r in let l = kindLabel(r.kind); return l.isEmpty ? r.kind : l }),
                ReportColumn("name", "Item", kind: .mono, value: { $0.kind == "task" ? $0.text("path") : $0.name }),
                ReportColumn("enabledState", "Enabled", kind: .state, value: { labelled(enabledLabels, "Unknown")($0.text("enabledState")) }),
                ReportColumn("state", "Reported state", value: { $0.text("state") }),
                ReportColumn("origin", "Source", value: { labelled(originLabels, "Unknown")($0.text("origin")) }),
                only(["task"], ReportColumn("lastRun", "Last result", kind: .state, value: { labelled(lastRunLabels, "Unknown")($0.text("lastRun")) })),
                only(["task"], ReportColumn("lastRunCode", "Last result code", kind: .mono, value: { $0.text("lastRunCode") })),
                only(["task"], ReportColumn("lastRunMessage", "Last result message", value: { $0.text("lastRunMessage") })),
                only(["task"], ReportColumn("lastRunTime", "Last run", kind: .time, value: { taskTime($0.text("lastRunTime"), sentinel: "Never") })),
                only(["task"], ReportColumn("nextRunTime", "Next run", kind: .time, value: { taskTime($0.text("nextRunTime"), sentinel: "Not scheduled") })),
                ReportColumn("type", "Type", value: { $0.text("type") }),
                ReportColumn("source", "Reported source", value: { $0.text("source") }),
                only(["launchd"], ReportColumn("runAtLoad", "Run at load", value: { yesNo($0.json["runAtLoad"]) })),
                only(["launchd"], ReportColumn("keepAlive", "Keep alive", value: { yesNo($0.json["keepAlive"]) })),
                ReportColumn("detail", "Program or action", kind: .mono, value: { r in
                    if r.kind == "task" { return r.text("action") }
                    if r.kind == "launchd" { let s = [r.text("program"), r.text("arguments")].compactMap { $0 }.joined(separator: " "); return s.isEmpty ? nil : s }
                    return r.text("path") ?? r.text("bundleId")
                }),
                ReportColumn("username", "User", value: { $0.text("username") }),
            ] + trailing,
            defaultColumns: ["deviceName", "kind", "name", "enabledState", "lastRun", "lastRunTime", "nextRunTime", "origin", "detail", "collectedAt"],
            runsWithout: { $0.list("lastRuns").contains("failed") })
    }()

    public static let extensionKinds = [("systemExtension", "System extension"), ("kernelExtension", "Kernel extension"), ("helper", "Privileged helper")]
    public static let activationLabels = [("activated", "Activated"), ("notActivated", "Not activated"), ("unknown", "Unknown")]
    public static let signatureLabels = [("signed", "Signed"), ("unsigned", "Unsigned"), ("unknown", "Unknown")]
    public static let managedLabels = [("yes", "Managed"), ("no", "Not managed"), ("unknown", "Not reported")]

    public static let extensions: ItemReportSpec = {
        let kindLabel = labelled(extensionKinds, "")
        let optional: ([(String, String)], String, String) -> (ItemRow) -> String? = { labels, field, fallback in
            { r in r.text(field).map { labelled(labels, fallback)($0) } }
        }
        return ItemReportSpec(
            tab: "extensions", api: "/system/extensions", csvName: "extensions-report",
            description: "System extensions, kernel extensions and privileged helper tools across Macs.",
            footnote: "macOS only. Rows list reported items only. Profile management for system extensions is not collected by the current macOS client, so it shows as not reported.",
            prompt: "Choose extensions or helper tools from Selections, pick a team id, or show extensions that are not activated or helpers that are unsigned.",
            kinds: [ReportChoice(value: "systemExtension", label: "System extensions"), ReportChoice(value: "kernelExtension", label: "Kernel extensions"), ReportChoice(value: "helper", label: "Privileged helpers")],
            filters: [
                ItemChoiceFilter(param: "activations", label: "Activation", summaryKey: "activation", choices: activationLabels.map { ReportChoice(value: $0.0, label: $0.1) }),
                ItemChoiceFilter(param: "signatures", label: "Signature", summaryKey: "signature", choices: signatureLabels.map { ReportChoice(value: $0.0, label: $0.1) }),
                ItemChoiceFilter(param: "managed", label: "Managed by profile", summaryKey: "managed", choices: managedLabels.map { ReportChoice(value: $0.0, label: $0.1) }),
                ItemChoiceFilter(param: "teamIds", label: "Team id", choices: [], fromTeamCatalog: true),
            ],
            columns: leading + [
                ReportColumn("kind", "Kind", value: { r in let l = kindLabel(r.kind); return l.isEmpty ? r.kind : l }),
                ReportColumn("name", "Identifier or name", kind: .mono, value: { $0.name }),
                ReportColumn("version", "Version", kind: .mono, value: { $0.text("version") }),
                ReportColumn("state", "Reported state", value: { $0.text("state") }),
                only(["systemExtension"], ReportColumn("activation", "Activation", kind: .state, missing: "Not applicable", value: optional(activationLabels, "activation", "Unknown"))),
                ReportColumn("teamId", "Team id", kind: .mono, value: { $0.text("teamId") }),
                only(["helper"], ReportColumn("signature", "Signature", kind: .state, missing: "Not applicable", value: optional(signatureLabels, "signature", "Unknown"))),
                only(["systemExtension"], ReportColumn("managed", "Managed by profile", missing: "Not reported", value: optional(managedLabels, "managed", "Not reported"))),
                ReportColumn("type", "Type", value: { $0.text("type") }),
                ReportColumn("category", "Category", value: { $0.text("category") }),
                ReportColumn("appName", "App", value: { $0.text("appName") }),
                ReportColumn("bundleId", "Bundle id", kind: .mono, value: { $0.text("bundleId") }),
                only(["kernelExtension"], ReportColumn("loaded", "Loaded", value: { ReportLabels.yesNo($0.json["loaded"].bool) })),
                ReportColumn("path", "Path", kind: .mono, value: { $0.text("path") }),
            ] + trailing,
            defaultColumns: ["deviceName", "kind", "name", "version", "activation", "teamId", "signature", "managed", "appName", "collectedAt"],
            runsWithout: { $0.list("activations").contains("notActivated") || $0.list("signatures").contains("unsigned") || !$0.list("teamIds").isEmpty },
            macOnly: true)
    }()

    /// Rows matching the device search box.
    public func filter(_ rows: [ItemRow], params p: ReportParams) -> [ItemRow] {
        let q = p["search"] ?? ""
        return q.isEmpty ? rows : rows.filter { $0.device.matches(q) || ($0.name?.lowercased().contains(q.lowercased()) ?? false) }
    }
}
