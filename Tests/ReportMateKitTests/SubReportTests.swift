import Testing
import Foundation
@testable import ReportMateKit

// Fixtures are shaped from the API's real responses with invented, neutral values.

private func json(_ text: String) -> JSONValue { try! JSONValue.parse(Data(text.utf8)) }

private let scope = #""options": {"usages": ["Shared"], "catalogs": ["Lab"], "areas": [], "fleets": [], "locations": ["Building A"], "rooms": ["A101"], "inventoryStates": ["checked_out"]}"#
private let device = #""serialNumber": "TESTSERIAL01", "deviceName": "Test Mac", "platform": "macOS", "assetTag": "A0001", "usage": "Shared", "catalog": "Lab", "area": null, "fleet": null, "location": "Building A", "room": "A101", "archived": false, "inventoryState": "checked_out", "lastSeen": "2026-01-02T10:00:00Z", "collectedAt": "2026-01-02T09:00:00Z""#

@Suite struct ReportParamsTests {
    @Test func dropsTabPlatformAndEmptyValues() {
        let p = ReportParams(["tab": "services", "platform": "mac", "states": " ", "search": "lab"])
        #expect(p.values == ["search": "lab"])
    }

    @Test func readsJSONAndCommaLists() {
        var p = ReportParams()
        p.setJSONList("serviceNames", ["Print Spooler", "a,b"])
        #expect(p.jsonList("serviceNames") == ["Print Spooler", "a,b"])
        p["legacy"] = "x, y"
        #expect(p.jsonList("legacy", commaFallback: true) == ["x", "y"])
        #expect(p.jsonList("legacy").isEmpty)
        p.toggle("states", "running"); p.toggle("states", "stopped"); p.toggle("states", "running")
        #expect(p.list("states") == ["stopped"])
        #expect(ReportParams(["items": "[not json"]).jsonList("items").isEmpty)
    }

    @Test func viewKeepsDeviceColumnAndFallsBackToDefaultSort() {
        let v = ReportView(params: ReportParams(["columns": "state", "sort": "lastSeen", "direction": "desc"]), available: ["deviceName", "state", "lastSeen"], defaults: ["deviceName"])
        #expect(v.columns == ["deviceName", "state"])
        #expect(v.sort == "deviceName")
        #expect(!v.ascending)
    }

    @Test func unknownValuesSortLastInBothDirections() {
        let col = ReportColumn<Int?>("n", "N", kind: .number, value: { $0.map(String.init) }, sortKey: { $0.map { .number(Double($0)) } })
        let rows: [Int?] = [nil, 2, 1]
        #expect(ReportSorting.sort(rows, by: col, ascending: true, tiebreak: { _ in "" }) == [1, 2, nil])
        #expect(ReportSorting.sort(rows, by: col, ascending: false, tiebreak: { _ in "" }) == [2, 1, nil])
    }
}

@Suite struct PagedReportTests {
    private func page(offset: Int, total: Int, rows: Int) -> JSONValue {
        json(#"{"generatedAt": "2026-01-02T10:00:00Z", "total": \#(total), "offset": \#(offset), "limit": 2, "rows": [\#((0..<rows).map { _ in "{}" }.joined(separator: ","))], "extra": {"ignored": true}}"#)
    }

    @Test func loadsEveryPage() async throws {
        let result = try await PagedReport.loadAll(rowsKey: "rows", pageSize: 2, fetch: { offset, _ in
            self.page(offset: offset, total: 3, rows: offset == 0 ? 2 : 1)
        })
        #expect(result.rows.count == 3)
    }

    @Test func rejectsAReportThatChangesBetweenPages() async {
        await #expect(throws: SubReportError.changed) {
            _ = try await PagedReport.loadAll(rowsKey: "rows", pageSize: 2, fetch: { offset, _ in
                self.page(offset: offset, total: offset == 0 ? 3 : 4, rows: offset == 0 ? 2 : 1)
            })
        }
    }

    @Test func missingServerReportIsNotAvailable() async {
        await #expect(throws: SubReportError.notAvailable) {
            _ = try await PagedReport.loadAll(rowsKey: "rows", pageSize: 2, fetch: { _, _ in .null })
        }
    }

    @Test func rejectsTooManyRows() async {
        await #expect(throws: SubReportError.tooLarge(99)) {
            _ = try await PagedReport.loadAll(rowsKey: "rows", pageSize: 2, maxRows: 10, fetch: { offset, _ in self.page(offset: offset, total: 99, rows: 2) })
        }
    }
}

@Suite struct SystemSubReportTests {
    @Test func servicesDecodeAndExport() throws {
        let catalog = try #require(ServiceCatalog(json: json(#"{"services": [{"name": "spooler", "displayName": "Print Spooler", "devices": 4, "startups": ["automatic"]}], "applications": [{"name": "Example App", "devices": 2, "versions": ["1.0"]}], \#(scope)}"#)))
        #expect(catalog.services.first?.displayName == "Print Spooler")
        #expect(catalog.options["rooms"] == ["A101"])
        #expect(ServiceCatalog(json: json(#"{"items": []}"#)) == nil)

        let envelope = json(#"{"generatedAt": "2026-01-02T12:00:00Z", "queryRequired": false, "total": 1, "offset": 0, "limit": 500, "summary": {"running": 1}, \#(scope), "devices": []}"#)
        let row = json(#"{\#(device), "hostname": "test-mac", "services": [{"name": "spooler", "displayName": null, "status": "Running", "startType": "Auto", "path": null, "newField": 1}], "applications": [], "state": "running", "reportedState": "running", "freshness": "fresh", "applicationsFreshness": "unknown"}"#)
        let report = ServicesReportData(envelope: envelope, rows: [row, json("{}")])
        #expect(report.summary["running"] == 1)
        let d = report.devices[0]
        #expect(d.checkinAgeHours == 2)
        #expect(ServicesReportSpec.checkinState(d.checkinAgeHours, maximumHours: 1) == "stale")
        // A row with nothing collected reads as unknown, never as running or absent.
        #expect(report.devices[1].state == "unknown")
        #expect(report.devices[1].checkinAgeHours == nil)
        #expect(ServicesReportSpec.stateLabel("missing") == "Not found")

        let csv = ServicesReportSpec.csvRows(report.devices, generatedAt: report.generatedAt, reportURL: "https://reportmate.example/system?tab=services", maximumCheckinHours: 168)
        #expect(csv[0].count == ServicesReportSpec.csvHeaders.count)
        #expect(csv[0][15] == "spooler")
        #expect(csv[0][18] == "spooler: Not reported")
    }

    @Test func servicesNeedAChosenService() {
        #expect(ServicesReportSpec.apiQuery(ReportParams(), platform: .all) == nil)
        let q = ServicesReportSpec.apiQuery(ReportParams(["serviceNames": #"["spooler"]"#, "search": "lab", "sort": "state"]), platform: .macOS)
        #expect(q == ["serviceNames": #"["spooler"]"#, "platform": "macos"])
    }

    @Test func updatesDecodeNullsAsNotReported() {
        let r = UpdatesReportData(envelope: json(#"{"generatedAt": "2026-01-02T12:00:00Z", "total": 2, "summary": {"none": 1, "pending": 1}, "rows": []}"#), rows: [
            json(#"{\#(device), "collectionValid": true, "pendingCount": 0, "updateKey": null, "cves": [], "isSecurity": null, "reportedState": "none", "state": "none"}"#),
            json(#"{\#(device), "collectionValid": false, "updateKey": "macos:26.1", "title": "macOS 26.1", "cves": ["CVE-2026-0001"], "isSecurity": true, "rebootRequired": true, "ageDays": 12, "ageSource": "offered", "reportedState": "pending", "state": "unknown"}"#),
        ])
        #expect(r.rows[0].flags.isEmpty)
        let title = UpdatesReportSpec.columns.first { $0.key == "title" }!
        #expect(title.text(r.rows[0]) == "Empty pending list reported")
        let state = UpdatesReportSpec.columns.first { $0.key == "state" }!
        #expect(state.detail?(r.rows[1]) == "No valid update collection")
        #expect(r.rows[1].flags == ["Security", "Restart required"])
        let csv = UpdatesReportSpec.csvRows(r.rows, generatedAt: r.generatedAt, reportURL: "")
        #expect(csv[0].count == UpdatesReportSpec.csvHeaders.count)
        #expect(csv[0][22] == nil) // Security flag is blank when no update is named
        #expect(csv[1][22] == "Yes")
        #expect(UpdatesReportSpec.stateChoices(ReportParams()) == ["pending", "none", "unknown"])
        #expect(UpdatesReportSpec.stateChoices(ReportParams(["updates": #"["macos:26.1"]"#])) == ["pending", "installed", "not_reported", "unknown"])
    }

    @Test func itemReportsMarkNotApplicableColumns() throws {
        let spec = ItemReportSpec.background
        let catalog = try #require(ItemCatalog(json: json(#"{"items": [{"kind": "task", "key": "\\Example\\Task", "label": null, "devices": 3}], \#(scope)}"#)))
        #expect(catalog.items.first?.value == "task:\\Example\\Task")
        let rows = ItemReportData(envelope: json(#"{"generatedAt": "2026-01-02T12:00:00Z", "queryRequired": false, "total": 2, "summary": {"lastRun:failed": 1}, "rows": []}"#), rows: [
            json(#"{\#(device), "kind": "task", "path": "\\Example\\Task", "lastRun": "failed", "lastRunTime": "1999-11-30T00:00:00", "enabledState": "enabled", "freshness": "fresh"}"#),
            json(#"{\#(device), "kind": "launchd", "name": "com.example.agent", "runAtLoad": true, "freshness": "stale"}"#),
        ]).rows
        let col: (String) -> ReportColumn<ItemRow> = { k in spec.columns.first { $0.key == k }! }
        #expect(col("lastRun").text(rows[0]) == "Failed")
        #expect(col("lastRunTime").text(rows[0]) == "Never")
        #expect(col("lastRun").text(rows[1]) == "Not applicable")
        #expect(col("runAtLoad").text(rows[1]) == "Yes")
        #expect(col("keepAlive").text(rows[1]) == "Not reported")
        #expect(col("freshness").text(rows[1]) == "Older than maximum age")
        #expect(spec.csvRows(rows, generatedAt: "", reportURL: "")[0].count == spec.csvHeaders.count)
        #expect(spec.apiQuery(ReportParams(), platform: .all) == nil)
        #expect(spec.apiQuery(ReportParams(["lastRuns": "failed"]), platform: .all)?["lastRuns"] == "failed")
        #expect(ItemReportSpec.extensions.apiQuery(ReportParams(["teamIds": "EXAMPLE123"]), platform: .windows) == nil)
    }
}

@Suite struct ManagementSubReportTests {
    @Test func profilesDecodeAndLabelUnknownHonestly() throws {
        let catalog = try #require(ProfileCatalog(json: json(#"{"profiles": [{"identifier": "com.example.wifi", "name": "Wi-Fi", "devices": 5, "platforms": ["macOS"]}], "preferences": [{"identifier": "com.example.app", "name": "com.example.app", "devices": 2, "platforms": ["macOS"], "keys": ["Enabled"]}], \#(scope)}"#)))
        #expect(catalog.options(for: .profile, platform: .windows).isEmpty)
        #expect(catalog.options(for: .preference, platform: .macOS).first?.keys == ["Enabled"])
        let data = ProfilesReportData(envelope: json(#"{"generatedAt": "2026-01-02T12:00:00Z", "kind": "preference", "queryRequired": false, "total": 2, "summary": {"installed": 1, "unknown": 1}, "devices": []}"#), rows: [
            json(#"{\#(device), "freshness": "fresh", "inventoryCount": 4, "state": "installed", "identifier": "com.example.app", "name": "com.example.app", "scope": "system", "settingCount": 3, "values": [{"scope": "system", "value": true}]}"#),
            json(#"{\#(device), "freshness": "unknown", "inventoryCount": 0, "state": "unknown", "identifier": "com.example.app", "name": "com.example.app", "scope": null}"#),
        ])
        #expect(data.kind == .preference)
        let cols = ProfilesReportSpec.columns(kind: .preference)
        let state = cols.first { $0.key == "state" }!
        #expect(state.detail?(data.rows[1]) == "No management inventory reported")
        #expect(cols.first { $0.key == "scope" }!.text(data.rows[1]) == "Not applicable")
        #expect(data.rows[0].values?.first?.value == "Yes")
        let csv = ProfilesReportSpec.csvRows(data.rows, generatedAt: "", reportURL: "")
        #expect(csv[0].count == ProfilesReportSpec.csvHeaders(kind: .preference).count)
        #expect(csv[0][27] == "system: Yes")
        #expect(ProfilesReportSpec.apiQuery(ReportParams(["preferenceKey": "Enabled"]), kind: .profile, platform: .all) == nil)
        #expect(ProfilesReportSpec.apiQuery(ReportParams(["identifiers": #"["com.example.wifi"]"#, "preferenceKey": "Enabled"]), kind: .profile, platform: .all)?["preferenceKey"] == nil)
    }

    @Test func enrollmentHealthTreatsMissingAsUnknown() {
        let now = FlexibleDate.parse("2026-01-31T00:00:00Z")!
        let windows = EnrollmentHealth(json: json(#"{"platform": "Windows", "complianceState": "non_compliant", "complianceSource": "policies", "lastMdmSync": "2026-01-01T00:00:00Z", "mdmCertificateExpires": "2026-02-10T00:00:00Z"}"#))
        let mac = EnrollmentHealth(json: json(#"{"platform": "macOS", "complianceState": null, "userApprovedMdm": true, "installedFromDep": true, "depCapable": null}"#))
        #expect(windows.complianceLabel == "Not compliant")
        #expect(windows.syncText(now: now) == "30 days ago")
        #expect(windows.certificateText(now: now) == "Expires in 10 days")
        #expect(windows.appleFlag(true) == "Not applicable")
        #expect(mac.complianceLabel == "Unknown")
        #expect(mac.appleFlag(mac.depCapable) == "Unknown")
        #expect(mac.csvValues[2] == "Unknown")
        let f = EnrollmentHealthFilters(query: ["compliance": "non_compliant", "syncOlderThan": "7", "certExpiring": "30"])
        #expect(f.count == 3)
        #expect(f.matches(windows, now: now))
        // A device that did not report a value never matches a problem filter.
        #expect(!EnrollmentHealthFilters(syncOlderThanDays: 1).matches(mac, now: now))
        #expect(EnrollmentHealthFilters(query: ["syncOlderThan": "-3"]).syncOlderThanDays == nil)
        #expect(EnrollmentHealthFilters(query: f.query) == f)
    }
}

@Suite struct SecurityIdentitySubReportTests {
    @Test func vulnerabilitySummaryAndDevices() throws {
        let summary = try #require(VulnerabilitySummaryData(json: json(#"{"generatedAt": "2026-01-02T12:00:00Z", "view": "summary", "coverage": {"devices": 10, "reporting": 8, "notReporting": 2, "unknown": 0, "listMayBeIncomplete": 1}, "cves": [{"identifier": "CVE-2026-0001", "cve": "CVE-2026-0001", "kbArticle": null, "devices": 3, "unpatchedDevices": 3, "patchedDevices": 0, "activelyExploited": null, "severities": [], "fixedIn": ["26.2"], "products": ["macOS"], "platforms": ["macOS"], "sources": ["SOFA"]}]}"#)))
        #expect(summary.coverage.vulnerabilityText.contains("2 do not (coverage unknown, not counted as clean)"))
        #expect(summary.cves[0].link?.absoluteString == "https://nvd.nist.gov/vuln/detail/CVE-2026-0001")
        let exploited = VulnerabilitiesReportSpec.summaryColumns.first { $0.key == "exploited" }!
        #expect(exploited.text(summary.cves[0]) == "Not reported")
        #expect(VulnerabilitiesReportSpec.summaryCSVRows(summary.cves, generatedAt: "", reportURL: "")[0][5] == "Not reported")
        #expect(VulnerabilitiesReportSpec.filterSummary(summary.cves, query: "26.2").count == 1)

        let devices = VulnerabilityDevicesData(envelope: json(#"{"generatedAt": "2026-01-02T12:00:00Z", "coverage": {}, "total": 1, "rows": []}"#), rows: [
            json(#"{\#(device), "identifier": "KB0000001", "cve": null, "kbArticle": "KB0000001", "source": "MSRC", "status": "unpatched", "severity": null, "activelyExploited": false, "url": "javascript:alert(1)", "freshness": "fresh", "listMayBeIncomplete": true}"#),
        ])
        #expect(devices.rows[0].link == nil)
        let row = VulnerabilitiesReportSpec.deviceCSVRows(devices.rows, generatedAt: "", reportURL: "")[0]
        #expect(row.count == VulnerabilitiesReportSpec.deviceCSVHeaders.count)
        #expect(row[5] == "Not reported")
        #expect(row[11] == nil)
        #expect(VulnerabilitiesReportSpec.apiQuery(ReportParams(), platform: .windows) == ["platform": "windows", "view": "summary"])
    }

    @Test func detectionsDefaultToThirtyDays() {
        #expect(DetectionsReportSpec.days(ReportParams()) == 30)
        #expect(DetectionsReportSpec.days(ReportParams(["days": "0"])) == 0)
        #expect(DetectionsReportSpec.days(ReportParams(["days": "x"])) == 30)
        let data = DetectionsData(envelope: json(#"{"generatedAt": "2026-01-02T12:00:00Z", "days": 30, "coverage": {"devices": 4, "reporting": 2, "notReporting": 2, "devicesWithDetections": 1}, \#(scope), "total": 1, "rows": []}"#), rows: [
            json(#"{\#(device), "threatName": "Test.Threat", "severity": "Severe", "count": null, "detectedAt": "2026-01-01T00:00:00Z"}"#),
        ])
        #expect(data.coverage.detectionText.hasSuffix("1 devices have matching detections."))
        #expect(DetectionsReportSpec.columns.first { $0.key == "count" }!.text(data.rows[0]) == "Not reported (1 event)")
        #expect(DetectionsReportSpec.csvRows(data.rows, generatedAt: "", reportURL: "")[0].count == DetectionsReportSpec.csvHeaders.count)
    }

    @Test func postureReadsPlatformColumnsAndUnknowns() {
        let data = PostureReportData(envelope: json(#"{"generatedAt": "2026-01-02T12:00:00Z", "maxAgeHours": 168, "total": 2, "summary": {"noRecoveryKey": 1}, "unknown": {"noLaps": 1}, "devices": []}"#), rows: [
            json(#"{\#(device), "identityFreshness": "fresh", "securityFreshness": "stale", "reported": {"pssoState": "expired", "pssoUsers": [{"username": "user1", "token": "expired"}], "activationLock": "likely", "recoveryKey": "present", "personalRecoveryKey": true, "institutionalRecoveryKey": false, "secureTokenGranted": 2, "secureTokenMissing": 0}, "checks": {"noLaps": null, "expiredPssoToken": true, "noRecoveryKey": false}}"#),
            json(#"{"serialNumber": "TESTSERIAL02", "platform": "Windows", "reported": null, "checks": {}}"#),
        ])
        let mac = data.devices[0], win = data.devices[1]
        #expect(PostureReportSpec.text(mac, "psso") == "Token expired")
        #expect(PostureReportSpec.text(mac, "activationLock") == "Likely on (inferred from Find My)")
        #expect(PostureReportSpec.text(mac, "recoveryKey") == "Personal")
        #expect(PostureReportSpec.text(mac, "laps") == nil)
        #expect(PostureReportSpec.text(win, "laps") == "Unknown")
        #expect(PostureReportSpec.text(win, "passwordPolicy") == "Min length Unknown · Lockout after Unknown for Unknown")
        #expect(PostureReportSpec.availableColumns(.windows).contains("psso") == false)
        let csv = PostureReportSpec.csvRows(data.devices, generatedAt: "", reportURL: "")
        #expect(csv[0].count == PostureReportSpec.csvHeaders.count)
        let quickStart = 13 + PostureReportSpec.csvPostureKeys.count + 1
        #expect(Array(csv[0][quickStart..<(quickStart + 5)]) == ["Not applicable", "Not applicable", "Yes", "Unknown", "No"])
        #expect(Array(csv[1][quickStart..<(quickStart + 2)]) == ["Unknown", "Unknown"])
    }
}

@Suite struct SubReportLinkTests {
    @Test func tabLinksKeepEveryFilter() throws {
        let link = try #require(DeepLink(url: URL(string: "https://reportmate.example/system?tab=services&serviceNames=%5B%22spooler%22%5D&platform=mac")!))
        #expect(link.target == .report("system"))
        #expect(link.query["tab"] == "services")
        let p = ReportParams(link.query)
        #expect(p.jsonList("serviceNames") == ["spooler"])
        #expect(p["platform"] == nil)
        #expect(DeepLink(url: link.url) == link)
    }
}
