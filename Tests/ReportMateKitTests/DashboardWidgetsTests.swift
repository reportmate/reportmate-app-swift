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
        #expect(rows.filter { m in unmanaged.matches(management: m) }.count == 1)
        #expect(rows.filter { m in ReportLinkFilter(report: "management", query: ["enrolled": "1"]).matches(management: m) }.count == 1)
        #expect(rows.filter { m in ReportLinkFilter(report: "management", query: ["enrollmentType": "Automated"]).matches(management: m) }.count == 1)
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
        let rows = [entra, hybrid, domain, workgroup]
        #expect(rows.filter(ReportLinkFilter(report: "identity", query: ["admins": "extra"]).matches(identity:)).count == 1)
        #expect(rows.filter(ReportLinkFilter(report: "identity", query: ["join": "hybrid"]).matches(identity:)).count == 1)
        #expect(rows.filter(ReportLinkFilter(report: "identity", query: ["usage": "shared"]).matches(identity:)).count == 1)
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
        #expect(rows.filter(currency.isOnLatest).count == 4)
        #expect(rows.filter(currency.isBehind).count == 3)
        // 15 is two majors behind 27 (26 follows 15), so only 14 is unsupported.
        #expect(rows.filter(currency.isUnsupported).count == 1)
        func count(_ q: [String: String]) -> Int { rows.filter { ReportLinkFilter(report: "system", query: q).matches(system: $0, currency: currency) }.count }
        #expect(count(["patch": "behind"]) == 3)
        #expect(count(["os": "unsupported"]) == 1)
        #expect(count(["os": "windows10"]) == 1)
        #expect(count(["osVersion": "26.4.0"]) == 2)
    }

    @Test func aBetaOnOneMacDoesNotSetTheLatestPatch() {
        let rows = [row("macOS", "27.2", platform: "macOS")]
            + Array(repeating: row("macOS", "27.0.1", platform: "macOS"), count: 6)
            + Array(repeating: row("macOS", "27.0", platform: "macOS"), count: 5)
        let currency = OSCurrency(rows: rows)
        #expect(currency.latestByMajor[27] == "27.0.1")
        #expect(rows.filter(currency.isOnLatest).count == 7)
        #expect(rows.filter(currency.isBehind).count == 5)
    }

    @Test func unsupportedCountsFromAnEstablishedMajor() {
        let rows = [row("macOS", "28.0", platform: "macOS")]
            + Array(repeating: row("macOS", "27.0.1", platform: "macOS"), count: 5)
            + [row("macOS", "15.7", platform: "macOS"), row("macOS", "14.6", platform: "macOS")]
        let currency = OSCurrency(rows: rows)
        #expect(currency.newestOrdinal == 17)
        #expect(rows.filter(currency.isUnsupported).count == 1)
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


@Suite struct ReportParameterTests {
    @Test func managementPlatformAndLastSeen() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let m = ManagementReportRow(json: json(#"{"isEnrolled": false}"#))
        func hit(_ q: [String: String], _ platform: Platform, _ hoursAgo: Double?) -> Bool {
            ReportLinkFilter(report: "management", query: q).matches(management: m, platform: platform, lastSeen: hoursAgo.map { now.addingTimeInterval(-$0 * 3600) }, now: now)
        }
        #expect(hit(["platform": "macOS"], .macOS, 1))
        #expect(!hit(["platform": "Windows"], .macOS, 1))
        #expect(hit(["lastSeen": "24h"], .macOS, 2))
        #expect(!hit(["lastSeen": "24h"], .macOS, 30))
        #expect(hit(["lastSeen": "1-7d"], .windows, 30))
        #expect(hit(["lastSeen": "7d+"], .windows, 200))
        #expect(hit(["lastSeen": "7d+"], .windows, nil))
        #expect(hit(["platform": "Windows", "enrolled": "0", "lastSeen": "1-7d"], .windows, 48))
        let f = ReportLinkFilter(report: "management", query: ["platform": "macOS", "lastSeen": "7d+"])
        #expect(f.chips.map(\.label) == ["Last seen: over 7 days ago", "Platform: macOS"])
    }

    @Test func identityExactAdminCounts() {
        let rows = [1, 2, 3, 4, 6].map { n in IdentityReportRow(json: json("{\"summary\": {\"adminUsers\": \(n)}}")) }
        func count(_ v: String) -> Int { rows.filter(ReportLinkFilter(report: "identity", query: ["admins": v]).matches(identity:)).count }
        #expect(count("2") == 1)
        #expect(count("3") == 1)
        #expect(count("4+") == 2)
        #expect(count("extra") == 4)
        #expect(ReportLinkFilter.label(key: "admins", value: "4+") == "Local admins: 4+")
    }

    @Test func managementPlatformLinkParses() {
        let link = DeepLink(url: URL(string: "reportmate://management?platform=Windows&lastSeen=1-7d&enrolled=0")!)
        #expect(link?.query == ["platform": "Windows", "lastSeen": "1-7d", "enrolled": "0"])
        #expect(link.map { ReportLinkFilter(report: "management", query: $0.query).params.count } == 3)
    }

    @Test func staleAgentsOverAWeek() {
        let agents = [StaleAgent(serialNumber: "SAMPLE1", staleDays: 1.5), StaleAgent(serialNumber: "SAMPLE2", staleDays: 8), StaleAgent(serialNumber: "SAMPLE3", staleDays: 40)]
        #expect(InstallsStale.serials(agents) == ["SAMPLE2", "SAMPLE3"])
        let options = InstallsFilterOptions(json: json(#"{"staleAgents": [{"serialNumber": "SAMPLE1", "staleDays": 9.5, "platform": "Windows"}], "staleAgentThresholdDays": 1}"#))
        #expect(options.staleAgents.first?.staleDays == 9.5)
    }

    @Test func networkQualityAndVpn() {
        let rows = [
            NetworkReportRow(json: json(#"{"raw": {"networkQuality": {"rating": "Low"}, "activeConnection": {"connectionType": "Ethernet"}}}"#)),
            NetworkReportRow(json: json(#"{"raw": {"networkQuality": {"dlRating": "low"}, "activeConnection": {"connectionType": "WiFi", "isVpnActive": true}}}"#)),
            NetworkReportRow(json: json(#"{"raw": {"networkQuality": {"rating": "High", "dlRating": "low"}}}"#)),
        ]
        func count(_ q: [String: String]) -> Int { rows.filter(ReportLinkFilter(report: "network", query: q).matches(network:)).count }
        #expect(count(["quality": "poor"]) == 2)
        #expect(count(["vpn": "1"]) == 1)
        #expect(count(["connection": "wired"]) == 1)
    }
}

/// The shape reportmate-api `dashboard_insights.py` returns (its shape_* functions and
/// tests/test_dashboard_insights.py), with SAMPLE values.
let insightsFixture = #"""
{
  "generatedAt": "2026-10-22T15:00:00.123456+00:00",
  "platform": "macOS",
  "includeArchived": false,
  "computeSeconds": 1.42,
  "cards": {
    "rebootDebt": {
      "devices": 550,
      "uptime30dPlus": {"count": 30, "link": {"path": "/system", "params": {"uptime": "30d+"}}},
      "uptime2to4w": {"count": 112, "link": {"path": "/system", "params": {"uptime": "2-4w"}}},
      "pendingUpdates": {"count": 315, "link": {"path": "/system", "params": {"pending": "1-5,6-10,10+"}}},
      "deferredUpdates": {"count": 290, "link": {"path": "/system", "params": {"deferred": "1"}}},
      "uptimeBuckets": [{"key": "lt1d", "label": "< 1 day", "count": 250, "link": {"path": "/system", "params": {"uptime": "lt1d"}}}]
    },
    "protectionGaps": {
      "devices": 550,
      "gaps": [
        {"key": "firewall", "label": "Firewall off", "count": 536, "total": 550, "link": {"path": "/security", "params": {"firewall": "off"}}},
        {"key": "encryption", "label": "Disk encryption off", "count": 9, "total": 550, "link": {"path": "/security", "params": {"encryption": "off"}}}
      ],
      "withThreats": {"count": 0, "link": {"path": "/security", "params": {"threats": "1"}}},
      "criticalCves": {"count": 3, "link": {"path": "/security", "params": {"cve": "critical"}}}
    },
    "unmanagedDevices": {
      "devices": 550,
      "unmanaged": {"count": 11, "pct": 2, "link": {"path": "/management", "params": {"enrolled": "0"}}},
      "enrolledPct": 98,
      "byPlatform": [{"platform": "macOS", "count": 11, "devices": 550, "link": {"path": "/management", "params": {"enrolled": "0"}}}],
      "lastSeen": [{"key": "24h", "label": "Seen in the last 24 hours", "count": 4, "link": {"path": "/management", "params": {"enrolled": "0"}}}],
      "recent": [{"serialNumber": "SAMPLE1", "name": "Sample Mac", "platform": "macOS", "lastSeen": "2026-10-22T14:00:00+00:00", "link": {"path": "/device/SAMPLE1", "params": {}}}]
    },
    "hardwareAtRisk": {
      "devices": 550,
      "lowStorage": {"count": 21, "link": {"path": "/hardware", "params": {"storage": "low"}}},
      "lowMemory": {"count": 0, "link": {"path": "/hardware", "params": {"memory": "le8"}}},
      "intelMacs": {"count": 5, "macs": 550, "link": {"path": "/hardware", "params": {"arch": "Intel"}}}
    },
    "installHealth": {
      "devices": 550,
      "withErrors": {"count": 1, "link": {"path": "/installs", "params": {"filter": "errors"}}},
      "withWarnings": {"count": 7, "link": {"path": "/installs", "params": {"filter": "warnings"}}},
      "topFailing": [{"name": "Sample App", "devices": 3, "link": {"path": "/installs", "params": {"item": "Sample App", "filter": "errors"}}}],
      "silentAgents": {"count": 6, "thresholdDays": 7, "link": {"path": "/installs", "params": {"stale": "1"}}}
    },
    "checkinGaps": {
      "hours": 24,
      "checkinsAllPlatforms": true,
      "rejected": {"count": 22, "link": {"path": "/events/failures", "params": {"hours": "24"}}},
      "retried": {"count": 30, "link": {"path": "/events/failures", "params": {"hours": "24", "outcome": "retried"}}},
      "accepted": {"count": 40, "link": {"path": "/events/failures", "params": {"hours": "24", "outcome": "accepted"}}},
      "reasons": [{"reason": "malformed_json", "count": 4, "devices": 1, "link": {"path": "/events/failures", "params": {"hours": "24", "reason": "malformed_json"}}}],
      "stale": {"count": 31, "link": {"path": "/devices", "params": {"status": "stale"}}},
      "missing": {"count": 84, "link": {"path": "/devices", "params": {"status": "missing"}}}
    },
    "osCurrency": {"error": "statement timeout"},
    "softwareRisk": {
      "devices": 550,
      "criticalCves": {"count": 3, "link": {"path": "/security", "params": {"cve": "critical"}}},
      "exploitedCves": {"count": 1, "link": {"path": "/security", "params": {"cve": "exploited"}}},
      "itemsBehind": [{"name": "Sample Browser", "devices": 40, "link": {"path": "/installs", "params": {"item": "Sample Browser"}}}]
    },
    "expiringCertificates": {
      "devices": 550,
      "windowDays": 30,
      "expiring": {"certificates": 42, "devices": 27, "link": {"path": "/security", "params": {"certs": "expiring"}}},
      "expiredUser": {"devices": 0, "link": {"path": "/security", "params": {"certs": "expired"}}},
      "soonest": [{"commonName": "Sample CA", "daysUntilExpiry": 1, "devices": 12, "link": {"path": "/security", "params": {"certSearch": "Sample CA", "certStatus": "expiring"}}}]
    },
    "localAdminExposure": {
      "devices": 544,
      "extraAdmins": {"count": 488, "link": {"path": "/identity", "params": {"admins": "extra"}}},
      "byAdminCount": [{"key": "2", "label": "2 admins", "count": 300, "link": {"path": "/identity", "params": {"admins": "extra"}}}],
      "topDevices": [{"serialNumber": "SAMPLE2", "name": "Sample Lab", "platform": "macOS", "admins": 7, "link": {"path": "/device/SAMPLE2", "params": {}}}],
      "join": [{"key": "entra", "label": "Entra joined", "count": 198, "link": {"path": "/identity", "params": {"join": "entra"}}}],
      "workgroup": {"count": 346, "link": {"path": "/identity", "params": {"join": "workgroup"}}, "byPlatform": [{"platform": "macOS", "count": 346}]}
    },
    "unusedSoftware": {
      "days": 30,
      "minInstalls": 10,
      "leastUsed": [{"name": "Sample Suite", "activeDevices": 1, "installedDevices": 40, "usageRate": 0.025, "link": {"path": "/applications/usage/Sample%20Suite", "params": {"days": "30"}}}],
      "mostUsed": [{"name": "Sample Browser", "totalHours": 1200.5, "activeHours": 900.0, "activeDevices": 300, "link": {"path": "/applications/usage/Sample%20Browser", "params": {"days": "30"}}}]
    },
    "connectivityProblems": {
      "devices": 550,
      "weakSignal": {"count": 4, "link": {"path": "/network", "params": {"signal": "weak"}}},
      "poorQuality": {"count": 131, "measured": 400, "link": {"path": "/network", "params": {}}},
      "onVpn": {"count": 2, "link": {"path": "/network", "params": {}}}
    }
  }
}
"""#

@Suite struct DashboardInsightsDocumentTests {
    private var doc: DashboardInsightsDocument { DashboardInsightsDocument(json: json(insightsFixture)) }

    @Test func readsEveryCard() {
        let d = doc
        #expect(d.generatedAt != nil)
        #expect(d.platform == "macOS")
        #expect(Set(d.cards.keys) == Set(DashboardInsightsDocument.cardKeys))
        #expect(d.card("rebootDebt")?.item("uptime30dPlus")?.count == 30)
        #expect(d.card("protectionGaps")?.items("gaps").map(\.key) == ["firewall", "encryption"])
        #expect(d.card("protectionGaps")?.items("gaps").first?.int("total") == 550)
        #expect(d.card("unmanagedDevices")?.item("unmanaged")?.int("pct") == 2)
        #expect(d.card("installHealth")?.items("topFailing").first?.name == "Sample App")
        #expect(d.card("installHealth")?.items("topFailing").first?.count == 3)
        #expect(d.card("expiringCertificates")?.item("expiring")?.int("certificates") == 42)
        #expect(d.card("unusedSoftware")?.items("mostUsed").first?.double("totalHours") == 1200.5)
        #expect(d.card("checkinGaps")?.bool("checkinsAllPlatforms") == true)
    }

    @Test func aFailedCardCarriesItsError() {
        #expect(doc.card("osCurrency")?.error == "statement timeout")
        #expect(doc.card("rebootDebt")?.error == nil)
    }

    @Test func serverLinksBecomeAppLinks() {
        let d = doc
        #expect(d.card("unmanagedDevices")?.item("unmanaged")?.link?.url.absoluteString == "reportmate://management?enrolled=0")
        #expect(d.card("rebootDebt")?.item("pendingUpdates")?.link?.url.absoluteString == "reportmate://system?pending=1-5,6-10,10+")
        #expect(d.card("installHealth")?.items("topFailing").first?.link == DashboardLinks.installs(item: "Sample App", filter: "errors"))
        #expect(d.card("checkinGaps")?.items("reasons").first?.link == DashboardLinks.failures(hours: 24, reason: "malformed_json"))
        #expect(d.card("unusedSoftware")?.items("leastUsed").first?.link == DashboardLinks.applicationUsage("Sample Suite"))
        #expect(d.card("localAdminExposure")?.items("topDevices").first?.link?.target == .device(serial: "SAMPLE2", tab: nil))
        #expect(d.card("expiringCertificates")?.items("soonest").first?.link?.query == ["certSearch": "Sample CA", "certStatus": "expiring"])
    }

    @Test func platformParameter() {
        #expect(DashboardInsightsDocument.platformParameter(.all) == "all")
        #expect(DashboardInsightsDocument.platformParameter(.macOS) == "macOS")
        #expect(DashboardInsightsDocument.platformParameter(.windows) == "Windows")
    }
}
