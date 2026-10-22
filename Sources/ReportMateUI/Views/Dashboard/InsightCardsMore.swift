import SwiftUI
import ReportMateKit

// The twelve insight cards (revision 2 of the shared widget spec): each answers
// one question about the fleet. Every figure, bar, legend row and chip opens the
// link the API attached to it: the report with that filter on.

private extension InsightCardData {
    func count(_ key: String) -> Int? { item(key)?.count }
}

private extension InsightItem {
    /// The server's link when it opens the Tools Logs report (an older API pointed at /devices).
    var logsLink: DeepLink? { link.flatMap { $0.target == .managementLogs ? $0 : nil } }

    /// The server's link, or `fallback` when it gave a bare report path.
    func link(or fallback: DeepLink) -> DeepLink {
        guard let l = link, !l.query.isEmpty else { return fallback }
        return l
    }
}

/// The insight-column card for an API card key.
struct InsightCardView: View {
    let key: String
    let platform: PlatformFilter

    var body: some View {
        switch key {
        case "rebootDebt": RebootDebtCard()
        case "protectionGaps": ProtectionGapsCard()
        case "managementToolLogs", "managementToolErrors": ManagementToolLogsCard()
        case "storage": StorageCard()
        case "checkinGaps": CheckInGapsCard(platform: platform)
        case "updateDebt", "osCurrency": UpdateDebtCard()
        case "appUsage": AppUsageCard()
        case "userAccounts": UserAccountsCard()
        case "softwareRisk": SoftwareRiskCard()
        case "expiringCertificates": ExpiringCertificatesCard()
        case "directoryServices", "directoryJoin": DirectoryServicesCard(platform: platform)
        default: ConnectivityProblemsCard()
        }
    }
}

// MARK: - Uptime Overview

struct RebootDebtCard: View {
    var body: some View {
        InsightCard(key: "rebootDebt", title: "Uptime Overview", subtitle: "How long devices have been up", systemImage: "arrow.clockwise.circle", tone: .orange, link: DashboardLinks.system()) { c in
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
            }
        }
    }
}

// MARK: - Protection Gaps

struct ProtectionGapsCard: View {
    var body: some View {
        InsightCard(key: "protectionGaps", title: "Protection Gaps", subtitle: "Devices missing a protection, worst first", systemImage: "lock.trianglebadge.exclamationmark", tone: .red, link: DashboardLinks.report("security")) { c in
            VStack(alignment: .leading, spacing: 12) {
                let gaps = c.items("gaps").filter { $0.count > 0 }
                if gaps.isEmpty {
                    Text(c.items("gaps").isEmpty ? "No protection data reported" : "No device is missing a protection").appFont(.caption).foregroundStyle(.secondary)
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

// MARK: - Management Tools Logs

/// Errors and warnings in the management tools' own logs over the last day, per
/// tool, with the commonest error messages. Parsed by the API at ingest. The MDM
/// agent's own logs are left out.
struct ManagementToolLogsCard: View {
    var body: some View {
        InsightCard(key: "managementToolLogs", title: "Management Tools Logs", subtitle: "Errors and warnings in the tools' own logs", systemImage: AppSection.management.systemImage, tone: .yellow, link: DashboardLinks.managementLogs()) { c in
            VStack(alignment: .leading, spacing: 12) {
                let tools = ManagementToolMessages.tools(c).filter { ($0.int("devicesWithErrors") ?? 0) + ($0.int("devicesWithWarnings") ?? 0) > 0 }
                let hours = c.int("windowHours") ?? 24
                if tools.isEmpty {
                    Text("No tool reported an error or warning in the last \(hours) hours").appFont(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        InsightHeading("Devices with errors, last \(hours) hours")
                        ForEach(tools) { t in
                            let errors = t.int("devicesWithErrors") ?? 0, warnings = t.int("devicesWithWarnings") ?? 0
                            HStack(spacing: 8) {
                                let tool = t.string("tool")
                                MaybeInsightLink(link: DashboardLinks.managementLogs(tool: tool)) {
                                    Text(t.name ?? tool ?? "").appFont(.callout, weight: .medium).lineLimit(1).frame(width: 110, alignment: .leading)
                                }
                                MaybeInsightLink(link: t.logsLink ?? DashboardLinks.managementLogs(tool: tool, level: "error")) {
                                    Text("\(errors) errors").appFont(.callout).foregroundStyle(errors == 0 ? Color.secondary : Tone.red.color).monospacedDigit()
                                }
                                MaybeInsightLink(link: InsightItem(json: .object(["link": t.json["warningsLink"]])).logsLink ?? DashboardLinks.managementLogs(tool: tool, level: "warning")) {
                                    Text("\(warnings) warnings").appFont(.callout).foregroundStyle(warnings == 0 ? Color.secondary : Tone.yellow.color).monospacedDigit()
                                }
                                Spacer(minLength: 0)
                                Text("\(t.int("errorLines") ?? 0) lines").appFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }
                // Grouped by tool and message with the timestamp and level stripped.
                let top = Array(ManagementToolMessages.topErrors(c).prefix(5))
                if !top.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        InsightHeading("Commonest errors")
                        ForEach(Array(top.enumerated()), id: \.offset) { _, g in
                            let e = g.item
                            let tool = e.string("tool") ?? ""
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                MaybeInsightLink(link: e.logsLink ?? DashboardLinks.managementLogs(tool: tool, message: e.string("id") ?? ManagementToolsFleet.messageID(tool: tool, message: g.message))) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(g.message).appFont(.callout).lineLimit(2).truncationMode(.middle)
                                        Text("\(e.string("name") ?? "") · \(g.devices) devices · \(g.lines) lines").appFont(.caption).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                if let sample = e.item("sampleDevice"), let link = sample.link {
                                    InsightLink(link: link) { Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.secondary) }
                                        .accessibilityLabel("Open an example device's log")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Storage

struct StorageCard: View {
    var body: some View {
        InsightCard(key: "storage", title: "Storage", subtitle: "Free space, capacity and the fullest devices", systemImage: "internaldrive", tone: .teal, link: DashboardLinks.report("hardware")) { c in
            VStack(alignment: .leading, spacing: 12) {
                let low = c.item("lowStorage")
                HStack(alignment: .top, spacing: 8) {
                    InsightFigure(value: low?.count, label: "under 10% free", tone: .red, link: low?.link)
                    ForEach((low?.items("byPlatform") ?? []).filter { $0.count > 0 }) { p in
                        InsightFigure(value: p.count, label: "\(p.name ?? "") under 10%", tone: .orange, link: p.link)
                    }
                }
                let free = c.items("freeSpace")
                if !free.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        InsightHeading("Free space")
                        let max = free.map(\.count).max() ?? 1
                        ForEach(free) { b in
                            InsightBarRow(label: b.label ?? b.key ?? "", count: b.count, max: max, tone: b.key == "lt5" ? .red : b.key == "5-10" ? .orange : b.key == "10-20" ? .yellow : .green, link: b.link)
                        }
                    }
                }
                let capacity = c.items("capacity")
                if !capacity.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        InsightHeading("Capacity")
                        let max = capacity.map(\.count).max() ?? 1
                        ForEach(capacity) { b in InsightBarRow(label: b.label ?? b.key ?? "", count: b.count, max: max, tone: .teal, link: b.link) }
                    }
                }
                let fullest = c.items("fullest")
                if !fullest.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        InsightHeading("Fullest devices")
                        ForEach(fullest) { d in
                            MaybeInsightLink(link: d.link) {
                                HStack {
                                    Text(d.name ?? d.string("serialNumber") ?? "").appFont(.callout).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: Int64((d.double("freeBytes") ?? 0).safeInt), countStyle: .decimal) + " free")
                                        .appFont(.caption).foregroundStyle(.secondary)
                                    Text(String(format: "%.1f%%", d.double("freePct") ?? 0)).appFont(.callout, weight: .medium).foregroundStyle(Tone.red.color).monospacedDigit()
                                        .frame(minWidth: 48, alignment: .trailing)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Install Health

/// Column 1, under Fleet Status, in place of the old Errors and Warnings tiles.
/// The two headline counts are the largest numbers on the dashboard. Until the
/// card answers they come from the dashboard payload, so they show with Fleet Status.
struct InstallHealthCard: View {
    let stats: InstallStats?
    let platform: PlatformFilter
    @Environment(AppState.self) private var appState
    @Environment(DashboardInsightsModel.self) private var insights
    @Environment(\.insightsRetry) private var retry

    var body: some View {
        let link = DashboardLinks.installs()
        let c = insights.card("installHealth").flatMap { $0.error == nil ? $0 : nil }
        Card {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader("Installs", subtitle: "Munki and Cimian across the fleet", systemImage: "arrow.down.circle", tone: .green) { appState.follow(link) }
                    .help(appState.describe(link))
                    .linkContextMenu(link)
                    .accessibilityAddTraits(.isButton)
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        hero(c?.item("withErrors")?.count ?? stats.flatMap { $0.devicesWithErrors(for: platform) }, label: "devices with errors", tone: .red,
                             link: c?.item("withErrors")?.link ?? DashboardLinks.installs(filter: "errors"))
                        hero(c?.item("withWarnings")?.count ?? stats.flatMap { $0.devicesWithWarnings(for: platform) }, label: "devices with warnings", tone: .yellow,
                             link: c?.item("withWarnings")?.link ?? DashboardLinks.installs(filter: "warnings"))
                    }
                    details(c)
                }
                .padding(16)
            }
        }
    }

    private func hero(_ value: Int?, label: String, tone: Tone, link: DeepLink) -> some View {
        InsightLink(link: link) {
            VStack(alignment: .leading, spacing: 2) {
                if let value {
                    Text("\(value)").font(.system(size: 52, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(value == 0 ? Color.secondary : tone.color)
                        .minimumScaleFactor(0.5).lineLimit(1)
                } else {
                    SkeletonBlock(width: 72, height: 52, radius: 10)
                }
                Text(label).appFont(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func details(_ c: InsightCardData?) -> some View {
        if let c {
            // Munki against Cimian: devices with errors and warnings, then items.
            let agents = c.items("byAgent").filter { ($0.int("devices") ?? 0) > 0 }
            if !agents.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(agents) { a in
                        let e = a.item("withErrors"), w = a.item("withWarnings"), ei = a.item("errorItems"), wi = a.item("warningItems")
                        HStack(spacing: 8) {
                            Text(a.name ?? a.string("agent") ?? "").appFont(.callout, weight: .medium).frame(width: 60, alignment: .leading)
                            MaybeInsightLink(link: e?.link) {
                                Text("\(e?.count ?? 0) with errors").appFont(.callout).foregroundStyle((e?.count ?? 0) == 0 ? Color.secondary : Tone.red.color).monospacedDigit()
                            }
                            MaybeInsightLink(link: w?.link) {
                                Text("\(w?.count ?? 0) with warnings").appFont(.callout).foregroundStyle((w?.count ?? 0) == 0 ? Color.secondary : Tone.yellow.color).monospacedDigit()
                            }
                            Spacer(minLength: 0)
                            MaybeInsightLink(link: ei?.link ?? wi?.link) {
                                Text("\(ei?.count ?? 0) / \(wi?.count ?? 0) items").appFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .help("Error items / warning items")
                        }
                    }
                }
            }
            let pending = c.item("pending"), silent = c.item("silentAgents")
            InsightChips {
                StatChip(value: c.item("errorItems")?.count ?? 0, label: "error items", tone: .red, link: c.item("errorItems")?.link)
                StatChip(value: c.item("warningItems")?.count ?? 0, label: "warning items", tone: .yellow, link: c.item("warningItems")?.link)
                StatChip(value: pending?.int("items") ?? 0, label: "pending on \(pending?.int("devices") ?? 0) devices", tone: .blue, link: pending?.link)
                StatChip(value: silent?.count ?? 0, label: "agents silent over \(silent?.int("thresholdDays") ?? 7) days", tone: .orange, link: silent?.link)
            }
            let top = c.items("topFailing").filter { $0.count > 0 }
            VStack(alignment: .leading, spacing: 2) {
                InsightHeading("Top failing items")
                if top.isEmpty {
                    Text("No failing items").appFont(.caption).foregroundStyle(.secondary).padding(4)
                } else {
                    let max = top.map(\.count).max() ?? 1
                    ForEach(top) { item in InsightBarRow(label: item.name ?? "", count: item.count, max: max, tone: .red, link: item.link) }
                }
            }
        } else if let message = insights.card("installHealth")?.error ?? (insights.loading ? nil : insights.error) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle").appFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 8)
                Button("Retry") { retry() }.controlSize(.small)
            }
        } else {
            SkeletonBars(count: 4).skeletonAccessibility("Loading install items").skeletonTimeout(retry: retry)
        }
    }
}

// MARK: - Check-in Gaps

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
                let reasons = c.items("reasons").filter { $0.count > 0 }
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

// MARK: - Update Debt

/// Patch level against the fleet's latest, with the devices that have updates pending
/// or deferred (which used to sit on the reboot card).
struct UpdateDebtCard: View {
    @Environment(DashboardInsightsModel.self) private var insights

    var body: some View {
        InsightCard(key: "updateDebt", title: "Update Debt", subtitle: "Patch level, pending and deferred updates", systemImage: "arrow.triangle.2.circlepath", tone: .blue, link: DashboardLinks.system()) { c in
            VStack(alignment: .leading, spacing: 12) {
                let behind = c.item("behind")
                if (c.int("rated") ?? 0) > 0 {
                    InsightDonut(data: [
                        InsightSlice(label: "On latest patch", count: c.int("onLatest") ?? 0, color: .green, link: DashboardLinks.system(["patch": "latest"])),
                        InsightSlice(label: "Behind", count: behind?.count ?? 0, color: .orange, link: behind?.link),
                    ], center: "\(c.int("pctOnLatest") ?? 0)%")
                }
                InsightChips {
                    // An API from before the split still carries these on the reboot card.
                    let reboot = insights.card("rebootDebt")
                    let pending = c.item("pendingUpdates") ?? reboot?.item("pendingUpdates")
                    let deferred = c.item("deferredUpdates") ?? reboot?.item("deferredUpdates")
                    StatChip(value: pending?.count ?? 0, label: "with pending updates", tone: .yellow, link: pending?.link)
                    StatChip(value: deferred?.count ?? 0, label: "with deferred updates", tone: .orange, link: deferred?.link)
                    StatChip(value: c.count("unsupportedMac") ?? 0, label: "unsupported macOS", tone: .red, link: c.item("unsupportedMac")?.link)
                    StatChip(value: c.count("windows10") ?? 0, label: "on Windows 10", tone: .orange, link: c.item("windows10")?.link)
                }
                let lagging = c.items("lagging").filter { $0.count > 0 }
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

// MARK: - Software Risk

struct SoftwareRiskCard: View {
    var body: some View {
        InsightCard(key: "softwareRisk", title: "Software Risk", subtitle: "Vulnerabilities and out-of-date items", systemImage: "exclamationmark.shield", tone: .red, link: DashboardLinks.report("security")) { c in
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    InsightFigure(value: c.count("criticalCves"), label: "devices with critical CVEs", tone: .red, link: c.item("criticalCves")?.link)
                    InsightFigure(value: c.count("exploitedCves"), label: "with actively exploited CVEs", tone: .red, link: c.item("exploitedCves")?.link)
                }
                let behind = c.items("itemsBehind").filter { $0.count > 0 }
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

// MARK: - Expiring Certificates

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

// MARK: - Directory Services

/// The Identity report's Directory Services classification: Cloud Joined, Domain
/// Joined (Trusted, Unconfirmed, Broken), Standard and Unjoined, with extra local
/// admins and shared or assigned use. It follows the global platform toggle; no
/// card has a platform control of its own.
struct DirectoryServicesCard: View {
    let platform: PlatformFilter

    private static let colors: [String: Color] = [
        "cloud joined": .green, "domain joined": .orange, "standard": .blue, "unjoined": .red,
        "cloud": .green,
        "trusted": .yellow, "unconfirmed": .orange, "broken": .red,
        // The API's earlier keys.
        "entra": .green, "domain": .orange, "hybrid": .teal, "workgroup": .red, "psso": .green, "bound": .orange, "unbound": .red,
    ]

    private func color(_ s: InsightItem) -> Color {
        Self.colors[(s.label ?? "").lowercased()] ?? Self.colors[(s.key ?? "").lowercased().replacingOccurrences(of: "-", with: " ")] ?? .gray
    }

    var body: some View {
        InsightCard(key: "directoryServices", title: "Directory Services", subtitle: "How devices are joined, and shared or assigned use", systemImage: "person.badge.key", tone: .indigo, link: DashboardLinks.report("identity")) { c in
            // The current card is one classification for the toggle's platform; an earlier
            // API sent three views, of which the toggle picks one.
            let section = c.json["segments"].array != nil ? InsightItem(json: c.json)
                : InsightItem(json: c.json["views"][platform == .macOS ? "mac" : platform == .windows ? "windows" : "all"])
            let segments = section.items("segments").filter { $0.count > 0 }
            VStack(alignment: .leading, spacing: 12) {
                if segments.isEmpty {
                    Text("No directory data reported").appFont(.caption).foregroundStyle(.secondary)
                } else {
                    // Domain Joined's trust states disclose under its legend row, collapsed at first,
                    // as the identity report's widget shows them.
                    InsightDonut(data: segments.map { s in
                        InsightSlice(label: s.label ?? s.key ?? "", count: s.count, color: color(s), link: s.link,
                                     children: s.items("children").map { InsightSlice(label: $0.label ?? $0.key ?? "", count: $0.count, color: color($0), link: $0.link) })
                    }, center: "\(section.int("total") ?? section.int("devices") ?? segments.reduce(0) { $0 + $1.count })")
                }
                InsightChips {
                    StatChip(value: section.item("shared")?.count ?? 0, label: "shared", tone: .blue, link: section.item("shared")?.link)
                    StatChip(value: section.item("assigned")?.count ?? 0, label: "assigned", tone: .indigo, link: section.item("assigned")?.link)
                }
            }
        }
    }
}

// MARK: - User Accounts

/// Accounts, from the Identity report's own rules: the Authentication donut (Modern
/// against Standard), the admin accounts on the most devices, and devices with
/// more local admins than the managed ones. Follows the global platform toggle.
struct UserAccountsCard: View {
    private static let authColors: [String: Color] = ["modern": .green, "legacy": .orange, "standard": .blue]

    var body: some View {
        InsightCard(key: "userAccounts", title: "User Accounts", subtitle: "Authentication and administrator accounts", systemImage: AppSection.identity.systemImage, tone: .indigo, link: DashboardLinks.report("identity")) { c in
            VStack(alignment: .leading, spacing: 12) {
                // The authentication split, as a list or as {segments: […]}.
                let auth = (c.items("authentication") + (c.item("authentication")?.items("segments") ?? []) + c.items("auth")).filter { $0.count > 0 }
                if !auth.isEmpty {
                    InsightDonut(data: auth.map { s in
                        InsightSlice(label: s.label ?? s.key?.capitalized ?? "", count: s.count,
                                     color: Self.authColors[(s.key ?? s.label ?? "").lowercased()] ?? .gray,
                                     link: s.link ?? s.key.map { DashboardLinks.report("identity", ["auth": $0.lowercased()]) })
                    }, center: c.int("total").map(String.init))
                }
                let admins = Array((c.items("topAdmins") + c.items("adminAccounts") + c.items("admins")).filter { $0.count > 0 }.prefix(5))
                if !admins.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        InsightHeading("Administrator accounts")
                        let max = admins.map(\.count).max() ?? 1
                        ForEach(admins) { a in
                            let name = a.string("name") ?? a.string("account") ?? a.label ?? ""
                            InsightBarRow(label: name, count: a.count, max: max, tone: .indigo,
                                          link: a.link ?? DashboardLinks.report("identity", ["admin": name]), valueText: "\(a.count) devices")
                        }
                    }
                }
                let extra = c.item("extraAdmins")
                InsightChips {
                    StatChip(value: extra?.count ?? 0, label: "devices with extra local admins", tone: .red,
                             link: extra?.link ?? DashboardLinks.report("identity", ["admins": "extra"]))
                }
            }
        }
    }
}

// MARK: - App Usage

/// In the wide column under Recent Events: the ten most-used apps over 30 days,
/// narrowed by Usage and Catalog chips like Platform Distribution's. Each
/// combination is its own cached answer, and each app's link carries the chips.
struct AppUsageCard: View {
    @Environment(AppState.self) private var appState
    @Environment(DashboardInsightsModel.self) private var insights

    var body: some View {
        let link = (insights.card(DashboardInsightsDocument.appUsageKey).flatMap { InsightItem(json: $0.json).link })
            ?? DashboardLinks.report("applications", ["type": "usage", "period": "30"])
        InsightCard(key: DashboardInsightsDocument.appUsageKey, title: "App Usage", subtitle: "Most used apps, last 30 days", systemImage: "chart.bar.xaxis", tone: .blue, link: link) { c in
            VStack(alignment: .leading, spacing: 10) {
                chips(c)
                let apps = Array(c.items("apps").prefix(10))
                if apps.isEmpty {
                    Text("No usage recorded for this selection").appFont(.caption).foregroundStyle(.secondary)
                } else {
                    let max = apps.compactMap { $0.double("totalHours") }.max() ?? 1
                    VStack(alignment: .leading, spacing: 2) {
                        AppUsageHeader()
                        ForEach(apps) { app in AppUsageRow(app: app, maxHours: max) }
                    }
                }
            }
            .opacity(insights.appUsageLoading ? 0.6 : 1)
        }
    }

    @ViewBuilder
    private func chips(_ c: InsightCardData) -> some View {
        let available = c.item("available")
        let usages = available?.items("usages").compactMap { $0.string("value") } ?? []
        let catalogs = available?.items("catalogs").compactMap { $0.string("value") } ?? []
        if !usages.isEmpty || !catalogs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !usages.isEmpty { pillRow("Usage", usages, selected: insights.appUsageUsages, tone: .purple) { toggle(\.appUsageUsages, $0) } }
                if !catalogs.isEmpty { pillRow("Catalog", catalogs, selected: insights.appUsageCatalogs, tone: .green) { toggle(\.appUsageCatalogs, $0) } }
            }
        }
    }

    private func pillRow(_ label: String, _ values: [String], selected: Set<String>, tone: Tone, toggle: @escaping (String) -> Void) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label.uppercased()).appFont(.caption2).foregroundStyle(.secondary).frame(width: 52, alignment: .leading).padding(.top, 4)
            FlowLayout(spacing: 4) {
                ForEach(values, id: \.self) { v in FilterPill(text: v, selected: selected.contains(v), tone: tone, size: 10) { toggle(v) } }
            }
        }
    }

    private func toggle(_ keyPath: ReferenceWritableKeyPath<DashboardInsightsModel, Set<String>>, _ value: String) {
        if insights[keyPath: keyPath].contains(value) { insights[keyPath: keyPath].remove(value) } else { insights[keyPath: keyPath].insert(value) }
        Task { await insights.loadAppUsage(api: appState.api, platform: appState.platformFilter) }
    }
}

// MARK: - Connectivity Problems

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

/// App Usage's column widths, shared by the header and every row so they line up.
enum AppUsageColumns {
    static let bar: CGFloat = 60
    static let hours: CGFloat = 64
    static let devices: CGFloat = 56
}

/// App · Hours · Devices, over the rows.
struct AppUsageHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("App").frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: AppUsageColumns.bar, height: 1)
            Text("Hours").frame(width: AppUsageColumns.hours, alignment: .trailing)
            Text("Devices").frame(width: AppUsageColumns.devices, alignment: .trailing)
        }
        .appFont(.caption2, weight: .semibold)
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .padding(.horizontal, 4)
        .accessibilityHidden(true)
    }
}

/// One App Usage row on the shared grid: name (flexible, truncated) | 60 pt bar |
/// compact hours | device count. The full name and exact hours are in the tooltip.
struct AppUsageRow: View {
    let app: InsightItem
    let maxHours: Double

    private static let exact: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 1
        return f
    }()

    var body: some View {
        let hours = app.double("totalHours") ?? 0
        let devices = app.int("activeDevices") ?? app.int("devices") ?? 0
        let name = app.name ?? ""
        MaybeInsightLink(link: app.link) {
            HStack(spacing: 10) {
                Text(name).appFont(.callout).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.12))
                        Capsule().fill(Tone.blue.color.opacity(0.75)).frame(width: maxHours > 0 ? geo.size.width * hours / maxHours : 0)
                    }
                }
                .frame(width: AppUsageColumns.bar, height: 6)
                Text(CompactHours.format(hours))
                    .appFont(.callout, weight: .medium).monospacedDigit()
                    .frame(width: AppUsageColumns.hours, alignment: .trailing)
                Text("\(devices)")
                    .appFont(.callout).foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: AppUsageColumns.devices, alignment: .trailing)
            }
        }
        .help("\(name): \(Self.exact.string(from: NSNumber(value: hours)) ?? "0") hours on \(devices) devices")
        .accessibilityElement(children: .combine)
    }
}
