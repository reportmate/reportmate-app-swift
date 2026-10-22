import Testing
import Foundation
@testable import ReportMateKit

private func json(_ text: String) -> JSONValue { try! JSONValue.parse(Data(text.utf8)) }

@Suite struct DashboardLinkTests {
    @Test func managementProviderLinkMatchesTheWebRoute() {
        let link = DashboardLinks.report("management", ["provider": "Unmanaged"])
        #expect(link.url.absoluteString == "reportmate://management?provider=Unmanaged")
        #expect(link.webURL(base: URL(string: "https://reportmate.example")!)?.absoluteString == "https://reportmate.example/management?provider=Unmanaged")
    }

    @Test func linksRoundTripThroughTheParser() {
        let links: [DeepLink] = [
            DashboardLinks.devices(status: .stale),
            DashboardLinks.installs(item: "Google Chrome", filter: "errors"),
            DashboardLinks.installsStale,
            DashboardLinks.failures(hours: 24, reason: "invalid_passphrase"),
            DashboardLinks.system(osVersion: "26.4"),
            DashboardLinks.report("security", ["certSearch": "Example CA", "certStatus": "expiring"]),
            DashboardLinks.report("peripherals", ["kind": "printers", "room": "B1120"]),
            DashboardLinks.applicationUsage("Adobe Photoshop 2026"),
        ]
        for link in links {
            #expect(DeepLink(url: link.url) == link)
        }
    }

    @Test func failuresAndUsageLinksUseTheirOwnRoutes() {
        #expect(DashboardLinks.failures(reason: "missing_credentials").url.absoluteString == "reportmate://events/failures?hours=24&reason=missing_credentials")
        #expect(DashboardLinks.applicationUsage("Zoom").url.absoluteString == "reportmate://applications/usage/Zoom?days=30")
        #expect(DashboardLinks.installs(item: "Firefox", filter: "errors").url.absoluteString == "reportmate://installs?filter=errors&item=Firefox")
    }
}

@Suite struct ReportLinkFilterTests {
    @Test func keepsOnlyTheReportsOwnParameters() {
        let f = ReportLinkFilter(report: "management", query: ["provider": "Unmanaged", "platform": "mac", "bogus": "1"])
        #expect(f.params == ["provider": "Unmanaged"])
        #expect(f.chips.first?.label == "Provider: Unmanaged")
    }

    @Test func takeMovesAParameterToAWidget() {
        var f = ReportLinkFilter(report: "hardware", query: ["processor": "Intel Core i7,Apple M3", "arch": "Intel"])
        #expect(f.take("processor") == ["Intel Core i7", "Apple M3"])
        #expect(f.params == ["arch": "Intel"])
    }

    @Test func managementProviderAndEnrollment() {
        let rows = [
            ManagementReportRow(json: json(#"{"provider": "Microsoft Intune", "isEnrolled": true, "enrollmentStatus": "Enrolled", "enrollmentType": "Automated Device Enrollment"}"#)),
            ManagementReportRow(json: json(#"{"isEnrolled": false}"#)),
        ]
        let unmanaged = ReportLinkFilter(report: "management", query: ["provider": "Unmanaged"])
        #expect(rows.filter(unmanaged.matches(management:)).count == 1)
        #expect(rows.filter(ReportLinkFilter(report: "management", query: ["enrolled": "1"]).matches(management:)).count == 1)
        #expect(rows.filter(ReportLinkFilter(report: "management", query: ["enrollmentType": "Automated"]).matches(management:)).count == 1)
    }

    @Test func securityParameters() {
        let mac = SecurityReportRow(json: json(#"{"encryptionEnabled": false, "firewallEnabled": true, "sipEnabled": false, "criticalCveCount": 2, "activelyExploitedCveCount": 1, "expiringSoonCertCount": 1}"#), platform: .macOS)
        let win = SecurityReportRow(json: json(#"{"encryptionEnabled": true, "firewallEnabled": false, "antivirusEnabled": false, "secureBootEnabled": false, "userExpiredCertCount": 3, "activeThreatCount": 1}"#), platform: .windows)
        func count(_ q: [String: String]) -> Int { [mac, win].filter(ReportLinkFilter(report: "security", query: q).matches(security:)).count }
        #expect(count(["encryption": "off"]) == 1)
        #expect(count(["firewall": "off"]) == 1)
        #expect(count(["antivirus": "off"]) == 1)
        #expect(count(["sip": "off"]) == 1)
        #expect(count(["secureBoot": "off"]) == 1)
        #expect(count(["threats": "1"]) == 1)
        #expect(count(["certs": "expired"]) == 1)
        #expect(count(["certs": "expiring"]) == 1)
        #expect(count(["cve": "critical"]) == 1)
        #expect(count(["cve": "exploited"]) == 1)
        #expect(count(["certSearch": "Example CA"]) == 2)
    }

    @Test func identityJoinFollowsDirectoryServices() {
        let entra = IdentityReportRow(json: json(#"{"directoryServices": {"azureAd": {"joined": true}}, "usage": "Shared", "summary": {"adminUsers": 2}}"#))
        let hybrid = IdentityReportRow(json: json(#"{"directoryServices": {"azureAd": {"joined": true}, "activeDirectory": {"isDomainJoined": true}}, "usage": "Assigned"}"#))
        let domain = IdentityReportRow(json: json(#"{"directoryServices": {"activeDirectory": {"bound": true}}}"#))
        let workgroup = IdentityReportRow(json: json(#"{"directoryServices": {"workgroup": "WORKGROUP"}}"#))
        #expect([entra, hybrid, domain, workgroup].map(IdentityJoin.of) == [.entra, .hybrid, .domain, .workgroup])
        let stats = DashboardInsights.identity([entra, hybrid, domain, workgroup])
        #expect(stats.extraAdmins == 1 && stats.shared == 1 && stats.assigned == 1)
        let rows = [entra, hybrid, domain, workgroup]
        #expect(rows.filter(ReportLinkFilter(report: "identity", query: ["admins": "extra"]).matches(identity:)).count == stats.extraAdmins)
        #expect(rows.filter(ReportLinkFilter(report: "identity", query: ["join": "hybrid"]).matches(identity:)).count == stats.joins[.hybrid])
        #expect(rows.filter(ReportLinkFilter(report: "identity", query: ["usage": "shared"]).matches(identity:)).count == stats.shared)
    }

    @Test func hardwareParameters() {
        let air = HardwareReportRow(json: json(#"{"model": "MacBook Air", "processor": {"name": "Apple M2"}, "memory": 8589934592, "storage": [{"size": 1000, "freeSpace": 50}]}"#))
        let tower = HardwareReportRow(json: json(#"{"model": "OptiPlex 7010", "processor": {"name": "Intel Core i7", "architecture": "x64"}, "memory": 34359738368, "storage": [{"size": 1000, "freeSpace": 500}]}"#))
        #expect(HardwareClass.family(platform: .macOS, air) == "Apple Silicon")
        #expect(HardwareClass.family(platform: .windows, tower) == "x64")
        let pairs: [(HardwareReportRow, Platform)] = [(air, .macOS), (tower, .windows)]
        func count(_ q: [String: String]) -> Int { pairs.filter { ReportLinkFilter(report: "hardware", query: q).matches(hardware: $0.0, platform: $0.1) }.count }
        #expect(count(["arch": "Apple Silicon"]) == 1)
        #expect(count(["storage": "low"]) == 1)
        #expect(count(["memory": "le8"]) == 1)
        #expect(count(["type": "laptop"]) == 1)
        #expect(count(["type": "desktop"]) == 1)
    }
}

@Suite struct OSCurrencyTests {
    private func row(_ os: String, _ version: String?, platform: String) -> SystemReportRow {
        var obj: [String: JSONValue] = ["operatingSystem": .string(os), "platform": .string(platform)]
        if let version { obj["osVersion"] = .string(version) }
        return SystemReportRow(json: .object(obj))
    }

    @Test func latestPatchIsTheHighestSeenPerMajor() {
        let rows = [
            row("macOS", "27.0.1", platform: "macOS"), row("macOS", "27.0", platform: "macOS"),
            row("macOS", "26.4", platform: "macOS"), row("macOS", "26.7.1", platform: "macOS"), row("macOS", "26.4", platform: "macOS"),
            row("macOS", "15.7.1", platform: "macOS"), row("macOS", "14.6", platform: "macOS"),
            row("Windows 10 Enterprise 22H2", "10.0.19045", platform: "Windows"), row("Windows 11 Enterprise 25H2", "10.0.26200", platform: "Windows"),
        ]
        let currency = OSCurrency(rows: rows)
        #expect(currency.latestByMajor[26] == "26.7.1")
        let stats = DashboardInsights.osCurrency(rows, currency: currency)
        #expect(stats.macTotal == 7)
        #expect(stats.onLatest == 4)
        #expect(stats.behind == 3)
        // 15 is two majors behind 27 (26 follows 15), so only 14 is unsupported.
        #expect(stats.unsupported == 1)
        #expect(stats.windows10 == 1)
        #expect(stats.lagging.first == DashboardInsights.NamedCount(name: "26.4", count: 2))
        func count(_ q: [String: String]) -> Int { rows.filter { ReportLinkFilter(report: "system", query: q).matches(system: $0, currency: currency) }.count }
        #expect(count(["patch": "behind"]) == stats.behind)
        #expect(count(["os": "unsupported"]) == stats.unsupported)
        #expect(count(["os": "windows10"]) == stats.windows10)
        #expect(count(["osVersion": "26.4"]) == 2)
    }

    @Test func rapidSecurityResponseCountsAsNewer() {
        let rows = [row("macOS", "26.3.1", platform: "macOS"), row("macOS", "26.3.1 (a)", platform: "macOS")]
        #expect(OSCurrency(rows: rows).latestByMajor[26] == "26.3.1 (a)")
    }

    @Test func uptimeAndPendingBucketsByKey() {
        let r = SystemReportRow(json: json(#"{"operatingSystem": "macOS", "uptime": 90000, "pendingUpdatesCount": 3, "deferredUpdatesCount": 1}"#))
        let currency = OSCurrency(rows: [r])
        #expect(ReportLinkFilter(report: "system", query: ["uptime": "1-3d"]).matches(system: r, currency: currency))
        #expect(!ReportLinkFilter(report: "system", query: ["uptime": "lt1d"]).matches(system: r, currency: currency))
        #expect(ReportLinkFilter(report: "system", query: ["pending": "1-5", "deferred": "1"]).matches(system: r, currency: currency))
    }
}

@Suite struct InsightAggregationTests {
    private func record(_ serial: String, _ name: String, status: String, installed: String? = nil, latest: String? = nil, source: String = "munki") -> InstallRecord {
        var obj: [String: JSONValue] = ["serialNumber": .string(serial), "itemName": .string(name), "currentStatus": .string(status), "source": .string(source)]
        if let installed { obj["installedVersion"] = .string(installed) }
        if let latest { obj["latestVersion"] = .string(latest) }
        return InstallRecord(json: .object(obj))
    }

    @Test func topFailingCountsDevicesPerItem() {
        let rows = [
            record("SAMPLE1", "Firefox", status: "Error"), record("SAMPLE2", "Firefox", status: "install_failed"),
            record("SAMPLE1", "Zoom", status: "Error"), record("SAMPLE3", "Zoom", status: "Installed"),
            record("SAMPLE1", "managed_apps", status: "Error"),
        ]
        #expect(DashboardInsights.topFailingItems(rows) == [.init(name: "Firefox", count: 2), .init(name: "Zoom", count: 1)])
    }

    @Test func behindCountsInstalledVersusLatest() {
        let rows = [
            record("SAMPLE1", "Chrome", status: "Installed", installed: "140.0", latest: "141.0"),
            record("SAMPLE2", "Chrome", status: "Installed", installed: "141.0", latest: "141.0"),
            record("SAMPLE3", "Slack", status: "Installed", installed: "4.1", latest: "4.2", source: "other"),
        ]
        #expect(DashboardInsights.topBehindItems(rows) == [.init(name: "Chrome", count: 1)])
    }

    @Test func staleAgentsOverAWeek() {
        let agents = [StaleAgent(serialNumber: "SAMPLE1", staleDays: 1.5), StaleAgent(serialNumber: "SAMPLE2", staleDays: 8), StaleAgent(serialNumber: "SAMPLE3", staleDays: 40)]
        #expect(DashboardInsights.staleAgentCount(agents) == 2)
        #expect(InstallsStale.serials(agents) == ["SAMPLE2", "SAMPLE3"])
        let options = InstallsFilterOptions(json: json(#"{"staleAgents": [{"serialNumber": "SAMPLE1", "staleDays": 9.5, "platform": "Windows"}], "staleAgentThresholdDays": 1}"#))
        #expect(options.staleAgents.first?.staleDays == 9.5)
        #expect(options.staleAgentThresholdDays == 1)
    }

    @Test func certificatesSoonestFirst() {
        let certs = json(#"[{"commonName": "B", "daysUntilExpiry": 20, "serialNumber": "SAMPLE1"}, {"commonName": "A", "daysUntilExpiry": 3, "serialNumber": "SAMPLE2"}, {"commonName": "B", "daysUntilExpiry": 5, "serialNumber": "SAMPLE3"}, {"commonName": "C", "daysUntilExpiry": 60, "serialNumber": "SAMPLE3"}]"#).elements
        let sec = [SecurityReportRow(json: json(#"{"expiringSoonCertCount": 2}"#), platform: .macOS), SecurityReportRow(json: json(#"{"userExpiredCertCount": 1}"#), platform: .windows)]
        let s = DashboardInsights.certificates(expiring: certs, security: sec)
        #expect(s.expiringCertificates == 3)
        #expect(s.expiringDevices == 1 && s.expiredDevices == 1)
        #expect(s.soonest.map(\.name) == ["A", "B"])
    }

    @Test func appUsageTopAndLeastUsed() {
        let apps = json(#"[{"name": "Busy", "totalHours": 100, "deviceCount": 5, "activeDeviceCount": 5, "installedDeviceCount": 10}, {"name": "Idle", "totalHours": 1, "deviceCount": 1, "activeDeviceCount": 1, "installedDeviceCount": 40}, {"name": "Rare", "totalHours": 50, "deviceCount": 1, "installedDeviceCount": 2}]"#).elements.map(UtilizationApp.init(json:))
        let r = DashboardInsights.appUsage(apps)
        #expect(r.top.map(\.name) == ["Busy", "Rare", "Idle"])
        #expect(r.least.map(\.name) == ["Idle", "Busy"])
    }

    @Test func networkAndPrinterRooms() {
        let net = [
            NetworkReportRow(json: json(#"{"raw": {"activeConnection": {"connectionType": "Ethernet"}}}"#)),
            NetworkReportRow(json: json(#"{"raw": {"activeConnection": {"connectionType": "WiFi"}}}"#)),
        ]
        let periph: [(row: PeripheralsReportRow, room: String?)] = [
            (PeripheralsReportRow(json: json(#"{"printers": [{"name": "P1"}, {"name": "P2"}], "displayDevices": [{}]}"#)), "B1120"),
            (PeripheralsReportRow(json: json(#"{"printers": [{"name": "P1"}]}"#)), "B1120"),
            (PeripheralsReportRow(json: json(#"{"printers": []}"#)), "C200"),
        ]
        let s = DashboardInsights.networkPeripherals(network: net, peripherals: periph)
        #expect(s.wired == 1 && s.wifi == 1)
        #expect(s.printers == 3 && s.printerDevices == 2 && s.displays == 1)
        #expect(s.printerRooms == [.init(name: "B1120", count: 2)])
        let filter = ReportLinkFilter(report: "peripherals", query: ["kind": "printers", "room": "B1120"])
        #expect(periph.filter { filter.matches(peripherals: $0.row, room: $0.room) }.count == 2)
    }
}
