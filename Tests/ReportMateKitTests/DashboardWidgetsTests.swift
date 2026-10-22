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
        #expect(rows.filter { r in ReportLinkFilter(report: "identity", query: ["admins": "extra"]).matches(identity: r) }.count == 1)
        #expect(rows.filter { r in ReportLinkFilter(report: "identity", query: ["join": "hybrid"]).matches(identity: r) }.count == 1)
        #expect(rows.filter { r in ReportLinkFilter(report: "identity", query: ["usage": "shared"]).matches(identity: r) }.count == 1)
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
        func count(_ v: String) -> Int { rows.filter { r in ReportLinkFilter(report: "identity", query: ["admins": v]).matches(identity: r) }.count }
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
@Suite struct RevisionThreeParameterTests {
    @Test func storageBucketsCapacityAndPlatform() {
        let nearlyFull = HardwareReportRow(json: json(#"{"storage": [{"size": 500000000000, "freeSpace": 20000000000}]}"#))
        let roomy = HardwareReportRow(json: json(#"{"storage": [{"size": 2000000000000, "freeSpace": 1000000000000}]}"#))
        let pairs: [(HardwareReportRow, Platform)] = [(nearlyFull, .macOS), (roomy, .windows)]
        func count(_ q: [String: String]) -> Int { pairs.filter { ReportLinkFilter(report: "hardware", query: q).matches(hardware: $0.0, platform: $0.1) }.count }
        #expect(count(["storage": "lt5"]) == 1)
        #expect(count(["storage": "20+"]) == 1)
        #expect(count(["storage": "low"]) == 1)
        #expect(count(["capacity": "512"]) == 1)
        #expect(count(["capacity": "2t+"]) == 1)
        #expect(count(["storage": "low", "platform": "Windows"]) == 0)
        #expect(count(["platform": "macOS"]) == 1)
        // The global toggle's form is not a hardware filter.
        #expect(ReportLinkFilter(report: "hardware", query: ["platform": "mac"]).params.isEmpty)
    }

    @Test func identityMacDirectoryAndPlatform() {
        let psso = IdentityReportRow(json: json(#"{"platformSSOUsers": {"deviceRegistered": true}}"#))
        let bound = IdentityReportRow(json: json(#"{"directoryServices": {"activeDirectory": {"bound": true}}}"#))
        let loose = IdentityReportRow(json: json(#"{}"#))
        #expect([psso, bound, loose].map(MacDirectory.of) == [.psso, .bound, .unbound])
        let f = ReportLinkFilter(report: "identity", query: ["directory": "unbound", "platform": "macOS"])
        #expect(f.matches(identity: loose, platform: .macOS))
        #expect(!f.matches(identity: loose, platform: .windows))
        #expect(!f.matches(identity: psso, platform: .macOS))
    }

    @Test func installsAndDevicesKeepTheirParameters() {
        #expect(ReportLinkFilter(report: "installs", query: ["agent": "munki", "filter": "pending"]).params.count == 2)
        #expect(ReportLinkFilter(report: "devices", query: ["tool": "installs", "level": "error"]).chips.map(\.label) == ["Errors", "Tool: installs"])
    }
}

/// The shapes reportmate-api `dashboard_insights.py` returns (PR #158), with SAMPLE values.
let insightsFixture = #"""
{
  "generatedAt": "2026-10-22T15:00:00.123456+00:00",
  "platform": "macOS",
  "includeArchived": false,
  "cards": {
    "installHealth": {
      "devices": 550,
      "withErrors": {"count": 6, "link": {"path": "/installs", "params": {"filter": "errors"}}},
      "withWarnings": {"count": 8, "link": {"path": "/installs", "params": {"filter": "warnings"}}},
      "errorItems": {"count": 9, "link": {"path": "/installs", "params": {"filter": "errors"}}},
      "warningItems": {"count": 218, "link": {"path": "/installs", "params": {"filter": "warnings"}}},
      "pending": {"items": 40, "devices": 12, "link": {"path": "/installs", "params": {"filter": "pending"}}},
      "silentAgents": {"count": 6, "thresholdDays": 7, "link": {"path": "/installs", "params": {"stale": "1"}}},
      "topFailing": [{"name": "Sample App", "devices": 3, "link": {"path": "/installs", "params": {"item": "Sample App", "filter": "errors"}}}],
      "byAgent": [{"agent": "munki", "name": "Munki", "platform": "macOS", "devices": 550,
                   "withErrors": {"count": 1, "link": {"path": "/installs", "params": {"filter": "errors", "agent": "munki"}}},
                   "withWarnings": {"count": 7, "link": {"path": "/installs", "params": {"filter": "warnings", "agent": "munki"}}},
                   "errorItems": {"count": 2, "link": {"path": "/installs", "params": {"filter": "errors", "agent": "munki"}}},
                   "warningItems": {"count": 100, "link": {"path": "/installs", "params": {"filter": "warnings", "agent": "munki"}}},
                   "pending": {"items": 30, "devices": 10, "link": {"path": "/installs", "params": {"filter": "pending", "agent": "munki"}}},
                   "silentAgents": {"count": 4, "link": {"path": "/installs", "params": {"stale": "1", "agent": "munki"}}}}]
    },
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
    "managementToolErrors": {
      "windowHours": 24,
      "tools": [{"tool": "installs", "name": "Munki", "platform": "macOS", "devices": 550, "devicesWithErrors": 12, "devicesWithWarnings": 40, "errorLines": 300, "warningLines": 900,
                 "link": {"path": "/devices", "params": {"tool": "installs", "level": "error", "platform": "macOS"}},
                 "warningsLink": {"path": "/devices", "params": {"tool": "installs", "level": "warning", "platform": "macOS"}}}],
      "topErrors": [{"message": "Could not download <n> bytes", "tool": "installs", "name": "Munki", "devices": 5, "lines": 40,
                     "link": {"path": "/devices", "params": {"tool": "installs", "level": "error"}},
                     "sampleDevice": {"serialNumber": "SAMPLE1", "link": {"path": "/device/SAMPLE1", "params": {"tab": "management", "tool": "installs", "level": "error"}}}}]
    },
    "storage": {
      "devices": 550,
      "freeSpace": [{"key": "lt5", "label": "Under 5% free", "count": 7, "link": {"path": "/hardware", "params": {"storage": "lt5"}}}],
      "lowStorage": {"count": 21, "link": {"path": "/hardware", "params": {"storage": "low"}},
                     "byPlatform": [{"platform": "macOS", "count": 21, "link": {"path": "/hardware", "params": {"storage": "low", "platform": "macOS"}}}]},
      "capacity": [{"key": "le256", "label": "256 GB or less", "count": 100, "link": {"path": "/hardware", "params": {"capacity": "le256"}}}],
      "fullest": [{"serialNumber": "SAMPLE2", "name": "Sample Lab", "platform": "macOS", "freePct": 1.2, "freeBytes": 3000000000, "totalBytes": 250000000000, "link": {"path": "/device/SAMPLE2", "params": {}}}]
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
    "osCurrency": {"error": "Timed out after 20s", "generatedAt": "2026-10-22T15:00:00+00:00"},
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
    "directoryJoin": {
      "views": {
        "all": {"devices": 900, "segments": [{"key": "entra", "label": "Entra joined", "count": 500, "link": {"path": "/identity", "params": {"join": "entra"}}}],
                "extraAdmins": {"count": 488, "link": {"path": "/identity", "params": {"admins": "extra"}}},
                "shared": {"count": 400, "link": {"path": "/identity", "params": {"usage": "shared"}}},
                "assigned": {"count": 300, "link": {"path": "/identity", "params": {"usage": "assigned"}}}},
        "windows": {"devices": 350, "segments": [], "extraAdmins": {"count": 10, "link": {"path": "/identity", "params": {"admins": "extra", "platform": "Windows"}}},
                    "shared": {"count": 200, "link": {"path": "/identity", "params": {"usage": "shared", "platform": "Windows"}}},
                    "assigned": {"count": 150, "link": {"path": "/identity", "params": {"usage": "assigned", "platform": "Windows"}}}},
        "mac": {"devices": 550, "segments": [{"key": "unbound", "label": "Not bound", "count": 346, "link": {"path": "/identity", "params": {"directory": "unbound", "platform": "macOS"}}}],
                "extraAdmins": {"count": 478, "link": {"path": "/identity", "params": {"admins": "extra", "platform": "macOS"}}},
                "shared": {"count": 200, "link": {"path": "/identity", "params": {"usage": "shared", "platform": "macOS"}}},
                "assigned": {"count": 150, "link": {"path": "/identity", "params": {"usage": "assigned", "platform": "macOS"}}}}
      }
    },
    "connectivityProblems": {
      "devices": 550,
      "weakSignal": {"count": 4, "link": {"path": "/network", "params": {"signal": "weak"}}},
      "poorQuality": {"count": 131, "measured": 400, "link": {"path": "/network", "params": {"quality": "poor"}}},
      "onVpn": {"count": 2, "link": {"path": "/network", "params": {"vpn": "1"}}}
    }
  }
}
"""#

let appUsageEnvelope = #"""
{"card": "appUsage", "platform": "all", "includeArchived": false, "generatedAt": "2026-10-22T15:00:00+00:00",
 "data": {"days": 30, "filters": {"usages": ["Shared"], "catalogs": []},
          "available": {"usages": [{"value": "Shared", "devices": 500}, {"value": "Assigned", "devices": 400}], "catalogs": [{"value": "Staff", "devices": 300}]},
          "link": {"path": "/applications", "params": {"type": "usage", "period": "30", "usages": "Shared"}},
          "apps": [{"name": "Sample Browser", "totalHours": 1200.5, "activeHours": 900.0, "devices": 320, "activeDevices": 300,
                    "link": {"path": "/applications/usage/Sample%20Browser", "params": {"days": "30", "usages": "Shared"}}}]}}
"""#

@Suite struct DashboardInsightsDocumentTests {
    private var doc: DashboardInsightsDocument { DashboardInsightsDocument(json: json(insightsFixture)) }

    @Test func readsEveryCard() {
        let d = doc
        #expect(d.generatedAt != nil)
        #expect(Set(DashboardInsightsDocument.cardKeys).isSubset(of: Set(d.cards.keys)))
        #expect(d.card("installHealth")?.item("pending")?.int("items") == 40)
        #expect(d.card("installHealth")?.items("byAgent").first?.json["silentAgents"]["count"].int == 4)
        #expect(d.card("managementToolErrors")?.items("tools").first?.int("devicesWithErrors") == 12)
        #expect(d.card("storage")?.item("lowStorage")?.items("byPlatform").first?.count == 21)
        #expect(d.card("directoryJoin")?.item("views")?.json["mac"]["devices"].int == 550)
        #expect(d.card("checkinGaps")?.bool("checkinsAllPlatforms") == true)
    }

    @Test func aFailedCardCarriesItsError() {
        #expect(doc.card("osCurrency")?.error == "Timed out after 20s")
        #expect(doc.card("rebootDebt")?.error == nil)
    }

    @Test func serverLinksBecomeAppLinks() {
        let d = doc
        #expect(d.card("rebootDebt")?.item("pendingUpdates")?.link?.url.absoluteString == "reportmate://system?pending=1-5,6-10,10+")
        #expect(d.card("installHealth")?.items("topFailing").first?.link == DashboardLinks.installs(item: "Sample App", filter: "errors"))
        let sample = d.card("managementToolErrors")?.items("topErrors").first?.item("sampleDevice")?.link
        #expect(sample?.target == .device(serial: "SAMPLE1", tab: "management"))
        #expect(sample?.query == ["tool": "installs", "level": "error"])
        #expect(d.card("storage")?.items("freeSpace").first?.link?.query == ["storage": "lt5"])
    }

    @Test func perCardEnvelope() {
        let card = DashboardInsightsDocument.card(fromEnvelope: json(appUsageEnvelope))
        #expect(card.error == nil)
        #expect(card.items("apps").first?.name == "Sample Browser")
        #expect(card.item("available")?.items("usages").map { $0.string("value") } == ["Shared", "Assigned"])
        #expect(card.items("apps").first?.link?.query == ["days": "30", "usages": "Shared"])
        let failed = DashboardInsightsDocument.card(fromEnvelope: json(#"{"card": "storage", "data": {"error": "Database unavailable"}}"#))
        #expect(failed.error == "Database unavailable")
    }

    @Test func platformParameter() {
        #expect(DashboardInsightsDocument.platformParameter(.all) == "all")
        #expect(DashboardInsightsDocument.platformParameter(.windows) == "Windows")
    }
}

@Suite struct RevisionFourTests {
    @Test func messagesLoseTheirTimestampAndLevel() {
        #expect(ManagementToolMessages.normalize("<ts> -<n>:<n> [ERR] Device registration failed for <guid>") == "Device registration failed for <guid>")
        #expect(ManagementToolMessages.normalize("2026-10-22T09:12:01Z [WARN] Retry later") == "Retry later")
        #expect(ManagementToolMessages.normalize("Plain message") == "Plain message")
    }

    @Test func duplicatesGroupAndMDMIsDropped() {
        let card = InsightCardData(json: json(#"""
        {"tools": [{"tool": "mdm", "name": "Intune", "devicesWithErrors": 300}, {"tool": "installs", "name": "Munki", "devicesWithErrors": 4}],
         "topErrors": [
           {"message": "<ts> -<n>:<n> [ERR] Device registration failed for <guid>", "tool": "installs", "name": "Munki", "devices": 2, "lines": 5},
           {"message": "<ts> +<n>:<n> [ERR] Device registration failed for <guid>", "tool": "installs", "name": "Munki", "devices": 3, "lines": 7},
           {"message": "Enrollment check failed", "tool": "mdm", "name": "Intune", "devices": 90, "lines": 900}
         ]}
        """#))
        #expect(ManagementToolMessages.tools(card).map { $0.string("tool") } == ["installs"])
        let top = ManagementToolMessages.topErrors(card)
        #expect(top.count == 1)
        #expect(top.first?.message == "Device registration failed for <guid>")
        #expect(top.first?.devices == 5 && top.first?.lines == 12)
    }

    @Test func renamedCardsAnswerUnderTheirNewKeys() {
        #expect(DashboardInsightsDocument(json: json(#"{"cards": {"osCurrency": {"rated": 1}}}"#)).card("updateDebt")?.int("rated") == 1)
        #expect(DashboardInsightsDocument.cardKeys.contains("updateDebt") && !DashboardInsightsDocument.cardKeys.contains("osCurrency"))
        let doc = DashboardInsightsDocument(json: json(#"{"cards": {"managementToolErrors": {"tools": []}, "directoryJoin": {"views": {}}}}"#))
        #expect(doc.card("managementToolLogs") != nil)
        #expect(doc.card("directoryServices") != nil)
    }

    @Test func directoryUsesTheIdentityReportClasses() {
        let cloud = IdentityReportRow(json: json(#"{"directoryServices": {"azureAd": {"joined": true}}}"#))
        let domain = IdentityReportRow(json: json(#"{"directoryServices": {"activeDirectory": {"bound": true}}, "domainTrust": {"trustStatus": "Broken"}}"#))
        let standard = IdentityReportRow(json: json(#"{}"#))
        func hit(_ row: IdentityReportRow, _ key: String) -> Bool { ReportLinkFilter(report: "identity", query: ["directory": key]).matches(identity: row, platform: .windows) }
        #expect(hit(cloud, "Cloud Joined") && hit(cloud, "cloud-joined"))
        #expect(hit(domain, "domain-joined") && hit(domain, "Broken") && !hit(domain, "trusted"))
        #expect(hit(standard, "standard"))
        #expect(IdentityDirectory.label("unconfirmed") == "Unconfirmed")
        #expect(ReportLinkFilter.label(key: "directory", value: "cloud-joined") == "Directory: Cloud Joined")
    }
}

@Suite struct DirectoryServicesCardTests {
    /// The final `directoryServices` card the web and Windows apps read.
    let card = InsightCardData(json: json(#"""
    {"generatedAt": "2026-10-22T17:00:00+00:00", "total": 900,
     "segments": [
       {"key": "cloud", "label": "Cloud Joined", "count": 500, "link": {"path": "/identity", "params": {"directory": "cloud"}}},
       {"key": "domain", "label": "Domain Joined", "count": 60, "link": {"path": "/identity", "params": {"directory": "domain"}},
        "children": [
          {"key": "trusted", "label": "Trusted", "count": 40, "link": {"path": "/identity", "params": {"directory": "trusted"}}},
          {"key": "unconfirmed", "label": "Unconfirmed", "count": 15, "link": {"path": "/identity", "params": {"directory": "unconfirmed"}}},
          {"key": "broken", "label": "Broken", "count": 5, "link": {"path": "/identity", "params": {"directory": "broken"}}}]},
       {"key": "standard", "label": "Standard", "count": 300, "link": {"path": "/identity", "params": {"directory": "standard"}}},
       {"key": "unjoined", "label": "Unjoined", "count": 40, "link": {"path": "/identity", "params": {"directory": "unjoined"}}}],
     "extraAdmins": {"count": 488, "link": {"path": "/identity", "params": {"admins": "extra"}}},
     "shared": {"count": 538, "link": {"path": "/identity", "params": {"usage": "shared"}}},
     "assigned": {"count": 342, "link": {"path": "/identity", "params": {"usage": "assigned"}}}}
    """#))

    @Test func readsSegmentsChildrenAndChips() {
        #expect(card.error == nil)
        #expect(card.int("total") == 900)
        let segments = card.items("segments")
        #expect(segments.map(\.key) == ["cloud", "domain", "standard", "unjoined"])
        #expect(segments.map(\.count).reduce(0, +) == 900)
        let domain = segments[1]
        #expect(domain.items("children").map(\.key) == ["trusted", "unconfirmed", "broken"])
        #expect(domain.items("children").map(\.count).reduce(0, +) == domain.count)
        #expect(domain.items("children").last?.link?.url.absoluteString == "reportmate://identity?directory=broken")
        #expect(card.item("extraAdmins")?.count == 488)
        #expect(card.item("shared")?.link?.query == ["usage": "shared"])
        #expect(card.item("assigned")?.count == 342)
    }

    @Test func everyLinkFiltersTheIdentityReport() {
        let cloud = IdentityReportRow(json: json(#"{"directoryServices": {"azureAd": {"joined": true}}}"#))
        let broken = IdentityReportRow(json: json(#"{"directoryServices": {"activeDirectory": {"bound": true}}, "domainTrust": {"trustStatus": "Broken"}}"#))
        let trusted = IdentityReportRow(json: json(#"{"directoryServices": {"activeDirectory": {"bound": true}}, "domainTrust": {"trustStatus": "Healthy"}}"#))
        let standard = IdentityReportRow(json: json(#"{}"#))
        let unjoined = IdentityReportRow(json: json(#"{"directoryServices": {"workgroup": "WORKGROUP"}}"#))
        let rows = [cloud, broken, trusted, standard, unjoined]
        func count(_ link: DeepLink?) -> Int {
            guard let link else { return -1 }
            let f = ReportLinkFilter(report: "identity", query: link.query)
            return rows.filter { f.matches(identity: $0, platform: .windows) }.count
        }
        let segments = card.items("segments")
        #expect(segments.map { count($0.link) } == [1, 2, 1, 1])
        #expect(segments[1].items("children").map { count($0.link) } == [1, 0, 1])
        #expect(ReportLinkFilter.label(key: "directory", value: "cloud") == "Directory: Cloud Joined")
        #expect(IdentityDirectory.label("domain") == "Domain Joined")
    }
}

@Suite struct MacSecuritySpellingTests {
    private func info(_ security: String) -> SecurityInfo {
        SecurityInfo(modules: json(#"{"security": \#(security)}"#), platform: .macOS)
    }

    @Test func readsTheMacClientsSpellings() {
        let client = info(#"""
        {"firewall": {"stealthModeEnabled": true, "allowSignedEnabled": true},
         "securityReleaseInfo": {"updateName": "macOS 26.4", "osVersion": "26.4"},
         "unpatchedCVEs": [{"cve": "CVE-2026-0001", "activelyExploited": true}, "CVE-2026-0002"]}
        """#)
        #expect(client.firewallStealthMode)
        #expect(client.firewallAllowsSigned)
        #expect(client.sofaRelease?.updateName == "macOS 26.4")
        #expect(client.cves.filter { $0.source == .sofa }.map(\.cve) == ["CVE-2026-0001", "CVE-2026-0002"])
        #expect(client.cves.first?.activelyExploited == true)
        #expect(client.cves.last?.osVersion == "26.4")
    }

    @Test func stillReadsTheWebSpellings() {
        let web = info(#"""
        {"firewall": {"stealthMode": true, "allowSignedSoftware": false},
         "sofaSecurityReleaseInfo": {"updateName": "macOS 26.5"},
         "sofaUnpatchedCves": [{"cve": "CVE-2026-0003"}]}
        """#)
        #expect(web.firewallStealthMode)
        #expect(!web.firewallAllowsSigned)
        #expect(web.sofaRelease?.updateName == "macOS 26.5")
        #expect(web.cves.map(\.cve).contains("CVE-2026-0003"))
    }
}

@Suite struct SafeLinkTests {
    @Test func opensOnlyWebURLsWithAHost() {
        #expect(SafeLink.url("https://support.apple.com/en-us/100100")?.host == "support.apple.com")
        #expect(SafeLink.url("http://example.com/notes") != nil)
        #expect(SafeLink.url(" https://example.com ") != nil)
        #expect(SafeLink.url("file:///etc/passwd") == nil)
        #expect(SafeLink.url("javascript:alert(1)") == nil)
        #expect(SafeLink.url("x-apple.systempreferences:com.apple.preference.security") == nil)
        #expect(SafeLink.url("reportmate://device/SAMPLE1") == nil)
        #expect(SafeLink.url("https:///no-host") == nil)
        #expect(SafeLink.url("/relative/path") == nil)
        #expect(SafeLink.url("") == nil)
        #expect(SafeLink.url(nil as String?) == nil)
    }

    @Test func deviceValuesStayInsideTheirPage() {
        let url = SafeLink.url(base: "https://msrc.microsoft.com/update-guide/vulnerability/", component: "CVE-2026-0001")
        #expect(url?.absoluteString == "https://msrc.microsoft.com/update-guide/vulnerability/CVE-2026-0001")
        let sneaky = SafeLink.url(base: "https://support.microsoft.com/help/", component: "123/../../evil?x=1#y")
        #expect(sneaky?.host == "support.microsoft.com")
        #expect(sneaky?.query == nil && sneaky?.fragment == nil)
        #expect(SafeLink.url(base: "https://support.microsoft.com/help/", component: "  ") == nil)
    }
}

@Suite struct CompactHoursTests {
    @Test func shortensLikeTheWebCard() {
        #expect(CompactHours.format(950) == "950 h")
        #expect(CompactHours.format(0.4) == "0 h")
        #expect(CompactHours.format(1_234) == "1.2k h")
        #expect(CompactHours.format(1_000) == "1k h")
        #expect(CompactHours.format(12_345) == "12k h")
        #expect(CompactHours.format(328_089) == "328k h")
        #expect(CompactHours.format(1_400_000) == "1.4M h")
    }
}
