import SwiftUI
import ReportMateKit

// Cards 5–12 of the shared dashboard widget spec. Every figure, bar, legend row
// and chip opens the report that owns it with the matching filter on.

// MARK: - 5 Install Health

struct InstallHealthWidget: View {
    let stats: InstallStats?
    let platform: PlatformFilter
    let staleAgents: [StaleAgent]?
    let records: [InstallRecord]?
    let recordsLoading: Bool
    let recordsFailed: Bool
    let loading: Bool
    let error: String?

    var body: some View {
        let top = records.map { DashboardInsights.topFailingItems($0) } ?? []
        let max = top.first?.count ?? 1
        InsightCard(title: "Install Health", subtitle: "Munki and Cimian across the fleet", systemImage: "arrow.down.circle", tone: .green, link: DashboardLinks.installs(), loading: loading, error: error, empty: stats == nil && staleAgents == nil) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    InsightFigure(value: stats.flatMap { $0.devicesWithErrors(for: platform) }, label: "devices with errors", tone: .red, link: DashboardLinks.installs(filter: "errors"))
                    InsightFigure(value: stats.flatMap { $0.devicesWithWarnings(for: platform) }, label: "devices with warnings", tone: .yellow, link: DashboardLinks.installs(filter: "warnings"))
                    InsightFigure(value: staleAgents.map(DashboardInsights.staleAgentCount), label: "agents silent over 7 days", tone: .orange, link: DashboardLinks.installsStale)
                }
                VStack(alignment: .leading, spacing: 2) {
                    InsightHeading("Top failing items")
                    if !top.isEmpty {
                        ForEach(top) { item in
                            InsightBarRow(label: item.name, count: item.count, max: max, tone: .red, link: DashboardLinks.installs(item: item.name, filter: "errors"))
                        }
                    } else if recordsLoading {
                        HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Loading install records…").appFont(.caption).foregroundStyle(.secondary) }.padding(4)
                    } else if recordsFailed {
                        Text("Install records unavailable; showing counts only.").appFont(.caption).foregroundStyle(.secondary).padding(4)
                    } else {
                        Text("No failing items").appFont(.caption).foregroundStyle(.secondary).padding(4)
                    }
                }
            }
        }
    }
}

// MARK: - 6 Check-in Gaps

struct CheckInGapsWidget: View {
    let page: IngestFailuresPage?
    let devices: [DeviceSummary]
    /// The platform toggle is on: the check-in figures cannot follow it, so they say so.
    var platformFiltered = false
    let loading: Bool
    let error: String?

    var body: some View {
        let gaps = DashboardInsights.checkInGaps(devices)
        let reasons = page?.summary.sorted { $0.count > $1.count } ?? []
        let max = reasons.first?.count ?? 1
        InsightCard(title: "Check-in Gaps", subtitle: platformFiltered ? "Check-ins: all platforms · silent devices: filtered" : "Rejected check-ins and silent devices", systemImage: "antenna.radiowaves.left.and.right.slash", tone: .red, link: DashboardLinks.failures(), loading: loading, error: error, empty: page == nil && devices.isEmpty) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    InsightFigure(value: page?.rejected, label: "rejected in 24h", tone: .red, link: outcome("rejected"))
                    InsightFigure(value: page?.retried, label: "retried", tone: .yellow, link: outcome("retried"))
                    InsightFigure(value: page?.accepted, label: "accepted after repair", tone: .green, link: outcome("accepted"))
                }
                if !reasons.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        InsightHeading("Reasons")
                        ForEach(reasons.prefix(5)) { r in
                            InsightBarRow(label: r.reason, count: r.count, max: max, tone: .red, link: DashboardLinks.failures(hours: 24, reason: r.reason))
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    InsightHeading("Silent devices")
                    InsightBarRow(label: "1–7 days", count: gaps.stale, max: Swift.max(gaps.stale, gaps.missing, 1), tone: .yellow, link: DashboardLinks.devices(status: .stale))
                    InsightBarRow(label: "Over 7 days", count: gaps.missing, max: Swift.max(gaps.stale, gaps.missing, 1), tone: .red, link: DashboardLinks.devices(status: .missing))
                }
            }
        }
    }

    private func outcome(_ o: String) -> DeepLink {
        var link = DashboardLinks.failures()
        link.query["outcome"] = o
        return link
    }
}

// MARK: - 7 OS Currency

struct OSCurrencyWidget: View {
    let rows: [ReportRow]
    /// Every `/system` row, before the platform toggle: the latest patch is the fleet's.
    let allRows: [ReportRow]
    let loading: Bool
    let error: String?

    var body: some View {
        let currency = OSCurrency(rows: allRows.map { SystemReportRow(json: $0.json) })
        let s = DashboardInsights.osCurrency(rows.map { SystemReportRow(json: $0.json) }, currency: currency)
        let max = s.lagging.first?.count ?? 1
        InsightCard(title: "OS Currency", subtitle: "Patch level against the newest in the fleet", systemImage: "arrow.triangle.2.circlepath", tone: .blue, link: DashboardLinks.system(), loading: loading, error: error, empty: rows.isEmpty) {
            VStack(alignment: .leading, spacing: 12) {
                if s.macTotal > 0 {
                    InsightDonut(data: [
                        InsightSlice(label: "On latest patch", count: s.onLatest, color: .green),
                        InsightSlice(label: "Behind", count: s.behind, color: .orange, link: DashboardLinks.system(["patch": "behind"])),
                    ], center: "\(s.onLatestPercent)%")
                }
                InsightChips {
                    StatChip(value: s.unsupported, label: "unsupported macOS", tone: .red, link: DashboardLinks.system(["os": "unsupported"]))
                    StatChip(value: s.windows10, label: "on Windows 10", tone: .orange, link: DashboardLinks.system(["os": "windows10"]))
                }
                if !s.lagging.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        InsightHeading("Most common lagging versions")
                        ForEach(s.lagging) { v in
                            InsightBarRow(label: "macOS \(v.name)", count: v.count, max: max, tone: .orange, link: DashboardLinks.system(osVersion: v.name))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 8 Software Risk

struct SoftwareRiskWidget: View {
    let security: [ReportRow]
    let records: [InstallRecord]?
    let recordsLoading: Bool
    let recordsFailed: Bool
    let loading: Bool
    let error: String?

    var body: some View {
        let s = security.map { SecurityReportRow(json: $0.json, platform: $0.platform) }
        let behind = records.map { DashboardInsights.topBehindItems($0) } ?? []
        let max = behind.first?.count ?? 1
        InsightCard(title: "Software Risk", subtitle: "Vulnerabilities and out-of-date items", systemImage: "exclamationmark.shield", tone: .red, link: DashboardLinks.report("security"), loading: loading, error: error, empty: security.isEmpty && records == nil) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    InsightFigure(value: s.filter { $0.criticalCveCount > 0 }.count, label: "devices with critical CVEs", tone: .red, link: DashboardLinks.report("security", ["cve": "critical"]))
                    InsightFigure(value: s.filter { $0.activelyExploitedCveCount > 0 }.count, label: "with actively exploited CVEs", tone: .red, link: DashboardLinks.report("security", ["cve": "exploited"]))
                }
                VStack(alignment: .leading, spacing: 2) {
                    InsightHeading("Most devices behind")
                    if !behind.isEmpty {
                        ForEach(behind) { item in
                            InsightBarRow(label: item.name, count: item.count, max: max, tone: .orange, link: DashboardLinks.report("installs", ["item": item.name]))
                        }
                    } else if recordsLoading {
                        HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Loading install records…").appFont(.caption).foregroundStyle(.secondary) }.padding(4)
                    } else if recordsFailed {
                        Text("Install records unavailable.").appFont(.caption).foregroundStyle(.secondary).padding(4)
                    } else {
                        Text("Every managed item is current").appFont(.caption).foregroundStyle(.secondary).padding(4)
                    }
                }
            }
        }
    }
}

// MARK: - 9 Certificates

struct CertificatesWidget: View {
    let expiring: [JSONValue]?
    let security: [ReportRow]
    let loading: Bool
    let error: String?

    var body: some View {
        let s = DashboardInsights.certificates(expiring: expiring ?? [], security: security.map { SecurityReportRow(json: $0.json, platform: $0.platform) })
        InsightCard(title: "Certificates", subtitle: "Expiring within 30 days and expired", systemImage: "checkmark.seal", tone: .yellow, link: DashboardLinks.report("security"), loading: loading, error: error, empty: expiring == nil && security.isEmpty) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    InsightFigure(value: expiring == nil ? nil : s.expiringCertificates, label: "certificates expiring", tone: .orange, link: DashboardLinks.report("security", ["certs": "expiring"]))
                    InsightFigure(value: s.expiringDevices, label: "devices with expiring", tone: .orange, link: DashboardLinks.report("security", ["certs": "expiring"]))
                    InsightFigure(value: s.expiredDevices, label: "devices with expired user certs", tone: .red, link: DashboardLinks.report("security", ["certs": "expired"]))
                }
                if !s.soonest.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        InsightHeading("Expiring soonest")
                        ForEach(s.soonest) { c in
                            InsightLink(link: DashboardLinks.report("security", ["certSearch": c.name, "certStatus": "expiring"])) {
                                HStack {
                                    Text(c.name).appFont(.callout).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(c.count == 0 ? "today" : "\(c.count) day\(c.count == 1 ? "" : "s")").appFont(.callout, weight: .medium).foregroundStyle(c.count <= 7 ? Tone.red.color : .secondary).monospacedDigit()
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 10 Identity

struct IdentityInsightWidget: View {
    let rows: [ReportRow]
    let loading: Bool
    let error: String?

    var body: some View {
        let s = DashboardInsights.identity(rows.map { IdentityReportRow(json: $0.json) })
        let colors: [IdentityJoin: Color] = [.entra: .blue, .hybrid: .teal, .domain: .orange, .workgroup: Color.secondary.opacity(0.4)]
        let slices = IdentityJoin.allCases.compactMap { j -> InsightSlice? in
            let n = s.joins[j] ?? 0
            return n == 0 ? nil : InsightSlice(label: j.label, count: n, color: colors[j] ?? .gray, link: DashboardLinks.report("identity", ["join": j.rawValue]))
        }
        InsightCard(title: "Identity", subtitle: "Directory join, admins and usage", systemImage: "person.badge.key", tone: .indigo, link: DashboardLinks.report("identity"), loading: loading, error: error, empty: rows.isEmpty) {
            VStack(alignment: .leading, spacing: 12) {
                InsightDonut(data: slices, center: "\(s.total)")
                InsightChips {
                    StatChip(value: s.extraAdmins, label: "with extra local admins", tone: .red, link: DashboardLinks.report("identity", ["admins": "extra"]))
                    StatChip(value: s.shared, label: "shared", tone: .blue, link: DashboardLinks.report("identity", ["usage": "shared"]))
                    StatChip(value: s.assigned, label: "assigned", tone: .indigo, link: DashboardLinks.report("identity", ["usage": "assigned"]))
                }
            }
        }
    }
}

// MARK: - 11 App Usage

struct AppUsageWidget: View {
    let usage: UtilizationData?
    var platformFiltered = false
    let loading: Bool
    let error: String?

    var body: some View {
        let r = DashboardInsights.appUsage(usage?.applications ?? [])
        let maxHours = r.top.first?.totalHours ?? 1
        InsightCard(title: "App Usage", subtitle: platformFiltered ? "Last 30 days · All platforms" : "Last 30 days", systemImage: "chart.bar.xaxis", tone: .blue, link: DashboardLinks.report("applications", ["type": "usage", "period": "30"]), loading: loading, error: error, empty: (usage?.applications ?? []).isEmpty) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    InsightHeading("Most used")
                    ForEach(r.top) { app in
                        InsightBarRow(label: app.name, count: Int(app.totalHours.rounded()), max: Int(maxHours.rounded()), tone: .blue, link: DashboardLinks.applicationUsage(app.name), valueText: "\(Int(app.totalHours.rounded())) h")
                    }
                }
                if !r.least.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        InsightHeading("Least used (on 10+ devices)")
                        ForEach(r.least) { app in
                            let installed = app.installedDeviceCount ?? 0
                            let active = app.activeDeviceCount ?? app.deviceCount
                            InsightBarRow(label: app.name, count: active, max: installed, tone: .gray, link: DashboardLinks.applicationUsage(app.name), valueText: "\(active) of \(installed)")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 12 Network & Peripherals

struct NetworkPeripheralsWidget: View {
    let network: [ReportRow]
    let peripherals: [ReportRow]
    let loading: Bool
    let error: String?

    var body: some View {
        let s = DashboardInsights.networkPeripherals(network: network.map { NetworkReportRow(json: $0.json) },
                                                     peripherals: peripherals.map { (PeripheralsReportRow(json: $0.json), $0.inventory.location) })
        let max = s.printerRooms.first?.count ?? 1
        InsightCard(title: "Network & Peripherals", subtitle: "Connections, signal, printers and displays", systemImage: "wifi", tone: .teal, link: DashboardLinks.report("network"), loading: loading, error: error, empty: network.isEmpty && peripherals.isEmpty) {
            VStack(alignment: .leading, spacing: 12) {
                InsightDonut(data: [
                    InsightSlice(label: "Wired", count: s.wired, color: .teal, link: DashboardLinks.report("network", ["connection": "wired"])),
                    InsightSlice(label: "Wi-Fi", count: s.wifi, color: .blue, link: DashboardLinks.report("network", ["connection": "wifi"])),
                ])
                InsightChips {
                    StatChip(value: s.weakSignal, label: "weak Wi-Fi signal", tone: .red, link: DashboardLinks.report("network", ["signal": "weak"]))
                    StatChip(value: s.printers, label: "printers on \(s.printerDevices) devices", tone: .purple, link: DashboardLinks.report("peripherals", ["kind": "printers"]))
                    StatChip(value: s.displays, label: "displays on \(s.displayDevices) devices", tone: .cyan, link: DashboardLinks.report("peripherals", ["kind": "displays"]))
                }
                if !s.printerRooms.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        InsightHeading("Rooms with the most printers")
                        ForEach(s.printerRooms) { room in
                            InsightBarRow(label: room.name, count: room.count, max: max, tone: .purple, link: DashboardLinks.report("peripherals", ["kind": "printers", "room": room.name]))
                        }
                    }
                }
            }
        }
    }
}
