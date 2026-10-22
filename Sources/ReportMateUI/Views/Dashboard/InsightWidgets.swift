import SwiftUI
import Charts
import ReportMateKit

/// The dashboard's insight cards: one per module report, built from the same
/// endpoints the report pages read. The dashboard payload itself carries devices
/// and events only, so these load after it, two at a time, and each card shows a
/// placeholder until its data answers. One fetch feeds every card that reads it:
/// `/security` serves both Security Posture and Certificates.
@MainActor
@Observable
final class DashboardInsightsModel {
    /// The sources in load order. Install rows load last and on their own (see `loadInstallRecords`).
    enum Source: String, CaseIterable, Sendable {
        case system, security, management, hardware, identity, failures, appUsage, certificates, network, peripherals, installsFilters
    }

    enum Payload: Sendable {
        case json(JSONValue)
        case failures(IngestFailuresPage)
        case usage(UtilizationData)
        case installs(InstallsFilterOptions)
    }

    private(set) var reports: [Source: [ReportRow]] = [:]
    private(set) var failures: IngestFailuresPage?
    private(set) var appUsage: UtilizationData?
    private(set) var certificates: [JSONValue]?
    private(set) var installsFilters: InstallsFilterOptions?
    /// The bulk `/installs` rows behind the top-item lists. Large and sometimes a 502,
    /// so optional: when they fail the cards show their counts without the lists.
    private(set) var installRecords: [InstallRecord]?
    private(set) var installRecordsLoading = false
    private(set) var installRecordsFailed = false
    private var installRecordsAt: Date?

    var loading: Set<Source> = []
    var errors: [Source: String] = [:]
    var loadedAt: Date?
    /// The connection the shown cards were loaded with, and a counter that marks
    /// the newest load. A load started before the credential changed (an inherited
    /// passphrase swapped for Entra, say) finishes later than the one that replaced
    /// it; its results, 401s included, are dropped instead of overwriting the cards.
    private var loadedWith: AppConfiguration?
    private var generation = 0

    func rows(_ source: Source) -> [ReportRow] { reports[source] ?? [] }
    func isLoading(_ source: Source) -> Bool { loading.contains(source) }
    func error(_ source: Source) -> String? { errors[source] }

    func load(api: ReportMateAPI, force: Bool = false) async {
        if !force, loadedWith == api.configuration, let loadedAt, Date().timeIntervalSince(loadedAt) < 300 { return }
        if loadedWith != api.configuration {
            installRecords = nil
            installRecordsAt = nil
        }
        generation += 1
        let mine = generation
        loading = Set(Source.allCases)
        // Two at a time: each bulk report takes the API ten seconds or more, and
        // four at once had the gateway answer 503 for the last one. A 5xx or a
        // dropped connection gets one retry after a short pause.
        await withTaskGroup(of: (Source, Result<Payload, Error>).self) { group in
            var next = Source.allCases.makeIterator()
            for _ in 0..<2 { if let s = next.next() { group.addTask { (s, await Self.fetch(s, api: api)) } } }
            while let (source, result) = await group.next() {
                guard mine == generation else { group.cancelAll(); return }
                if let more = next.next() { group.addTask { (more, await Self.fetch(more, api: api)) } }
                switch result {
                case .success(let payload):
                    errors[source] = nil
                    apply(payload, to: source)
                case .failure(let error):
                    errors[source] = error.localizedDescription
                }
                loading.remove(source)
            }
        }
        guard mine == generation else { return }
        loadedAt = Date()
        loadedWith = api.configuration
        // Not awaited: the paged install rows take a minute or more, and the cards
        // above must not wait on them.
        if !installRecordsLoading { Task { await loadInstallRecords(api: api, generation: mine, force: force) } }
    }

    private func apply(_ payload: Payload, to source: Source) {
        switch payload {
        case .json(let json):
            if source == .certificates {
                certificates = json.array ?? json["data"].elements
            } else {
                reports[source] = FleetReportModel.extractRows(json).map(ReportRow.init(json:))
            }
        case .failures(let page): failures = page
        case .usage(let usage): appUsage = usage
        case .installs(let options): installsFilters = options
        }
    }

    nonisolated private static func fetch(_ source: Source, api: ReportMateAPI) async -> Result<Payload, Error> {
        await retrying {
            switch source {
            case .failures: return .failures(try await api.ingestFailures(limit: 1, hours: 24, outcome: "rejected"))
            case .appUsage: return .usage(try await api.applicationUsage(query: ["days": "30"]))
            case .installsFilters: return .installs(try await api.installsFilters())
            case .certificates: return .json(try await api.fleetReport("/security/certificates", query: ["status": "expiring"]))
            default: return .json(try await api.fleetReport("/\(source.rawValue)"))
            }
        }
    }

    nonisolated private static func retrying<T: Sendable>(_ work: @Sendable () async throws -> T) async -> Result<T, Error> {
        for attempt in 0..<2 {
            do { return .success(try await work()) }
            catch {
                let retry: Bool
                switch error as? APIError {
                case .http(let status, _, _): retry = status >= 500
                case .transport: retry = true
                default: retry = false
                }
                if !retry || attempt == 1 { return .failure(error) }
                try? await Task.sleep(for: .seconds(3))
            }
        }
        return .failure(APIError.transport("gave up"))
    }

    /// The 130k-row `/installs` list, paged, after everything else. It refreshes every
    /// half hour rather than every five minutes: it only feeds two top-five lists.
    private func loadInstallRecords(api: ReportMateAPI, generation mine: Int, force: Bool) async {
        if !force, let at = installRecordsAt, Date().timeIntervalSince(at) < 1800 { return }
        installRecordsLoading = true
        defer { installRecordsLoading = false }
        var rows: [InstallRecord] = []
        var offset = 0
        let pageSize = 5000
        while true {
            let at = offset
            let page = await Self.retrying { try await api.installRecords(limit: pageSize, offset: at) }
            guard mine == generation else { return }
            switch page {
            case .success(let records):
                rows.append(contentsOf: records)
                offset += records.count
                if records.count < pageSize {
                    installRecords = rows
                    installRecordsFailed = false
                    installRecordsAt = Date()
                    return
                }
            case .failure:
                installRecordsFailed = installRecords == nil
                return
            }
        }
    }
}

// MARK: - Card chrome

/// Card chrome shared by the insight widgets: a header that opens the report
/// unfiltered, then the body or a placeholder while the data loads.
struct InsightCard<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tone: Tone
    let link: DeepLink
    let loading: Bool
    let error: String?
    let empty: Bool
    @ViewBuilder var content: Content
    @Environment(AppState.self) private var appState

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(title, subtitle: subtitle, systemImage: systemImage, tone: tone) { appState.follow(link) }
                    .help(appState.describe(link))
                    .linkContextMenu(link)
                    .accessibilityAddTraits(.isButton)
                Group {
                    if let error, empty {
                        Label(error, systemImage: "exclamationmark.triangle").appFont(.caption).foregroundStyle(.secondary).padding(16)
                    } else if loading, empty {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading…").appFont(.caption).foregroundStyle(.secondary) }.padding(16)
                    } else if empty {
                        Text("No data").appFont(.caption).foregroundStyle(.secondary).padding(16)
                    } else {
                        content.padding(16)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}

/// "Label … bar … n of N" compliance row; the link opens the devices that fall short.
struct ComplianceRow: View {
    let label: String
    let on: Int
    let total: Int
    let link: DeepLink

    var body: some View {
        let pct = total == 0 ? 0 : Double(on) / Double(total)
        let tone: Tone = pct >= 0.9 ? .green : pct >= 0.7 ? .yellow : .red
        InsightLink(link: link) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(label).appFont(.callout)
                    Spacer()
                    Text("\(on) of \(total)").appFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Text("\(Int((pct * 100).rounded()))%").appFont(.caption, weight: .medium).foregroundStyle(tone.color).monospacedDigit().frame(width: 38, alignment: .trailing)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.12))
                        Capsule().fill(tone.color).frame(width: max(0, geo.size.width * pct))
                    }
                }
                .frame(height: 6)
            }
        }
    }
}

/// One slice of an insight donut, with the link its legend row opens.
struct InsightSlice: Identifiable {
    var id: String { label }
    let label: String
    let count: Int
    let color: Color
    var link: DeepLink? = nil
}

/// Ring plus legend, the dashboard's small donut. Each legend row opens its slice.
struct InsightDonut: View {
    let data: [InsightSlice]
    var center: String? = nil

    var body: some View {
        let total = data.reduce(0) { $0 + $1.count }
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Chart(data) { item in
                    SectorMark(angle: .value("Count", item.count), innerRadius: .ratio(0.64), angularInset: 1)
                        .foregroundStyle(item.color)
                }
                .chartLegend(.hidden)
                .frame(width: 96, height: 96)
                if let center { Text(center).appFont(.callout, weight: .semibold).monospacedDigit() }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(data) { item in
                    let row = HStack(spacing: 6) {
                        Circle().fill(item.color).frame(width: 9, height: 9)
                        Text(item.label).appFont(.callout).lineLimit(1)
                        Spacer(minLength: 6)
                        Text("\(item.count)").appFont(.callout, weight: .medium).monospacedDigit()
                        Text(total == 0 ? "" : "\(Int((Double(item.count) / Double(total) * 100).rounded()))%").appFont(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 34, alignment: .trailing)
                    }
                    if let link = item.link { InsightLink(link: link) { row } } else { row.padding(.horizontal, 4).padding(.vertical, 2) }
                }
            }
        }
    }
}

/// Small "n label" stat chip that opens the devices it counts.
struct StatChip: View {
    let value: Int
    let label: String
    let tone: Tone
    let link: DeepLink

    var body: some View {
        InsightLink(link: link) {
            HStack(spacing: 6) {
                Text("\(value)").appFont(.callout, weight: .semibold).foregroundStyle(value == 0 ? Color.secondary : tone.color).monospacedDigit()
                Text(label).appFont(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.subtleBackground, in: Capsule())
            .overlay(Capsule().stroke(Color.cardBorder))
        }
    }
}

/// "Label … bar … n" row for ranked lists (providers, failing items, reasons).
struct InsightBarRow: View {
    let label: String
    let count: Int
    let max: Int
    let tone: Tone
    let link: DeepLink
    var valueText: String? = nil

    var body: some View {
        InsightLink(link: link) {
            HStack(spacing: 8) {
                Text(label).appFont(.callout).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.12))
                        Capsule().fill(tone.color.opacity(0.75)).frame(width: max == 0 ? 0 : geo.size.width * CGFloat(count) / CGFloat(max))
                    }
                }
                .frame(width: 70, height: 6)
                Text(valueText ?? "\(count)").appFont(.callout, weight: .medium).monospacedDigit().frame(minWidth: 30, alignment: .trailing)
            }
        }
    }
}

/// A big figure with a caption, for the headline counts on a card.
struct InsightFigure: View {
    let value: Int?
    let label: String
    let tone: Tone
    let link: DeepLink

    var body: some View {
        InsightLink(link: link) {
            VStack(alignment: .leading, spacing: 1) {
                Text(value.map(String.init) ?? "–").appFont(.title2, weight: .bold).foregroundStyle((value ?? 0) == 0 ? Color.secondary : tone.color).monospacedDigit()
                Text(label).appFont(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Small caps heading inside a card.
struct InsightHeading: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).appFont(.caption2, weight: .semibold).foregroundStyle(.secondary).padding(.horizontal, 4)
    }
}

/// Wraps chips onto as many lines as they need.
struct InsightChips<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { FlowLayout(spacing: 6) { content } }
}

// MARK: - 1 System health

struct SystemInsightWidget: View {
    let rows: [ReportRow]
    let loading: Bool
    let error: String?

    private struct Stats { let buckets: [String: Int]; let pending: Int; let deferred: Int }
    private var stats: Stats {
        let s = rows.map { SystemReportRow(json: $0.json) }
        var buckets: [String: Int] = [:]
        for row in s { if let b = SystemBuckets.uptimeBucket(row.uptime) { buckets[b.key, default: 0] += 1 } }
        return Stats(buckets: buckets, pending: s.filter { $0.pendingUpdatesCount > 0 }.count, deferred: s.filter { $0.deferredUpdatesCount > 0 }.count)
    }

    var body: some View {
        let st = stats
        let buckets = st.buckets
        let max = buckets.values.max() ?? 1
        InsightCard(title: "System Health", subtitle: "Uptime and pending updates", systemImage: "gearshape.2", tone: .orange, link: DashboardLinks.system(), loading: loading, error: error, empty: rows.isEmpty) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    InsightHeading("Uptime")
                    ForEach(SystemBuckets.uptime.map(\.bucket), id: \.key) { b in
                        let count = buckets[b.key] ?? 0
                        InsightLink(link: DashboardLinks.system(["uptime": b.key])) {
                            HStack(spacing: 8) {
                                Text(b.label).appFont(.callout).frame(width: 96, alignment: .leading)
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.secondary.opacity(0.12))
                                        Capsule().fill(Tone.orange.color).frame(width: max == 0 ? 0 : geo.size.width * CGFloat(count) / CGFloat(max))
                                    }
                                }
                                .frame(height: 8)
                                Text("\(count)").appFont(.callout, weight: .medium).monospacedDigit().frame(width: 40, alignment: .trailing)
                            }
                        }
                    }
                }
                InsightChips {
                    StatChip(value: st.pending, label: "with pending updates", tone: .yellow, link: DashboardLinks.system(["pending": "1-5,6-10,10+"]))
                    StatChip(value: st.deferred, label: "with deferred updates", tone: .orange, link: DashboardLinks.system(["deferred": "1"]))
                }
            }
        }
    }
}

// MARK: - 2 Security posture

struct SecurityPostureWidget: View {
    let rows: [ReportRow]
    let loading: Bool
    let error: String?

    private func sec(_ q: [String: String]) -> DeepLink { DashboardLinks.report("security", q) }

    var body: some View {
        let s = rows.map { SecurityReportRow(json: $0.json, platform: $0.platform) }
        let macs = s.filter { !$0.isWindows }
        let wins = s.filter(\.isWindows)
        let protectors = s.filter(\.reportsProtection)
        InsightCard(title: "Security Posture", subtitle: "Fleet-wide protections in place", systemImage: "lock.shield", tone: .green, link: sec([:]), loading: loading, error: error, empty: rows.isEmpty) {
            VStack(alignment: .leading, spacing: 8) {
                ComplianceRow(label: "Disk encryption", on: s.filter(\.encryptionEnabled).count, total: s.count, link: sec(["encryption": "off"]))
                ComplianceRow(label: "Firewall", on: s.filter(\.firewallEnabled).count, total: s.count, link: sec(["firewall": "off"]))
                if !protectors.isEmpty {
                    ComplianceRow(label: "Antivirus protection", on: protectors.filter(\.antivirusEnabled).count, total: protectors.count, link: sec(["antivirus": "off"]))
                }
                let sipRows = macs.filter { $0.sipEnabled != nil }
                if !sipRows.isEmpty {
                    ComplianceRow(label: "System Integrity Protection", on: sipRows.filter { $0.sipEnabled == true }.count, total: sipRows.count, link: sec(["sip": "off"]))
                }
                if !wins.isEmpty {
                    ComplianceRow(label: "Secure Boot", on: wins.filter(\.secureBootEnabled).count, total: wins.count, link: sec(["secureBoot": "off"]))
                }
                InsightChips {
                    StatChip(value: s.filter { $0.activeThreatCount > 0 }.count, label: "with threats", tone: .red, link: sec(["threats": "1"]))
                    StatChip(value: s.filter { $0.userExpiredCertCount > 0 }.count, label: "expired certs", tone: .yellow, link: sec(["certs": "expired"]))
                    StatChip(value: s.filter { $0.criticalCveCount > 0 }.count, label: "critical CVEs", tone: .orange, link: sec(["cve": "critical"]))
                }
                .padding(.top, 4)
            }
        }
    }
}

// MARK: - 3 Management

struct ManagementInsightWidget: View {
    let rows: [ReportRow]
    let loading: Bool
    let error: String?

    private struct Stats { let total: Int; let enrolled: Int; let top: [DashboardInsights.NamedCount] }
    private var stats: Stats {
        let m = rows.map { ManagementReportRow(json: $0.json) }
        var providers: [String: Int] = [:]
        for row in m { providers[row.provider, default: 0] += 1 }
        let top = providers.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(5).map { DashboardInsights.NamedCount(name: $0.key, count: $0.value) }
        return Stats(total: m.count, enrolled: m.filter(\.isEnrolled).count, top: top)
    }

    var body: some View {
        let st = stats
        let max = st.top.first?.count ?? 1
        InsightCard(title: "Management", subtitle: "MDM enrollment across the fleet", systemImage: "checkmark.shield", tone: .purple, link: DashboardLinks.report("management"), loading: loading, error: error, empty: rows.isEmpty) {
            VStack(alignment: .leading, spacing: 14) {
                InsightDonut(data: [
                    InsightSlice(label: "Enrolled", count: st.enrolled, color: .green, link: DashboardLinks.report("management", ["enrolled": "1"])),
                    InsightSlice(label: "Not Enrolled", count: st.total - st.enrolled, color: Color.secondary.opacity(0.35), link: DashboardLinks.report("management", ["enrolled": "0"])),
                ], center: "\(st.total == 0 ? 0 : Int((Double(st.enrolled) / Double(st.total) * 100).rounded()))%")
                if !st.top.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        InsightHeading("Providers")
                        ForEach(st.top) { p in
                            InsightBarRow(label: p.name, count: p.count, max: max, tone: .purple, link: DashboardLinks.report("management", ["provider": p.name]))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 4 Hardware

struct HardwareInsightWidget: View {
    let rows: [ReportRow]
    let loading: Bool
    let error: String?

    private struct Stats { let count: Int; let data: [InsightSlice]; let lowStorage: Int; let lowMemory: Int; let laptops: Int }
    private var stats: Stats {
        let pairs = rows.map { ($0, HardwareReportRow(json: $0.json)) }
        var families: [String: Int] = [:]
        for (row, hw) in pairs { families[HardwareClass.family(platform: row.platform, hw), default: 0] += 1 }
        let palette: [String: Color] = ["Apple Silicon": .blue, "Intel": .indigo, "ARM64": .teal, "x64": .cyan, "Unknown": Color.secondary.opacity(0.35)]
        let data = families.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map {
            InsightSlice(label: $0.key, count: $0.value, color: palette[$0.key] ?? .gray, link: $0.key == "Unknown" ? nil : DashboardLinks.report("hardware", ["arch": $0.key]))
        }
        return Stats(count: pairs.count, data: data,
                     lowStorage: pairs.filter { HardwareClass.isLowStorage($0.1) }.count,
                     lowMemory: pairs.filter { HardwareClass.isLowMemory($0.1) }.count,
                     laptops: pairs.filter { HardwareClass.type($0.1) == "laptop" }.count)
    }

    var body: some View {
        let st = stats
        InsightCard(title: "Hardware", subtitle: "Architecture, memory and storage", systemImage: "cpu", tone: .teal, link: DashboardLinks.report("hardware"), loading: loading, error: error, empty: rows.isEmpty) {
            VStack(alignment: .leading, spacing: 14) {
                InsightDonut(data: st.data, center: "\(st.count)")
                InsightChips {
                    StatChip(value: st.lowStorage, label: "under 10% free", tone: .red, link: DashboardLinks.report("hardware", ["storage": "low"]))
                    StatChip(value: st.lowMemory, label: "8 GB or less", tone: .yellow, link: DashboardLinks.report("hardware", ["memory": "le8"]))
                    StatChip(value: st.laptops, label: "laptops", tone: .blue, link: DashboardLinks.report("hardware", ["type": "laptop"]))
                }
            }
        }
    }
}
