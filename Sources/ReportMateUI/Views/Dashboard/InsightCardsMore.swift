import SwiftUI
import ReportMateKit

// The twelve insight cards (revision 2 of the shared widget spec): each answers
// one question about the fleet. Every figure, bar, legend row and chip opens the
// link the API attached to it: the report with that filter on.

private extension InsightCardData {
    func count(_ key: String) -> Int? { item(key)?.count }
}

private extension InsightItem {
    /// The server's link, or `fallback` when it gave a bare report path.
    func link(or fallback: DeepLink) -> DeepLink {
        guard let l = link, !l.query.isEmpty else { return fallback }
        return l
    }
}

/// The card for `number` in the spec's order.
struct InsightCardView: View {
    let number: Int
    let platform: PlatformFilter

    var body: some View {
        switch number {
        case 1: RebootDebtCard()
        case 2: ProtectionGapsCard()
        case 3: UnmanagedDevicesCard()
        case 4: HardwareAtRiskCard()
        case 5: InstallHealthCard()
        case 6: CheckInGapsCard(platform: platform)
        case 7: OSCurrencyCard()
        case 8: SoftwareRiskCard()
        case 9: ExpiringCertificatesCard()
        case 10: LocalAdminExposureCard()
        case 11: UnusedSoftwareCard()
        default: ConnectivityProblemsCard()
        }
    }
}

// MARK: - 1 Reboot & Update Debt

struct RebootDebtCard: View {
    var body: some View {
        InsightCard(key: "rebootDebt", title: "Reboot & Update Debt", subtitle: "Long uptimes and updates waiting", systemImage: "arrow.clockwise.circle", tone: .orange, link: DashboardLinks.system()) { c in
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    InsightFigure(value: c.count("uptime30dPlus"), label: "up 30+ days", tone: .red, link: c.item("uptime30dPlus")?.link)
                    InsightFigure(value: c.count("uptime2to4w"), label: "up 2–4 weeks", tone: .orange, link: c.item("uptime2to4w")?.link)
                }
                let buckets = c.items("uptimeBuckets")
                if !buckets.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        InsightHeading("Uptime")
                        let max = buckets.map(\.count).max() ?? 1
                        ForEach(buckets) { b in
                            InsightBarRow(label: b.label ?? b.key ?? "", count: b.count, max: max, tone: .orange, link: b.link)
                        }
                    }
                }
                InsightChips {
                    StatChip(value: c.count("pendingUpdates") ?? 0, label: "with pending updates", tone: .yellow, link: c.item("pendingUpdates")?.link)
                    StatChip(value: c.count("deferredUpdates") ?? 0, label: "with deferred updates", tone: .orange, link: c.item("deferredUpdates")?.link)
                }
            }
        }
    }
}

// MARK: - 2 Protection Gaps

struct ProtectionGapsCard: View {
    var body: some View {
        InsightCard(key: "protectionGaps", title: "Protection Gaps", subtitle: "Devices missing a protection, worst first", systemImage: "lock.trianglebadge.exclamationmark", tone: .red, link: DashboardLinks.report("security")) { c in
            VStack(alignment: .leading, spacing: 12) {
                let gaps = c.items("gaps")
                if gaps.isEmpty {
                    Text("No protection data reported").appFont(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(gaps) { g in
                            let total = g.int("total") ?? 0
                            InsightBarRow(label: g.label ?? g.key ?? "", count: g.count, max: Swift.max(total, 1), tone: g.count == 0 ? .green : .red, link: g.link, valueText: "\(g.count) of \(total)")
                        }
                    }
                }
                InsightChips {
                    StatChip(value: c.count("withThreats") ?? 0, label: "with active threats", tone: .red, link: c.item("withThreats")?.link)
                    StatChip(value: c.count("criticalCves") ?? 0, label: "with critical CVEs", tone: .orange, link: c.item("criticalCves")?.link)
                }
            }
        }
    }
}

// MARK: - 3 Unmanaged Devices

struct UnmanagedDevicesCard: View {
    var body: some View {
        InsightCard(key: "unmanagedDevices", title: "Unmanaged Devices", subtitle: "Not enrolled in MDM", systemImage: "checkmark.shield", tone: .purple, link: DashboardLinks.report("management")) { c in
            VStack(alignment: .leading, spacing: 12) {
                let unmanaged = c.item("unmanaged")
                MaybeInsightLink(link: unmanaged?.link) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(unmanaged?.count ?? 0)").appFont(.title, weight: .bold).foregroundStyle((unmanaged?.count ?? 0) == 0 ? Color.secondary : Tone.purple.color).monospacedDigit()
                        Text("unmanaged · \(unmanaged?.int("pct") ?? 0)% of \(c.int("devices") ?? 0)").appFont(.callout).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
                if let enrolled = c.int("enrolledPct") {
                    Text("\(enrolled)% of the fleet is enrolled").appFont(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                }
                let byPlatform = c.items("byPlatform")
                if !byPlatform.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        InsightHeading("By platform")
                        ForEach(byPlatform) { p in
                            InsightBarRow(label: p.name ?? "Unknown", count: p.count, max: Swift.max(p.int("devices") ?? 1, 1), tone: .purple, link: p.link, valueText: "\(p.count) of \(p.int("devices") ?? 0)")
                        }
                    }
                }
                let lastSeen = c.items("lastSeen")
                if !lastSeen.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        InsightHeading("Last seen")
                        let max = lastSeen.map(\.count).max() ?? 1
                        ForEach(lastSeen) { s in InsightBarRow(label: s.label ?? s.key ?? "", count: s.count, max: max, tone: .gray, link: s.link) }
                    }
                }
                let recent = c.items("recent")
                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        InsightHeading("Most recently seen")
                        ForEach(recent) { d in
                            MaybeInsightLink(link: d.link) {
                                HStack {
                                    Text(d.name ?? d.string("serialNumber") ?? "").appFont(.callout).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(TimeFormatting.relative(FlexibleDate.parse(d.json["lastSeen"]))).appFont(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 4 Hardware at Risk

struct HardwareAtRiskCard: View {
    var body: some View {
        InsightCard(key: "hardwareAtRisk", title: "Hardware at Risk", subtitle: "Low storage, low memory and Intel Macs", systemImage: "cpu", tone: .teal, link: DashboardLinks.report("hardware")) { c in
            HStack(alignment: .top, spacing: 8) {
                InsightFigure(value: c.count("lowStorage"), label: "under 10% storage free", tone: .red, link: c.item("lowStorage")?.link)
                InsightFigure(value: c.count("lowMemory"), label: "8 GB memory or less", tone: .orange, link: c.item("lowMemory")?.link)
                let intel = c.item("intelMacs")
                InsightFigure(value: intel?.count, label: "Intel Macs of \(intel?.int("macs") ?? 0), at risk at the next macOS", tone: .yellow, link: intel?.link)
            }
        }
    }
}

// MARK: - 5 Install Health

struct InstallHealthCard: View {
    var body: some View {
        InsightCard(key: "installHealth", title: "Install Health", subtitle: "Munki and Cimian across the fleet", systemImage: "arrow.down.circle", tone: .green, link: DashboardLinks.installs()) { c in
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    InsightFigure(value: c.count("withErrors"), label: "devices with errors", tone: .red, link: c.item("withErrors")?.link)
                    InsightFigure(value: c.count("withWarnings"), label: "devices with warnings", tone: .yellow, link: c.item("withWarnings")?.link)
                    let silent = c.item("silentAgents")
                    InsightFigure(value: silent?.count, label: "agents silent over \(silent?.int("thresholdDays") ?? 7) days", tone: .orange, link: silent?.link)
                }
                let top = c.items("topFailing")
                VStack(alignment: .leading, spacing: 2) {
                    InsightHeading("Top failing items")
                    if top.isEmpty {
                        Text("No failing items").appFont(.caption).foregroundStyle(.secondary).padding(4)
                    } else {
                        let max = top.map(\.count).max() ?? 1
                        ForEach(top) { item in InsightBarRow(label: item.name ?? "", count: item.count, max: max, tone: .red, link: item.link) }
                    }
                }
            }
        }
    }
}

// MARK: - 6 Check-in Gaps

struct CheckInGapsCard: View {
    let platform: PlatformFilter

    var body: some View {
        InsightCard(key: "checkinGaps", title: "Check-in Gaps", subtitle: "Rejected check-ins and silent devices", systemImage: "antenna.radiowaves.left.and.right.slash", tone: .red, link: DashboardLinks.failures()) { c in
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    let hours = c.int("hours") ?? 24
                    InsightFigure(value: c.count("rejected"), label: "rejected in \(hours)h", tone: .red, link: c.item("rejected")?.link)
                    InsightFigure(value: c.count("retried"), label: "retried", tone: .yellow, link: c.item("retried")?.link)
                    InsightFigure(value: c.count("accepted"), label: "accepted after repair", tone: .green, link: c.item("accepted")?.link)
                }
                // Check-ins are recorded before a device is known, so they cannot follow the toggle.
                if c.bool("checkinsAllPlatforms"), platform != .all {
                    Text("Check-ins and reasons cover all platforms.").appFont(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                }
                let reasons = c.items("reasons")
                if !reasons.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        InsightHeading("Reasons")
                        let max = reasons.map(\.count).max() ?? 1
                        ForEach(reasons) { r in InsightBarRow(label: r.name ?? "", count: r.count, max: max, tone: .red, link: r.link) }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    InsightHeading("Silent devices")
                    let stale = c.count("stale") ?? 0, missing = c.count("missing") ?? 0
                    InsightBarRow(label: "1–7 days", count: stale, max: Swift.max(stale, missing, 1), tone: .yellow, link: c.item("stale")?.link)
                    InsightBarRow(label: "Over 7 days", count: missing, max: Swift.max(stale, missing, 1), tone: .red, link: c.item("missing")?.link)
                }
            }
        }
    }
}

// MARK: - 7 OS Currency

struct OSCurrencyCard: View {
    var body: some View {
        InsightCard(key: "osCurrency", title: "OS Currency", subtitle: "Patch level against the fleet's latest", systemImage: "arrow.triangle.2.circlepath", tone: .blue, link: DashboardLinks.system()) { c in
            VStack(alignment: .leading, spacing: 12) {
                let behind = c.item("behind")
                if (c.int("rated") ?? 0) > 0 {
                    InsightDonut(data: [
                        InsightSlice(label: "On latest patch", count: c.int("onLatest") ?? 0, color: .green),
                        InsightSlice(label: "Behind", count: behind?.count ?? 0, color: .orange, link: behind?.link),
                    ], center: "\(c.int("pctOnLatest") ?? 0)%")
                }
                InsightChips {
                    StatChip(value: c.count("unsupportedMac") ?? 0, label: "unsupported macOS", tone: .red, link: c.item("unsupportedMac")?.link)
                    StatChip(value: c.count("windows10") ?? 0, label: "on Windows 10", tone: .orange, link: c.item("windows10")?.link)
                }
                let lagging = c.items("lagging")
                if !lagging.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        InsightHeading("Most common lagging versions")
                        let max = lagging.map(\.count).max() ?? 1
                        ForEach(lagging) { v in InsightBarRow(label: v.label ?? v.name ?? "", count: v.count, max: max, tone: .orange, link: v.link) }
                    }
                }
                if let min = c.int("minDevices") {
                    Text("Latest is the highest version at least \(min) devices run.").appFont(.caption2).foregroundStyle(.secondary).padding(.horizontal, 4)
                }
            }
        }
    }
}

// MARK: - 8 Software Risk

struct SoftwareRiskCard: View {
    var body: some View {
        InsightCard(key: "softwareRisk", title: "Software Risk", subtitle: "Vulnerabilities and out-of-date items", systemImage: "exclamationmark.shield", tone: .red, link: DashboardLinks.report("security")) { c in
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    InsightFigure(value: c.count("criticalCves"), label: "devices with critical CVEs", tone: .red, link: c.item("criticalCves")?.link)
                    InsightFigure(value: c.count("exploitedCves"), label: "with actively exploited CVEs", tone: .red, link: c.item("exploitedCves")?.link)
                }
                let behind = c.items("itemsBehind")
                VStack(alignment: .leading, spacing: 2) {
                    InsightHeading("Most devices behind")
                    if behind.isEmpty {
                        Text("Every managed item is current").appFont(.caption).foregroundStyle(.secondary).padding(4)
                    } else {
                        let max = behind.map(\.count).max() ?? 1
                        ForEach(behind) { item in InsightBarRow(label: item.name ?? "", count: item.count, max: max, tone: .orange, link: item.link) }
                    }
                }
            }
        }
    }
}

// MARK: - 9 Expiring Certificates

struct ExpiringCertificatesCard: View {
    var body: some View {
        InsightCard(key: "expiringCertificates", title: "Expiring Certificates", subtitle: "Expiring soon and expired user certificates", systemImage: "checkmark.seal", tone: .yellow, link: DashboardLinks.report("security")) { c in
            VStack(alignment: .leading, spacing: 12) {
                let expiring = c.item("expiring")
                let window = c.int("windowDays") ?? 30
                HStack(alignment: .top, spacing: 8) {
                    InsightFigure(value: expiring?.int("certificates"), label: "certificates expiring in \(window) days", tone: .orange, link: expiring?.link)
                    InsightFigure(value: expiring?.int("devices"), label: "devices with expiring", tone: .orange, link: expiring?.link)
                    let expired = c.item("expiredUser")
                    InsightFigure(value: expired?.int("devices"), label: "devices with expired user certs", tone: .red, link: expired?.link)
                }
                let soonest = c.items("soonest")
                if !soonest.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        InsightHeading("Expiring soonest")
                        ForEach(soonest) { cert in
                            let days = cert.int("daysUntilExpiry") ?? 0
                            MaybeInsightLink(link: cert.link) {
                                HStack {
                                    Text(cert.name ?? "").appFont(.callout).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text("\(cert.int("devices") ?? 0) devices").appFont(.caption).foregroundStyle(.secondary)
                                    Text(days <= 0 ? "today" : "\(days) day\(days == 1 ? "" : "s")").appFont(.callout, weight: .medium)
                                        .foregroundStyle(days <= 7 ? Tone.red.color : .secondary).monospacedDigit().frame(minWidth: 52, alignment: .trailing)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 10 Local Admin Exposure

struct LocalAdminExposureCard: View {
    var body: some View {
        InsightCard(key: "localAdminExposure", title: "Local Admin Exposure", subtitle: "Extra local admins and unjoined devices", systemImage: "person.badge.key", tone: .indigo, link: DashboardLinks.report("identity")) { c in
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    InsightFigure(value: c.count("extraAdmins"), label: "devices with more than one local admin", tone: .red, link: c.item("extraAdmins")?.link)
                    let workgroup = c.item("workgroup")
                    InsightFigure(value: workgroup?.count, label: "not joined to Entra or a domain", tone: .orange, link: workgroup?.link)
                }
                let byCount = c.items("byAdminCount")
                if !byCount.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        InsightHeading("Admins per device")
                        let max = byCount.map(\.count).max() ?? 1
                        ForEach(byCount) { b in InsightBarRow(label: b.label ?? b.key ?? "", count: b.count, max: max, tone: .indigo, link: b.link) }
                    }
                }
                let top = c.items("topDevices")
                if !top.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        InsightHeading("Most local admins")
                        ForEach(top) { d in
                            MaybeInsightLink(link: d.link) {
                                HStack {
                                    Text(d.name ?? d.string("serialNumber") ?? "").appFont(.callout).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text("\(d.int("admins") ?? 0) admins").appFont(.callout, weight: .medium).monospacedDigit()
                                }
                            }
                        }
                    }
                }
                let joins = c.items("join")
                if !joins.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        InsightHeading("Directory join")
                        let max = joins.map(\.count).max() ?? 1
                        ForEach(joins) { j in InsightBarRow(label: j.label ?? j.key ?? "", count: j.count, max: max, tone: .gray, link: j.link) }
                    }
                }
            }
        }
    }
}

// MARK: - 11 Unused Software

struct UnusedSoftwareCard: View {
    var body: some View {
        InsightCard(key: "unusedSoftware", title: "Unused Software", subtitle: "Installed widely, rarely opened", systemImage: "shippingbox", tone: .blue, link: DashboardLinks.report("applications", ["type": "usage", "period": "30"])) { c in
            VStack(alignment: .leading, spacing: 12) {
                let least = c.items("leastUsed")
                VStack(alignment: .leading, spacing: 2) {
                    InsightHeading("Least used, on \(c.int("minInstalls") ?? 10)+ devices (\(c.int("days") ?? 30) days)")
                    if least.isEmpty {
                        Text("No app is installed widely enough to judge").appFont(.caption).foregroundStyle(.secondary).padding(4)
                    } else {
                        ForEach(least) { app in
                            let installed = app.int("installedDevices") ?? 0, active = app.int("activeDevices") ?? 0
                            InsightBarRow(label: app.name ?? "", count: active, max: Swift.max(installed, 1), tone: .gray, link: app.link, valueText: "\(active) of \(installed)")
                        }
                    }
                }
                let most = c.items("mostUsed")
                if !most.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        InsightHeading("Most used")
                        let max = Int((most.compactMap { $0.double("totalHours") }.max() ?? 1).rounded())
                        ForEach(most) { app in
                            let hours = Int((app.double("totalHours") ?? 0).rounded())
                            InsightBarRow(label: app.name ?? "", count: hours, max: Swift.max(max, 1), tone: .blue, link: app.link, valueText: "\(hours) h")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 12 Connectivity Problems

struct ConnectivityProblemsCard: View {
    var body: some View {
        InsightCard(key: "connectivityProblems", title: "Connectivity Problems", subtitle: "Weak Wi-Fi, poor network quality and VPN", systemImage: "wifi.exclamationmark", tone: .teal, link: DashboardLinks.report("network")) { c in
            HStack(alignment: .top, spacing: 8) {
                let weak = c.item("weakSignal")
                InsightFigure(value: weak?.count, label: "weak Wi-Fi signal", tone: .red, link: weak?.link(or: DashboardLinks.report("network", ["signal": "weak"])))
                let poor = c.item("poorQuality")
                InsightFigure(value: poor?.count, label: "poor network quality of \(poor?.int("measured") ?? 0) measured", tone: .orange,
                              link: poor?.link(or: DashboardLinks.report("network", ["quality": "poor"])))
                let vpn = c.item("onVpn")
                InsightFigure(value: vpn?.count, label: "on VPN", tone: .blue, link: vpn?.link(or: DashboardLinks.report("network", ["vpn": "1"])))
            }
        }
    }
}
