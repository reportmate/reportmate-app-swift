import Foundation

/// The link parameters a report reads from its URL (`?provider=Unmanaged`), and
/// the row predicates they apply. Shared with the web and Windows apps through
/// `docs/DASHBOARD-WIDGETS.md` in the web repo: the dashboard cards count rows
/// with these same predicates, so the number on a card is the number of rows the
/// report shows when the card's link opens it.
public struct ReportLinkFilter: Sendable, Hashable {
    /// The report's web route name: `system`, `security`, `management`, …
    public let report: String
    /// The parameters this report recognises, as the link carried them.
    public var params: [String: String]

    public init(report: String, query: [String: String] = [:]) {
        self.report = report
        let known = Set(ReportLinkFilter.parameters[report] ?? [])
        params = query.filter { known.contains($0.key) && !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        // The global toggle travels as `platform=mac|win`; only Management's own
        // `platform=macOS|Windows` is a report filter.
        if let p = params["platform"], report != "management" || !["macOS", "Windows"].contains(p) { params["platform"] = nil }
    }

    public var isEmpty: Bool { params.isEmpty }
    public var count: Int { params.count }

    /// The values of one parameter, split on commas.
    public func values(_ key: String) -> [String] { ReportLinkFilter.list(params[key]) }
    public func has(_ key: String, _ value: String) -> Bool { values(key).contains { $0.caseInsensitiveCompare(value) == .orderedSame } }

    /// Removes `key` and returns its values, for a report that applies it as a widget filter instead.
    public mutating func take(_ key: String) -> [String] {
        let v = values(key)
        params[key] = nil
        return v
    }

    /// One removable chip per parameter, sorted by key: (key, "Provider: Unmanaged").
    public var chips: [(key: String, label: String)] {
        params.keys.sorted().map { ($0, ReportLinkFilter.label(key: $0, value: params[$0] ?? "")) }
    }

    /// Parameter names per report, as `docs/DASHBOARD-WIDGETS.md` lists them.
    public static let parameters: [String: [String]] = [
        "devices": ["status", "search", "platform"],
        "system": ["osVersion", "uptime", "pending", "deferred", "edition", "os", "patch"],
        "security": ["encryption", "firewall", "antivirus", "sip", "secureBoot", "threats", "certs", "cve", "certSearch", "certStatus"],
        "management": ["provider", "enrolled", "enrollmentType", "platform", "lastSeen"],
        "hardware": ["arch", "storage", "memory", "type", "processor"],
        "installs": ["filter", "item", "stale", "view"],
        "failures": ["hours", "reason", "outcome"],
        "identity": ["admins", "join", "usage"],
        "network": ["connection", "signal", "quality", "vpn"],
        "peripherals": ["kind", "room"],
    ]

    public static func list(_ raw: String?) -> [String] {
        (raw ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The chip text for a parameter, in words rather than URL keys.
    public static func label(key: String, value: String) -> String {
        let v = list(value)
        let joined = v.joined(separator: ", ")
        switch key {
        case "encryption": return "Encryption off"
        case "firewall": return "Firewall off"
        case "antivirus": return "Antivirus off"
        case "sip": return "SIP off"
        case "secureBoot": return "Secure Boot off"
        case "threats": return "Active threats"
        case "certs": return v.first == "expired" ? "Expired certificates" : "Certificates expiring"
        case "cve": return v.first == "exploited" ? "Actively exploited CVEs" : "Critical CVEs"
        case "certSearch": return "Certificate: \(joined)"
        case "certStatus": return "Certificate status: \(joined)"
        case "provider": return "Provider: \(joined)"
        case "enrolled": return value == "1" ? "Enrolled" : "Not enrolled"
        case "enrollmentType": return "Enrollment: \(joined)"
        case "arch": return "Architecture: \(joined)"
        case "storage": return "Under 10% free storage"
        case "memory": return "8 GB memory or less"
        case "type": return v.map { $0.prefix(1).uppercased() + $0.dropFirst() + "s" }.joined(separator: ", ")
        case "processor": return "Processor: \(joined)"
        case "osVersion": return "OS \(joined)"
        case "uptime": return "Uptime: " + v.map { SystemBuckets.uptime(key: $0)?.label ?? $0 }.joined(separator: ", ")
        case "pending": return v.map { SystemBuckets.pending(key: $0)?.label ?? $0 }.joined(separator: ", ")
        case "deferred": return "Deferred updates"
        case "edition": return "Edition: \(joined)"
        case "os": return v.map { $0 == "windows10" ? "Windows 10" : $0 == "unsupported" ? "Unsupported macOS" : $0 }.joined(separator: ", ")
        case "patch": return "Behind the latest patch"
        case "admins": return v.first == "extra" ? "Extra local admins" : "Local admins: " + v.joined(separator: ", ")
        case "platform": return "Platform: \(joined)"
        case "lastSeen": return "Last seen: " + v.map { LastSeenBucket(rawValue: $0)?.label ?? $0 }.joined(separator: ", ")
        case "join": return "Join: " + v.map { IdentityJoin(rawValue: $0.lowercased())?.label ?? $0 }.joined(separator: ", ")
        case "usage": return "Usage: \(joined)"
        case "connection": return v.map { $0 == "wifi" ? "Wi-Fi" : $0 == "wired" ? "Wired" : $0 }.joined(separator: ", ")
        case "signal": return "Weak signal"
        case "quality": return "Poor network quality"
        case "vpn": return "On VPN"
        case "kind": return v.map { k in PeripheralsReportRow.kinds.first { $0.key == k }?.label ?? k }.joined(separator: ", ")
        case "room": return "Room: \(joined)"
        case "item": return "Item: \(joined)"
        case "stale": return "Agents silent over \(Int(InstallsStale.thresholdDays)) days"
        case "reason": return "Reason: \(joined)"
        default: return "\(key): \(joined)"
        }
    }
}

// MARK: - System

/// The System report's uptime and pending-update buckets, keyed the way links name them.
public enum SystemBuckets {
    public struct Bucket: Sendable, Hashable {
        public let key: String
        public let label: String
    }

    public static let uptime: [(bucket: Bucket, range: ClosedRange<Double>)] = [
        (Bucket(key: "lt1d", label: "< 1 day"), 0...86_399),
        (Bucket(key: "1-3d", label: "1-3 days"), 86_400...259_199),
        (Bucket(key: "3-7d", label: "3-7 days"), 259_200...604_799),
        (Bucket(key: "1-2w", label: "1-2 weeks"), 604_800...1_209_599),
        (Bucket(key: "2-4w", label: "2-4 weeks"), 1_209_600...2_591_999),
        (Bucket(key: "30d+", label: "30+ days"), 2_592_000...Double.greatestFiniteMagnitude),
    ]
    public static let pending: [(bucket: Bucket, range: ClosedRange<Int>)] = [
        (Bucket(key: "up-to-date", label: "Up to date"), 0...0),
        (Bucket(key: "1-5", label: "1-5 pending"), 1...5),
        (Bucket(key: "6-10", label: "6-10 pending"), 6...10),
        (Bucket(key: "10+", label: "10+ pending"), 11...Int.max),
    ]

    public static func uptimeBucket(_ seconds: Double?) -> Bucket? {
        guard let s = seconds, s > 0 else { return nil }
        return uptime.first { $0.range.contains(s) }?.bucket
    }
    public static func pendingBucket(_ count: Int) -> Bucket? { pending.first { $0.range.contains(count) }?.bucket }
    public static func uptime(key: String) -> Bucket? { uptime.first { $0.bucket.key == key }?.bucket }
    public static func pending(key: String) -> Bucket? { pending.first { $0.bucket.key == key }?.bucket }
    public static func uptime(label: String) -> Bucket? { uptime.first { $0.bucket.label == label }?.bucket }
    public static func pending(label: String) -> Bucket? { pending.first { $0.bucket.label == label }?.bucket }

    /// The web's `osVersion` URL filter: a Windows group name, an exact or normalised version, or a version prefix.
    public static func matchesVersion(_ d: SystemReportRow, _ filter: String) -> Bool {
        if filter.hasPrefix("Windows ") { return d.operatingSystem.contains(filter) }
        let version = d.osVersion ?? ""
        func normalize(_ v: String) -> String {
            guard !v.isEmpty else { return "" }
            var parts = v.split(separator: ".").map(String.init)
            while parts.count < 3 { parts.append("0") }
            return parts.prefix(3).joined(separator: ".")
        }
        var groupKey = "", childKey = ""
        if let r = d.operatingSystem.range(of: #"Windows\s+(\d+)"#, options: .regularExpression) {
            let win = d.operatingSystem[r].filter(\.isNumber)
            let build = d.buildNumber ?? "0"
            groupKey = "\(win).\(build)"
            childKey = "\(win).\(build).0"
        }
        return childKey == filter || groupKey == filter || version == filter || normalize(version) == normalize(filter) || version.hasPrefix(filter + ".")
    }
}

/// OS currency across the fleet. For each macOS major the latest patch is the
/// highest version at least `minimumDevices` Macs report (so one beta Mac does
/// not put the rest behind), and a Mac below it is behind. A major where no
/// version reaches that count takes its highest version. Unsupported is more than
/// two majors behind the newest major at least `minimumDevices` Macs run. A Mac more
/// than two majors behind the newest major seen is unsupported. Majors count in
/// release order, so 26 follows 15 (Apple skipped 16 to 25).
public struct OSCurrency: Sendable, Hashable {
    /// Highest version seen per macOS major.
    public let latestByMajor: [Int: String]
    /// Release ordinal of the newest macOS major seen.
    public let newestOrdinal: Int?

    public static let minimumDevices = 5

    public init(rows: [SystemReportRow], minimumDevices: Int = OSCurrency.minimumDevices) {
        var counts: [Int: [String: Int]] = [:]
        for r in rows where r.isMac {
            guard let v = r.osVersion, let major = OSCurrency.major(v) else { continue }
            counts[major, default: [:]][v, default: 0] += 1
        }
        var latest: [Int: String] = [:]
        for (major, versions) in counts {
            let common = versions.filter { $0.value >= minimumDevices }.map(\.key)
            let pool = common.isEmpty ? Array(versions.keys) : common
            latest[major] = pool.max { OSCurrency.compare($0, $1) == .orderedAscending }
        }
        latestByMajor = latest
        // Unsupported is measured from the newest major at least `minimumDevices` Macs run,
        // so a beta major on one Mac does not push the fleet back; else the newest seen.
        let established = counts.filter { $0.value.values.reduce(0, +) >= minimumDevices }.map(\.key)
        newestOrdinal = (established.isEmpty ? Array(latest.keys) : established).map(OSCurrency.ordinal).max()
    }

    /// "27.0" -> "27.0.0", the exact form `?osVersion=` matches.
    public static func threePart(_ version: String) -> String {
        var parts = version.split(separator: ".").map(String.init)
        while parts.count < 3 { parts.append("0") }
        return parts.joined(separator: ".")
    }

    public static func major(_ version: String) -> Int? { Int(version.split(separator: ".").first ?? "") }
    /// 15 → 15, 26 → 16, 27 → 17.
    public static func ordinal(_ major: Int) -> Int { major >= 26 ? major - 10 : major }
    public static func compare(_ a: String, _ b: String) -> ComparisonResult { a.compare(b, options: [.numeric, .caseInsensitive]) }

    public func isOnLatest(_ r: SystemReportRow) -> Bool {
        guard r.isMac, let v = r.osVersion, let major = OSCurrency.major(v), let latest = latestByMajor[major] else { return false }
        return OSCurrency.compare(v, latest) != .orderedAscending
    }
    public func isBehind(_ r: SystemReportRow) -> Bool {
        guard r.isMac, let v = r.osVersion, OSCurrency.major(v) != nil else { return false }
        return !isOnLatest(r)
    }
    public func isUnsupported(_ r: SystemReportRow) -> Bool {
        guard r.isMac, let v = r.osVersion, let major = OSCurrency.major(v), let newest = newestOrdinal else { return false }
        return newest - OSCurrency.ordinal(major) > 2
    }
    public static func isWindows10(_ r: SystemReportRow) -> Bool {
        !r.isMac && r.operatingSystem.range(of: #"Windows\s+10\b"#, options: .regularExpression) != nil
    }
}

// MARK: - Identity

/// How a device is joined to a directory, the way the identity card and `?join=` read it.
public enum IdentityJoin: String, Sendable, CaseIterable {
    case entra, domain, hybrid, workgroup

    public var label: String {
        switch self {
        case .entra: return "Entra"
        case .domain: return "Domain"
        case .hybrid: return "Hybrid"
        case .workgroup: return "Workgroup"
        }
    }

    public static func of(_ row: IdentityReportRow) -> IdentityJoin {
        switch (row.entraJoined, row.domainJoined) {
        case (true, true): return .hybrid
        case (true, false): return .entra
        case (false, true): return .domain
        default: return .workgroup
        }
    }
}

// MARK: - Hardware

public enum HardwareClass {
    /// Apple Silicon, Intel, ARM64 or x64, the `?arch=` values.
    public static func family(platform: Platform, _ hw: HardwareReportRow) -> String {
        let arch = hw.architecture.lowercased()
        let proc = hw.processorName.lowercased()
        if platform == .windows {
            return arch.contains("arm") || proc.contains("snapdragon") || proc.contains("qualcomm") ? "ARM64" : "x64"
        }
        if arch.contains("arm") || hw.chipName != nil || proc.contains("apple") { return "Apple Silicon" }
        return arch.isEmpty && proc.isEmpty ? "Unknown" : "Intel"
    }

    /// Under 10% of internal storage free.
    public static func isLowStorage(_ hw: HardwareReportRow) -> Bool {
        hw.storageTotalBytes > 0 && hw.storageFreeBytes > 0 && hw.storageFreeBytes / hw.storageTotalBytes < 0.1
    }

    public static func isLowMemory(_ hw: HardwareReportRow) -> Bool {
        hw.memoryBytes > 0 && hw.memoryBytes <= 8 * 1_073_741_824
    }

    /// `laptop` or `desktop`.
    public static func type(_ hw: HardwareReportRow) -> String { hw.deviceType.lowercased() }
}

// MARK: - Installs

public enum InstallsStale {
    /// The dashboard counts agents silent for more than a week; the API's own threshold is a day.
    public static let thresholdDays: Double = 7

    public static func serials(_ agents: [StaleAgent]) -> Set<String> {
        Set(agents.filter { $0.staleDays > thresholdDays }.map(\.serialNumber))
    }
}

// MARK: - Predicates

public extension ReportLinkFilter {
    /// Rows a `/security` link keeps. `certSearch` and `certStatus` drive the certificate search, not the rows.
    func matches(security d: SecurityReportRow) -> Bool {
        if params["encryption"] == "off", d.encryptionEnabled { return false }
        if params["firewall"] == "off", d.firewallEnabled { return false }
        if params["antivirus"] == "off", !(d.reportsProtection && !d.antivirusEnabled) { return false }
        if params["sip"] == "off", !(d.isWindows == false && d.sipEnabled == false) { return false }
        if params["secureBoot"] == "off", !(d.isWindows && !d.secureBootEnabled) { return false }
        if params["threats"] == "1", d.activeThreatCount == 0 { return false }
        switch params["certs"] {
        case "expired": if d.userExpiredCertCount == 0 { return false }
        case "expiring": if d.expiringSoonCertCount == 0 { return false }
        default: break
        }
        switch params["cve"] {
        case "critical": if d.criticalCveCount == 0 { return false }
        case "exploited": if d.activelyExploitedCveCount == 0 { return false }
        default: break
        }
        return true
    }

    /// `platform` (macOS or Windows) narrows this report only; the global toggle travels as
    /// `mac` or `win`. `lastSeen` is a `LastSeenBucket`.
    func matches(management m: ManagementReportRow, platform: Platform = .unknown, lastSeen: Date? = nil, now: Date = Date()) -> Bool {
        let platforms = values("platform").map { Platform.normalize($0) }
        if !platforms.isEmpty, !platforms.contains(platform) { return false }
        let seen = values("lastSeen").compactMap(LastSeenBucket.init(rawValue:))
        if !seen.isEmpty, !seen.contains(where: { $0.contains(lastSeen, now: now) }) { return false }
        let providers = values("provider")
        if !providers.isEmpty, !providers.contains(where: { $0.caseInsensitiveCompare(m.provider) == .orderedSame }) { return false }
        if let e = params["enrolled"], (e == "1") != m.isEnrolled { return false }
        let types = values("enrollmentType")
        if !types.isEmpty, !types.contains(m.bootstrapMethod ?? "Not Enrolled") { return false }
        return true
    }

    func matches(hardware hw: HardwareReportRow, platform: Platform) -> Bool {
        let arch = values("arch")
        if !arch.isEmpty, !arch.contains(HardwareClass.family(platform: platform, hw)) { return false }
        if params["storage"] == "low", !HardwareClass.isLowStorage(hw) { return false }
        if params["memory"] == "le8", !HardwareClass.isLowMemory(hw) { return false }
        let types = values("type").map { $0.lowercased() }
        if !types.isEmpty, !types.contains(HardwareClass.type(hw)) { return false }
        let processors = values("processor")
        if !processors.isEmpty, !processors.contains(hw.processorGroup) { return false }
        return true
    }

    /// `currency` comes from every `/system` row, so `patch` and `os` judge a row against the whole fleet.
    func matches(system d: SystemReportRow, currency: OSCurrency) -> Bool {
        let versions = values("osVersion")
        if !versions.isEmpty, !versions.contains(where: { SystemBuckets.matchesVersion(d, $0) }) { return false }
        let uptime = values("uptime")
        if !uptime.isEmpty, !(SystemBuckets.uptimeBucket(d.uptime).map { uptime.contains($0.key) } ?? false) { return false }
        let pending = values("pending")
        if !pending.isEmpty, !(SystemBuckets.pendingBucket(d.pendingUpdatesCount).map { pending.contains($0.key) } ?? false) { return false }
        if params["deferred"] == "1", d.deferredUpdatesCount == 0 { return false }
        let editions = values("edition")
        if !editions.isEmpty, !(d.edition.map { editions.contains($0) } ?? false) { return false }
        let os = values("os")
        if !os.isEmpty {
            let hit = os.contains { o in
                switch o {
                case "unsupported": return currency.isUnsupported(d)
                case "windows10": return OSCurrency.isWindows10(d)
                default: return false
                }
            }
            if !hit { return false }
        }
        if params["patch"] == "behind", !currency.isBehind(d) { return false }
        return true
    }

    func matches(identity i: IdentityReportRow) -> Bool {
        let admins = values("admins")
        if !admins.isEmpty {
            let n = i.adminUsers
            let hit = admins.contains { a in
                switch a {
                case "extra": return n > 1
                case "4+": return n >= 4
                default: return Int(a) == n
                }
            }
            if !hit { return false }
        }
        let joins = values("join").map { $0.lowercased() }
        if !joins.isEmpty, !joins.contains(IdentityJoin.of(i).rawValue) { return false }
        let usage = values("usage").map { $0.lowercased() }
        if !usage.isEmpty, !usage.contains((i.usage ?? "").lowercased()) { return false }
        return true
    }

    func matches(network n: NetworkReportRow) -> Bool {
        let connections = values("connection").map { $0.lowercased() }
        if !connections.isEmpty {
            let hit = connections.contains { c in c == "wired" ? n.isWired : c == "wifi" ? n.isWireless : false }
            if !hit { return false }
        }
        if params["signal"] == "weak", n.signal != .poor { return false }
        if params["quality"] == "poor", !n.isPoorQuality { return false }
        if params["vpn"] == "1", !n.info.vpnActive { return false }
        return true
    }

    /// `room` is the device's inventory location.
    func matches(peripherals p: PeripheralsReportRow, room: String?) -> Bool {
        let kinds = values("kind")
        if !kinds.isEmpty, !PeripheralsReportRow.kinds.contains(where: { kinds.contains($0.key) && p.count($0) > 0 }) { return false }
        let rooms = values("room")
        if !rooms.isEmpty, !rooms.contains(room ?? "") { return false }
        return true
    }
}

/// How long ago a device last checked in, as `?lastSeen=` names it.
public enum LastSeenBucket: String, Sendable, CaseIterable {
    case day = "24h", week = "1-7d", older = "7d+"

    public var label: String {
        switch self {
        case .day: return "in the last 24 hours"
        case .week: return "1-7 days ago"
        case .older: return "over 7 days ago"
        }
    }

    /// A device never seen counts as over seven days.
    public func contains(_ lastSeen: Date?, now: Date = Date()) -> Bool {
        guard let lastSeen else { return self == .older }
        let age = now.timeIntervalSince(lastSeen)
        switch self {
        case .day: return age < 86_400
        case .week: return age >= 86_400 && age <= 7 * 86_400
        case .older: return age > 7 * 86_400
        }
    }
}
