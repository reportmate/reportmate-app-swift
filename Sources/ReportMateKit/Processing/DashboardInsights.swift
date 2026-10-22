import Foundation

/// The figures behind the dashboard's insight cards, computed from the rows the
/// report pages read. Each count uses the predicate the card's link applies on
/// the report (`ReportLinkFilter`), so the two always agree.
public enum DashboardInsights {
    public struct NamedCount: Sendable, Hashable, Identifiable {
        public var id: String { name }
        public let name: String
        public let count: Int
        public init(name: String, count: Int) { self.name = name; self.count = count }
    }

    static func top(_ tally: [String: Int], limit: Int) -> [NamedCount] {
        tally.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .prefix(limit).map { NamedCount(name: $0.key, count: $0.value) }
    }

    // MARK: 5 Install Health

    /// Items with the most devices in an error state (`/installs?item=<name>&filter=errors`).
    public static func topFailingItems(_ records: [InstallRecord], limit: Int = 5) -> [NamedCount] {
        var devices: [String: Set<String>] = [:]
        for r in records where !r.isVirtualItem && !r.name.isEmpty && InstallStatusClass.error.matches(recordStatus: r.status) {
            devices[r.name, default: []].insert(r.serialNumber)
        }
        return top(devices.mapValues(\.count), limit: limit)
    }

    /// Agents silent for more than `InstallsStale.thresholdDays` (`/installs?stale=1`).
    public static func staleAgentCount(_ agents: [StaleAgent]) -> Int { InstallsStale.serials(agents).count }

    // MARK: 6 Check-in Gaps

    /// Devices silent 1–7 days (stale) and over 7 days (missing), by the device status thresholds.
    public static func checkInGaps(_ devices: [DeviceSummary]) -> (stale: Int, missing: Int) {
        (devices.filter { $0.status == .stale }.count, devices.filter { $0.status == .missing }.count)
    }

    // MARK: 7 OS Currency

    public struct OSCurrencyStats: Sendable, Hashable {
        public var macTotal = 0
        public var onLatest = 0
        public var behind = 0
        public var unsupported = 0
        public var windows10 = 0
        /// The most common versions that are behind, with the devices `?osVersion=` matches.
        public var lagging: [NamedCount] = []
        public var onLatestPercent: Int { macTotal == 0 ? 0 : Int((Double(onLatest) / Double(macTotal) * 100).rounded()) }
    }

    /// `currency` is built from the whole fleet; `rows` may be narrowed by the platform toggle.
    public static func osCurrency(_ rows: [SystemReportRow], currency: OSCurrency) -> OSCurrencyStats {
        var s = OSCurrencyStats()
        var behindVersions: [String: Int] = [:]
        for r in rows {
            if OSCurrency.isWindows10(r) { s.windows10 += 1 }
            guard r.isMac, let v = r.osVersion, OSCurrency.major(v) != nil else { continue }
            s.macTotal += 1
            if currency.isOnLatest(r) { s.onLatest += 1 } else { s.behind += 1; behindVersions[v, default: 0] += 1 }
            if currency.isUnsupported(r) { s.unsupported += 1 }
        }
        s.lagging = top(behindVersions, limit: 3).map { v in
            NamedCount(name: v.name, count: rows.filter { SystemBuckets.matchesVersion($0, v.name) }.count)
        }
        return s
    }

    // MARK: 8 Software Risk

    /// Managed items with the most devices whose installed version differs from the catalog's.
    public static func topBehindItems(_ records: [InstallRecord], limit: Int = 5) -> [NamedCount] {
        var devices: [String: Set<String>] = [:]
        for r in records where r.isManaged && !r.isVirtualItem && !r.name.isEmpty {
            guard let installed = r.installedVersion, let latest = r.latestVersion, installed != latest else { continue }
            devices[r.name, default: []].insert(r.serialNumber)
        }
        return top(devices.mapValues(\.count), limit: limit)
    }

    // MARK: 9 Certificates

    public struct CertificateStats: Sendable, Hashable {
        public var expiringCertificates = 0
        public var expiringDevices = 0
        public var expiredDevices = 0
        /// Common names expiring soonest, with days left.
        public var soonest: [NamedCount] = []
    }

    /// `expiring` is the `/security/certificates?status=expiring` rows; `security` the `/security` rows.
    public static func certificates(expiring: [JSONValue], security: [SecurityReportRow], withinDays: Int = 30) -> CertificateStats {
        var s = CertificateStats()
        let rows = expiring.filter { ($0["daysUntilExpiry"].int ?? 0) <= withinDays && !$0["isExpired"].boolish }
        s.expiringCertificates = rows.count
        s.expiringDevices = security.filter { $0.expiringSoonCertCount > 0 }.count
        s.expiredDevices = security.filter { $0.userExpiredCertCount > 0 }.count
        var soonest: [String: Int] = [:]
        for r in rows {
            let cn = r["commonName"].nonEmptyString ?? "Unknown"
            let days = r["daysUntilExpiry"].int ?? 0
            soonest[cn] = min(soonest[cn] ?? Int.max, days)
        }
        s.soonest = soonest.sorted { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }.prefix(5).map { NamedCount(name: $0.key, count: $0.value) }
        return s
    }

    // MARK: 10 Identity

    public struct IdentityStats: Sendable, Hashable {
        public var joins: [IdentityJoin: Int] = [:]
        public var extraAdmins = 0
        public var shared = 0
        public var assigned = 0
        public var total = 0
    }

    public static func identity(_ rows: [IdentityReportRow]) -> IdentityStats {
        var s = IdentityStats()
        s.total = rows.count
        for r in rows {
            s.joins[IdentityJoin.of(r), default: 0] += 1
            if r.adminUsers > 1 { s.extraAdmins += 1 }
            switch (r.usage ?? "").lowercased() {
            case "shared": s.shared += 1
            case "assigned": s.assigned += 1
            default: break
            }
        }
        return s
    }

    // MARK: 11 App Usage

    /// The five most-used apps by hours, and the five least-used of those installed on `minInstalls` or more devices.
    public static func appUsage(_ apps: [UtilizationApp], limit: Int = 5, minInstalls: Int = 10) -> (top: [UtilizationApp], least: [UtilizationApp]) {
        let named = apps.filter { !$0.name.isEmpty }
        let top = named.sorted { $0.totalHours > $1.totalHours }.prefix(limit)
        func ratio(_ a: UtilizationApp) -> Double {
            let installed = Double(a.installedDeviceCount ?? 0)
            return installed > 0 ? Double(a.activeDeviceCount ?? a.deviceCount) / installed : 1
        }
        let least = named.filter { ($0.installedDeviceCount ?? 0) >= minInstalls }
            .sorted { ratio($0) != ratio($1) ? ratio($0) < ratio($1) : $0.name < $1.name }.prefix(limit)
        return (Array(top), Array(least))
    }

    // MARK: 12 Network & Peripherals

    public struct NetworkPeripheralStats: Sendable, Hashable {
        public var wired = 0
        public var wifi = 0
        public var weakSignal = 0
        public var printers = 0
        public var printerDevices = 0
        public var displays = 0
        public var displayDevices = 0
        /// Rooms with the most printers, counted as devices with printers in the room.
        public var printerRooms: [NamedCount] = []
    }

    /// `peripherals` pairs each row with its room (inventory location).
    public static func networkPeripherals(network: [NetworkReportRow], peripherals: [(row: PeripheralsReportRow, room: String?)]) -> NetworkPeripheralStats {
        var s = NetworkPeripheralStats()
        let wired = ReportLinkFilter(report: "network", query: ["connection": "wired"])
        let wifi = ReportLinkFilter(report: "network", query: ["connection": "wifi"])
        let weak = ReportLinkFilter(report: "network", query: ["signal": "weak"])
        for n in network {
            if wired.matches(network: n) { s.wired += 1 }
            if wifi.matches(network: n) { s.wifi += 1 }
            if weak.matches(network: n) { s.weakSignal += 1 }
        }
        guard let printerKind = PeripheralsReportRow.kinds.first(where: { $0.key == "printers" }),
              let displayKind = PeripheralsReportRow.kinds.first(where: { $0.key == "displays" }) else { return s }
        var rooms: [String: Int] = [:]
        for (p, room) in peripherals {
            let printers = p.count(printerKind), displays = p.count(displayKind)
            s.printers += printers
            s.displays += displays
            if printers > 0 {
                s.printerDevices += 1
                if let room, !room.isEmpty { rooms[room, default: 0] += 1 }
            }
            if displays > 0 { s.displayDevices += 1 }
        }
        s.printerRooms = top(rooms, limit: 3)
        return s
    }
}
