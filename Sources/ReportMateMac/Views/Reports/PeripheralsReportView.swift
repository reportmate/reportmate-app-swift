import SwiftUI
import ReportMateKit

/// Fleet peripherals report. Port of `app/peripherals/page.tsx`.
struct PeripheralsReportView: View {
    @State private var model = FleetReportModel(path: "/peripherals")

    enum Column { case device, total, lastSeen }
    @State private var sortColumn: Column = .device
    @State private var ascending = true
    @State private var selectedKinds: Set<String> = []
    @State private var printerFilter: String? = nil
    @State private var usbTypeFilter: String? = nil

    private static let kindTones: [String: Tone] = ["usb": .blue, "bluetooth": .indigo, "printers": .purple, "cameras": .pink, "audio": .green, "displays": .cyan, "input": .yellow, "storage": .red]

    private func p(_ row: ReportRow) -> PeripheralsReportRow { PeripheralsReportRow(json: row.json) }

    private func base(_ rows: [ReportRow]) -> [(row: ReportRow, p: PeripheralsReportRow)] {
        rows.map { ($0, p($0)) }.filter { pair in
            selectedKinds.isEmpty || PeripheralsReportRow.kinds.contains { selectedKinds.contains($0.key) && pair.p.count($0) > 0 }
        }
    }

    private func table(_ pairs: [(row: ReportRow, p: PeripheralsReportRow)]) -> [(row: ReportRow, p: PeripheralsReportRow)] {
        pairs.filter { pair in
            if let printerFilter, !pair.p.printerNames.contains(printerFilter) { return false }
            if let usbTypeFilter, !pair.p.usbTypes.contains(usbTypeFilter) { return false }
            return true
        }.sorted { a, b in
            switch sortColumn {
            case .device: return ascending ? a.row.deviceName.lowercased() < b.row.deviceName.lowercased() : a.row.deviceName.lowercased() > b.row.deviceName.lowercased()
            case .total: return ascending ? a.p.total < b.p.total : a.p.total > b.p.total
            case .lastSeen: return ascending ? (a.row.lastSeen ?? .distantPast) < (b.row.lastSeen ?? .distantPast) : (a.row.lastSeen ?? .distantPast) > (b.row.lastSeen ?? .distantPast)
            }
        }
    }

    var body: some View {
        FleetReportContainer(
            section: .peripherals, model: model, activeFilterCount: selectedKinds.count + (printerFilter == nil ? 0 : 1) + (usbTypeFilter == nil ? 0 : 1), clearFilters: { selectedKinds = []; printerFilter = nil; usbTypeFilter = nil }, subtitle: "USB, Bluetooth, and other connected devices", searchPlaceholder: "Search peripherals...",
            searchKeys: { row in [row.deviceName, row.serialNumber, PeripheralsReportRow(json: row.json).searchableText] },
            toolbar: { _ in EmptyView() },
            widgets: { rows in widgets(base(rows).map(\.p)) }
        ) { rows in
            VStack(spacing: 0) {
                kindPills(rows)
                tableView(table(base(rows)))
            }
        }
    }

    /// Multi-select type pills; counts ignore the pills themselves so they never collapse to zero.
    private func kindPills(_ rows: [ReportRow]) -> some View {
        let pairs = rows.map { (platform: $0.platform, p: p($0)) }
        let fleetPlatforms = Set(rows.map(\.platform))
        return FlowLayout(spacing: 6) {
            ForEach(PeripheralsReportRow.kinds) { kind in
                let with = pairs.filter { $0.p.count(kind) > 0 }
                let count = with.count
                // A category that only one platform's client reports (Displays: the Mac
                // client leaves displayDevices empty) is labelled with its population, so
                // the count is not read as a fleet figure.
                let only = Set(with.map(\.platform))
                let single: Platform? = (count > 0 && only.count == 1 && fleetPlatforms.count > 1) ? only.first : nil
                FilterPill(text: single.map { "\(kind.label) (\(count), \($0.displayName) only)" } ?? "\(kind.label) (\(count))", selected: selectedKinds.contains(kind.key), tone: .blue, size: 12) {
                    if selectedKinds.contains(kind.key) { selectedKinds.remove(kind.key) } else { selectedKinds.insert(kind.key) }
                }
                .help(single.map { "Only \($0.displayName) devices report \(kind.label.lowercased()) in the peripherals module" } ?? "")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func widgets(_ all: [PeripheralsReportRow]) -> some View {
        let printers = countLabels(all.flatMap(\.printerNames))
        let usb = countLabels(all.flatMap(\.usbTypes))
        return HStack(alignment: .top, spacing: 12) {
            SingleCountListWidget(title: "Printers (\(printers.reduce(0) { $0 + $1.count }))", counts: printers.map { ($0.label, $0.count, Color.purple) }, selected: $printerFilter, emptyText: "No printers found").frame(width: 360)
            SingleCountListWidget(title: "USB Devices (\(usb.reduce(0) { $0 + $1.count }))", counts: usb.map { ($0.label, $0.count, Color.green) }, selected: $usbTypeFilter, emptyText: "No USB devices found").frame(width: 360)
        }
    }

    private func tableView(_ pairs: [(row: ReportRow, p: PeripheralsReportRow)]) -> some View {
        ReportTable {
            ReportSortHeader(title: "Device", column: .device, sortColumn: $sortColumn, ascending: $ascending, width: 240)
            ReportHeaderLabel(title: "Peripherals")
            ReportSortHeader(title: "Total", column: .total, sortColumn: $sortColumn, ascending: $ascending, width: 60)
            ReportSortHeader(title: "Last Seen", column: .lastSeen, sortColumn: $sortColumn, ascending: $ascending, width: 130)
        } rows: {
            if pairs.isEmpty { ReportEmptyRows(title: "No peripheral records found", message: "No peripheral records match your current search.", systemImage: "cable.connector") }
            ForEach(pairs, id: \.row.id) { pair in
                HStack(alignment: .top, spacing: 12) {
                    ReportDeviceCell(row: pair.row, tab: .peripherals).frame(width: 240, alignment: .leading)
                    FlowLayout(spacing: 4) {
                        ForEach(PeripheralsReportRow.kinds) { kind in
                            let n = pair.p.count(kind)
                            if n > 0 { Pill("\(n) \(kind.label)", tone: Self.kindTones[kind.key] ?? .gray) }
                        }
                        if pair.p.total == 0 { Text("No peripherals reported").appFont(.caption).foregroundStyle(.tertiary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(pair.p.total)").appFont(.callout, weight: .medium).monospacedDigit().frame(width: 60, alignment: .leading)
                    Text(pair.row.lastSeen.map { TimeFormatting.relative($0) } ?? "-").appFont(.callout).frame(width: 130, alignment: .leading)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
            }
        }
    }
}
