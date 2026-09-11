import SwiftUI
import Charts
import ReportMateKit

/// The dashboard's second tier: one card per module report, built from the
/// same bulk reports the report pages read. The dashboard payload itself
/// carries devices and events only, so these load after it, in parallel, and
/// show a placeholder until each report answers.
@MainActor
@Observable
final class DashboardInsightsModel {
    var security: [ReportRow] = []
    var management: [ReportRow] = []
    var hardware: [ReportRow] = []
    var system: [ReportRow] = []
    var loading: Set<String> = []
    var errors: [String: String] = [:]
    var loadedAt: Date?

    func load(api: ReportMateAPI, force: Bool = false) async {
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 300 { return }
        loading = ["security", "management", "hardware", "system"]
        // Two at a time: each bulk report takes the API ten seconds or more, and
        // four at once had the gateway answer 503 for the last one. A 5xx or a
        // dropped connection gets one retry after a short pause.
        await withTaskGroup(of: (String, Result<JSONValue, Error>).self) { group in
            let paths = ["/security", "/management", "/hardware", "/system"]
            var next = paths.makeIterator()
            func fetch(_ path: String) async -> (String, Result<JSONValue, Error>) {
                for attempt in 0..<2 {
                    do { return (path, .success(try await api.fleetReport(path))) }
                    catch {
                        let retry: Bool
                        switch error as? APIError {
                        case .http(let status, _, _): retry = status >= 500
                        case .transport: retry = true
                        default: retry = false
                        }
                        if !retry || attempt == 1 { return (path, .failure(error)) }
                        try? await Task.sleep(for: .seconds(3))
                    }
                }
                return (path, .failure(APIError.transport("gave up")))
            }
            for _ in 0..<2 { if let path = next.next() { group.addTask { await fetch(path) } } }
            while let (path, result) = await group.next() {
                if let more = next.next() { group.addTask { await fetch(more) } }
                let key = String(path.dropFirst())
                switch result {
                case .success(let json):
                    let rows = FleetReportModel.extractRows(json).map(ReportRow.init(json:))
                    errors[key] = nil
                    switch key {
                    case "security": security = rows
                    case "management": management = rows
                    case "hardware": hardware = rows
                    default: system = rows
                    }
                case .failure(let error): errors[key] = error.localizedDescription
                }
                loading.remove(key)
            }
        }
        loadedAt = Date()
    }
}

/// Card chrome shared by the insight widgets: header, then the body or a
/// placeholder while the report loads.
private struct InsightCard<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tone: Tone
    let section: AppSection
    let loading: Bool
    let error: String?
    let empty: Bool
    @ViewBuilder var content: Content
    @Environment(AppState.self) private var appState

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(title, subtitle: subtitle, systemImage: systemImage, tone: tone) { appState.section = section }
                Group {
                    if let error, empty {
                        Text(error).appFont(.caption).foregroundStyle(.secondary).padding(16)
                    } else if loading, empty {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading…").appFont(.caption).foregroundStyle(.secondary) }.padding(16)
                    } else if empty {
                        Text("No data").appFont(.caption).foregroundStyle(.tertiary).padding(16)
                    } else {
                        content.padding(16)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                Spacer(minLength: 0)
            }
        }
    }
}

/// "Label … bar … n of N" compliance row.
private struct ComplianceRow: View {
    let label: String
    let on: Int
    let total: Int

    var body: some View {
        let pct = total == 0 ? 0 : Double(on) / Double(total)
        let tone: Tone = pct >= 0.9 ? .green : pct >= 0.7 ? .yellow : .red
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

/// Ring plus legend, the dashboard's small donut.
private struct InsightDonut: View {
    let data: [(label: String, count: Int, color: Color)]
    var center: String? = nil

    var body: some View {
        let total = data.reduce(0) { $0 + $1.count }
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Chart(data, id: \.label) { item in
                    SectorMark(angle: .value("Count", item.count), innerRadius: .ratio(0.64), angularInset: 1)
                        .foregroundStyle(item.color)
                }
                .chartLegend(.hidden)
                .frame(width: 96, height: 96)
                if let center { Text(center).appFont(.callout, weight: .semibold).monospacedDigit() }
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(data, id: \.label) { item in
                    HStack(spacing: 6) {
                        Circle().fill(item.color).frame(width: 9, height: 9)
                        Text(item.label).appFont(.callout).lineLimit(1)
                        Spacer(minLength: 6)
                        Text("\(item.count)").appFont(.callout, weight: .medium).monospacedDigit()
                        Text(total == 0 ? "" : "\(Int((Double(item.count) / Double(total) * 100).rounded()))%").appFont(.caption).foregroundStyle(.tertiary).monospacedDigit().frame(width: 34, alignment: .trailing)
                    }
                }
            }
        }
    }
}

/// Small "n label" stat chip under a donut.
private struct StatChip: View {
    let value: Int
    let label: String
    let tone: Tone
    var body: some View {
        HStack(spacing: 6) {
            Text("\(value)").appFont(.callout, weight: .semibold).foregroundStyle(value == 0 ? Color.secondary : tone.color).monospacedDigit()
            Text(label).appFont(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.subtleBackground, in: Capsule())
        .overlay(Capsule().stroke(Color.cardBorder))
    }
}

// MARK: - Security posture

struct SecurityPostureWidget: View {
    let rows: [ReportRow]
    let loading: Bool
    let error: String?

    var body: some View {
        let s = rows.map { SecurityReportRow(json: $0.json, platform: $0.platform) }
        let macs = s.filter { !$0.isWindows }
        let wins = s.filter(\.isWindows)
        let protectors = s.filter(\.reportsProtection)
        InsightCard(title: "Security Posture", subtitle: "Fleet-wide protections in place", systemImage: "lock.shield", tone: .green, section: .security, loading: loading, error: error, empty: rows.isEmpty) {
            VStack(alignment: .leading, spacing: 12) {
                ComplianceRow(label: "Disk encryption", on: s.filter(\.encryptionEnabled).count, total: s.count)
                ComplianceRow(label: "Firewall", on: s.filter(\.firewallEnabled).count, total: s.count)
                if !protectors.isEmpty {
                    ComplianceRow(label: "Antivirus protection", on: protectors.filter(\.antivirusEnabled).count, total: protectors.count)
                }
                if !macs.isEmpty {
                    let sipRows = macs.filter { $0.sipEnabled != nil }
                    if !sipRows.isEmpty { ComplianceRow(label: "System Integrity Protection", on: sipRows.filter { $0.sipEnabled == true }.count, total: sipRows.count) }
                }
                if !wins.isEmpty {
                    ComplianceRow(label: "Secure Boot", on: wins.filter(\.secureBootEnabled).count, total: wins.count)
                }
                HStack(spacing: 8) {
                    StatChip(value: s.filter { $0.activeThreatCount > 0 }.count, label: "with threats", tone: .red)
                    StatChip(value: s.filter { $0.expiredCertCount > 0 }.count, label: "expired certs", tone: .yellow)
                    StatChip(value: s.filter { $0.criticalCveCount > 0 }.count, label: "critical CVEs", tone: .orange)
                }
                .padding(.top, 2)
            }
        }
    }
}

// MARK: - Management

struct ManagementInsightWidget: View {
    let rows: [ReportRow]
    let loading: Bool
    let error: String?

    private struct Stats { let total: Int; let enrolled: Int; let top: [(key: String, value: Int)] }
    private var stats: Stats {
        let m = rows.map { ManagementReportRow(json: $0.json) }
        var providers: [String: Int] = [:]
        for row in m where row.isEnrolled { providers[row.provider.isEmpty ? "Unknown" : row.provider, default: 0] += 1 }
        let top = providers.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(4).map { (key: $0.key, value: $0.value) }
        return Stats(total: m.count, enrolled: m.filter(\.isEnrolled).count, top: top)
    }

    var body: some View {
        let st = stats
        let enrolled = st.enrolled, top = st.top
        let max = top.first?.value ?? 1
        InsightCard(title: "Management", subtitle: "MDM enrollment across the fleet", systemImage: "checkmark.shield", tone: .purple, section: .management, loading: loading, error: error, empty: rows.isEmpty) {
            VStack(alignment: .leading, spacing: 14) {
                InsightDonut(data: [("Enrolled", enrolled, .green), ("Not Enrolled", st.total - enrolled, Color.secondary.opacity(0.35))], center: "\(st.total == 0 ? 0 : Int((Double(enrolled) / Double(st.total) * 100).rounded()))%")
                if !top.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PROVIDERS").appFont(.caption2, weight: .semibold).foregroundStyle(.secondary)
                        ForEach(Array(top), id: \.key) { name, count in
                            HStack(spacing: 8) {
                                Text(name).appFont(.callout).lineLimit(1)
                                Spacer()
                                Capsule().fill(Tone.purple.color.opacity(0.35)).frame(width: CGFloat(count) / CGFloat(max) * 70, height: 6)
                                Text("\(count)").appFont(.callout, weight: .medium).monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Hardware

struct HardwareInsightWidget: View {
    let rows: [ReportRow]
    let loading: Bool
    let error: String?

    private static func family(_ row: ReportRow, _ hw: HardwareReportRow) -> String {
        let arch = hw.architecture.lowercased()
        let proc = hw.processorName.lowercased()
        if row.platform == .windows {
            return arch.contains("arm") || proc.contains("snapdragon") || proc.contains("qualcomm") ? "ARM64" : "x64"
        }
        if arch.contains("arm") || hw.chipName != nil || proc.contains("apple") { return "Apple Silicon" }
        return arch.isEmpty && proc.isEmpty ? "Unknown" : "Intel"
    }

    private struct Stats { let count: Int; let data: [(label: String, count: Int, color: Color)]; let lowStorage: Int; let lowMemory: Int; let laptops: Int }
    private var stats: Stats {
        let pairs = rows.map { ($0, HardwareReportRow(json: $0.json)) }
        var families: [String: Int] = [:]
        for (row, hw) in pairs { families[Self.family(row, hw), default: 0] += 1 }
        let palette: [String: Color] = ["Apple Silicon": .blue, "Intel": .indigo, "ARM64": .teal, "x64": .cyan, "Unknown": Color.secondary.opacity(0.35)]
        let data = families.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { (label: $0.key, count: $0.value, color: palette[$0.key] ?? .gray) }
        return Stats(
            count: pairs.count, data: data,
            lowStorage: pairs.filter { $0.1.storageTotalBytes > 0 && $0.1.storageFreeBytes / $0.1.storageTotalBytes < 0.1 }.count,
            lowMemory: pairs.filter { $0.1.memoryBytes > 0 && $0.1.memoryBytes <= 8 * 1024 * 1024 * 1024 }.count,
            laptops: pairs.filter { $0.1.deviceType.lowercased().contains("laptop") || $0.1.deviceType.lowercased().contains("notebook") }.count)
    }

    var body: some View {
        let st = stats
        InsightCard(title: "Hardware", subtitle: "Architecture, memory and storage", systemImage: "cpu", tone: .teal, section: .hardware, loading: loading, error: error, empty: rows.isEmpty) {
            VStack(alignment: .leading, spacing: 14) {
                InsightDonut(data: st.data, center: "\(st.count)")
                HStack(spacing: 8) {
                    StatChip(value: st.lowStorage, label: "under 10% free", tone: .red)
                    StatChip(value: st.lowMemory, label: "8 GB or less", tone: .yellow)
                    StatChip(value: st.laptops, label: "laptops", tone: .blue)
                }
            }
        }
    }
}

// MARK: - System health

struct SystemInsightWidget: View {
    let rows: [ReportRow]
    let loading: Bool
    let error: String?

    private struct Stats { let buckets: [String: Int]; let pending: Int; let deferred: Int }
    private var stats: Stats {
        let s = rows.map { SystemReportRow(json: $0.json) }
        var buckets: [String: Int] = [:]
        for row in s { if let b = SystemReportView.uptimeBucket(row.uptime) { buckets[b, default: 0] += 1 } }
        return Stats(buckets: buckets, pending: s.filter { $0.pendingUpdatesCount > 0 }.count, deferred: s.filter { $0.deferredUpdatesCount > 0 }.count)
    }

    var body: some View {
        let st = stats
        let order = SystemReportView.uptimeBuckets.map(\.0.label)
        let buckets = st.buckets
        let max = buckets.values.max() ?? 1
        InsightCard(title: "System Health", subtitle: "Uptime and pending updates", systemImage: "gearshape.2", tone: .orange, section: .system, loading: loading, error: error, empty: rows.isEmpty) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("UPTIME").appFont(.caption2, weight: .semibold).foregroundStyle(.secondary)
                    ForEach(order, id: \.self) { label in
                        let count = buckets[label] ?? 0
                        HStack(spacing: 8) {
                            Text(label).appFont(.callout).frame(width: 96, alignment: .leading)
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
                HStack(spacing: 8) {
                    StatChip(value: st.pending, label: "with pending updates", tone: .yellow)
                    StatChip(value: st.deferred, label: "with deferred updates", tone: .orange)
                }
            }
        }
    }
}
