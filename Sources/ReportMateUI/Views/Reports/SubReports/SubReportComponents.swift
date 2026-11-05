import SwiftUI
import AppKit
import ReportMateKit

// The parts every module sub-report shares: the loader, the page scaffold
// (header, Selections, chips, status bar, table, footnote), the selection
// controls and the native table. Each report keeps its state in web-style
// query parameters (`ReportParams`), so Copy Link and a pasted link carry it.

/// Loads a report's selections (`/filters`) and its rows, each keyed by its query,
/// so a change of filters cancels the request in flight and starts the right one.
@MainActor
@Observable
final class SubReportLoader<Catalog: Sendable, Report: Sendable> {
    private(set) var catalog: Catalog?
    private(set) var catalogLoading = false
    private(set) var catalogError: String?
    private(set) var report: Report?
    private(set) var loading = false
    private(set) var error: String?
    private(set) var progress = ""
    private(set) var loadedAt: Date?

    @ObservationIgnored private var catalogKey: String?
    @ObservationIgnored private var reportKey: String?
    @ObservationIgnored private var catalogTask: Task<Void, Never>?
    @ObservationIgnored private var reportTask: Task<Void, Never>?

    static func key(_ api: ReportMateAPI, _ query: [String: String]?) -> String? {
        guard let query else { return nil }
        return api.configuration.normalizedBaseURL + "?" + query.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
    }

    func loadCatalog(key: String, force: Bool = false, fetch: @escaping @Sendable () async throws -> Catalog) {
        if !force, key == catalogKey, catalog != nil || catalogLoading { return }
        catalogTask?.cancel()
        catalogKey = key
        catalogLoading = true
        catalogError = nil
        catalogTask = Task {
            do {
                let value = try await fetch()
                guard !Task.isCancelled else { return }
                catalog = value
            } catch {
                guard !Task.isCancelled else { return }
                catalogError = error.localizedDescription
            }
            catalogLoading = false
        }
    }

    /// `key` nil means the report needs a selection first: nothing loads and no rows show.
    func loadReport(key: String?, force: Bool = false, fetch: @escaping @Sendable (@escaping ReportMateAPI.ReportProgress) async throws -> Report) {
        if !force, key == reportKey, report != nil || loading { return }
        reportTask?.cancel()
        // Rows from other filters would misreport these ones; a refresh keeps them until the new rows land.
        if key != reportKey { report = nil }
        reportKey = key
        error = nil
        progress = ""
        guard key != nil else { loading = false; return }
        loading = true
        let onProgress: ReportMateAPI.ReportProgress = { [weak self] loaded, total in
            Task { @MainActor in self?.progress = "\(loaded.formatted()) of \(total.formatted())" }
        }
        reportTask = Task {
            do {
                let value = try await fetch(onProgress)
                guard !Task.isCancelled else { return }
                report = value
                loadedAt = Date()
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}

/// A removable filter shown above the table.
struct ReportChip: Identifiable {
    let id: String
    let label: String
    let clear: () -> Void
}

/// Holds the latest export action, so File › Export CSV always exports the rows on screen.
@MainActor
final class ExportHandler {
    var action: () -> Void = {}
}

/// Header, Selections, chips, status bar, content and footnote for a sub-report.
struct SubReportScaffold<Selections: View, Status: View, Content: View>: View {
    @Environment(AppState.self) private var appState
    let section: AppSection
    let description: String
    let footnote: String
    var selectionCount = 0
    @Binding var selectionsExpanded: Bool
    var chips: [ReportChip] = []
    var loading = false
    var progress = ""
    var error: String?
    var canExport = false
    var exportHelp = "CSV of every field for the filtered, sorted rows, including hidden columns."
    var export: () -> Void = {}
    var refresh: () -> Void
    var clearAll: () -> Void
    @ViewBuilder var selections: Selections
    @ViewBuilder var status: Status
    @ViewBuilder var content: Content

    @State private var handler = ExportHandler()
    @State private var copied = false
    @State private var selectionsHeight: CGFloat = 200

    var body: some View {
        let _ = handler.action = export
        VStack(spacing: 0) {
            header
            if loading { LoadProgressBar(updating: true) }
            selectionsPanel
            if !chips.isEmpty { chipsBar }
            if let error {
                ErrorBanner(message: error, retry: refresh).padding(.horizontal, 16).padding(.vertical, 8)
            }
            status
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Text(footnote)
                .appFont(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color.subtleBackground)
                .overlay(alignment: .top) { Divider() }
        }
        .navigationTitle(ReportTabs.title(section, appState.pages.tab(section)))
        .onChange(of: canExport, initial: true) { _, can in
            let handler = handler
            appState.reportExport = can ? { handler.action() } : nil
        }
        .onDisappear { appState.reportExport = nil }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                ReportTabSwitch(section: section)
                Text(description).appFont(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button {
                appState.copyCurrentLink()
                copied = true
                Task { try? await Task.sleep(for: .seconds(2)); copied = false }
            } label: { Label(copied ? "Link Copied" : "Copy Link", systemImage: copied ? "checkmark" : "link") }
                .help("Copy a link to this exact report (Shift-Command-C)")
            Button(action: refresh) { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(loading)
                .help("Load the report again (Command-R)")
            Button(action: export) { Label("Export CSV…", systemImage: "square.and.arrow.down") }
                .disabled(!canExport)
                .help(exportHelp + " (Shift-Command-E)")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var selectionsPanel: some View {
        VStack(spacing: 0) {
            AccordionHeader(title: "Selections", detail: selectionCount > 0 ? "\(selectionCount) active" : nil, expanded: $selectionsExpanded) {
                if selectionCount > 0 { Button("Clear All", action: clearAll).buttonStyle(.link) }
            }
            if selectionsExpanded {
                // As tall as the selections, up to a third of a typical window; past that they scroll.
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) { selections }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.bottom, 12)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { selectionsHeight = $0 }
                }
                .frame(height: min(max(selectionsHeight, 60), 380))
            }
        }
        .overlay(alignment: .bottom) { Divider() }
    }

    private var chipsBar: some View {
        HStack(alignment: .top, spacing: 8) {
            FlowLayout(spacing: 6) {
                ForEach(chips) { chip in
                    Button(action: chip.clear) {
                        HStack(spacing: 4) {
                            Text(chip.label).appFont(.caption, weight: .medium).lineLimit(1)
                            Image(systemName: "xmark").appFont(.caption2)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Remove \(chip.label)")
                    .accessibilityLabel("Remove \(chip.label)")
                }
            }
            Button("Clear Selections", action: clearAll).buttonStyle(.link).appFont(.caption)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// The row of controls between the selections and the table: counts, search, quick filters.
struct SubReportStatusBar<Trailing: View>: View {
    let summary: String
    @Binding var search: String
    var searchPrompt = "Search devices"
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(summary).appFont(.callout).foregroundStyle(.secondary).monospacedDigit()
            TextField(searchPrompt, text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
            trailing
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// A centered message in place of the table: the prompt to choose, loading, or nothing matched.
struct SubReportMessage: View {
    let title: String
    var message: String? = nil
    var systemImage = "line.3.horizontal.decrease.circle"
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 28)).foregroundStyle(.tertiary)
            Text(title).appFont(.callout, weight: .medium).multilineTextAlignment(.center)
            if let message { Text(message).appFont(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Selection controls

/// A labelled group of choice pills. `allLabel` adds an "All" pill that clears the group.
struct ChoiceGroup: View {
    let label: String
    let choices: [ReportChoice]
    let isOn: (String) -> Bool
    var allLabel: String? = nil
    var allOn = false
    var onAll: () -> Void = {}
    let toggle: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased()).appFont(.caption2, weight: .medium).foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                if let allLabel { FilterPill(text: allLabel, selected: allOn, action: onAll) }
                ForEach(choices) { c in
                    FilterPill(text: c.devices.map { "\(c.label)  \($0.formatted())" } ?? c.label, selected: isOn(c.value)) { toggle(c.value) }
                        .help(c.value)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// Inventory-backed choice list: search the values actually collected, pick several.
struct SelectionCloud: View {
    let label: String
    let options: [ReportChoice]
    let selected: [String]
    var loading = false
    var limit = 150
    let toggle: (String) -> Void
    let select: ([String]) -> Void

    @State private var search = ""

    var body: some View {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let visible = q.isEmpty ? options : options.filter { "\($0.label) \($0.value)".lowercased().contains(q) }
        let shown = Array(visible.prefix(limit))
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(selected.isEmpty ? label : "\(label) (\(selected.count) selected)").appFont(.callout, weight: .medium)
                Spacer()
                if !q.isEmpty, !visible.isEmpty {
                    Button("Select \(visible.count.formatted()) Results") { select(Array(Set(selected + visible.map(\.value))).sorted()) }
                        .disabled(visible.count > 200)
                        .help(visible.count > 200 ? "Narrow the search to 200 choices or fewer to select them all" : "Add every matching choice")
                }
                if !selected.isEmpty { Button("Clear") { select([]) } }
            }
            TextField("Search \(label.lowercased())", text: $search).textFieldStyle(.roundedBorder)
            if !loading, visible.count > shown.count {
                Text("Showing \(shown.count) of \(visible.count.formatted()) choices. Search to narrow the list.").appFont(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                if loading {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Loading available \(label.lowercased())…").appFont(.caption).foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                } else if visible.isEmpty {
                    Text(q.isEmpty ? "No choices reported in this scope." : "No matching choices.").appFont(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                } else {
                    FlowLayout(spacing: 5) {
                        ForEach(shown) { o in
                            FilterPill(text: o.devices.map { "\(o.label)  \($0.formatted())" } ?? o.label, selected: selected.contains(o.value)) { toggle(o.value) }
                                .help(o.value)
                        }
                    }
                    .padding(6)
                }
            }
            .frame(minHeight: 60, maxHeight: 170)
            .background(Color.subtleBackground, in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(minWidth: 300, maxWidth: .infinity, alignment: .leading)
    }
}

/// The inventory scope, collection age and archive selections every sub-report offers.
struct ScopeSelections: View {
    @Binding var params: ReportParams
    let options: ReportScopeOptions
    /// "Service collection age", "Update collection age", …; nil hides the freshness controls.
    var freshnessLabel: String? = nil
    var defaultMaxAge = 24
    var showScope = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showScope {
                ForEach(["usages", "catalogs", "areas", "fleets", "locations", "rooms"], id: \.self) { key in
                    if !options[key].isEmpty {
                        ChoiceGroup(label: ReportScope.labels[key] ?? key, choices: options[key].map { ReportChoice(value: $0, label: $0) },
                                    isOn: { params.list(key).contains($0) }) { params.toggle(key, $0) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                if let freshnessLabel {
                    ChoiceGroup(label: freshnessLabel, choices: [ReportChoice(value: "fresh", label: "Within maximum age"), ReportChoice(value: "stale", label: "Older"), ReportChoice(value: "unknown", label: "Unknown")],
                                isOn: { params["freshness"] == $0 }, allLabel: "All", allOn: params["freshness"] == nil, onAll: { params["freshness"] = nil }) { v in
                        params["freshness"] = params["freshness"] == v ? nil : v
                    }
                    let age = params["maxAgeHours"] ?? String(defaultMaxAge)
                    let ages = Array(Set(["24", "168", "720", age])).sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
                    ChoiceGroup(label: "Maximum collection age", choices: ages.map { ReportChoice(value: $0, label: ReportLabels.hours(Int($0) ?? 0)) },
                                isOn: { age == $0 }) { v in params["maxAgeHours"] = v == String(defaultMaxAge) ? nil : v }
                }
                ChoiceGroup(label: "Inventory state", choices: options["inventoryStates"].map { ReportChoice(value: $0, label: ReportLabels.inventory($0)) },
                            isOn: { params.list("inventoryStates").contains($0) }, allLabel: "All", allOn: !params.has("inventoryStates"),
                            onAll: { params["inventoryStates"] = nil }) { params.toggle("inventoryStates", $0) }
                ChoiceGroup(label: "Archive", choices: [ReportChoice(value: "true", label: "Include archived")], isOn: { params["includeArchived"] == $0 }) { _ in
                    params.toggleFlag("includeArchived")
                }
            }
        }
    }

    /// How many scope, age and archive selections are active.
    static func count(_ p: ReportParams) -> Int {
        ReportScope.keys.reduce(0) { $0 + p.list($1).count } + (p.has("freshness") ? 1 : 0) + (p.has("maxAgeHours") ? 1 : 0) + (p.has("includeArchived") ? 1 : 0)
    }

    static let keys = ReportScope.keys + ["freshness", "maxAgeHours", "includeArchived"]
}

/// The Columns menu: show or hide each column; the device column always shows.
struct ColumnsMenu<Row>: View {
    let columns: [ReportColumn<Row>]
    let visible: [String]
    var alwaysShown = "deviceName"
    let set: ([String]?) -> Void

    var body: some View {
        Menu {
            ForEach(columns.filter { $0.key != alwaysShown }) { c in
                Toggle(c.label, isOn: Binding(get: { visible.contains(c.key) }, set: { on in
                    let next = columns.map(\.key).filter { $0 == c.key ? on : visible.contains($0) }
                    set(next)
                }))
            }
            Divider()
            Button("Reset Columns") { set(nil) }
        } label: { Label("Columns", systemImage: "tablecells") }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Show or hide columns. Export CSV always includes every column.")
    }
}

// MARK: - CSV

enum SubReportExport {
    /// Ask where to save, then write the CSV.
    @MainActor
    static func save(filename: String, headers: [String], rows: [[String?]]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(filename)-\(CSVText.dateStamp()).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        let text = SubReportCSV.text(headers: headers, rows: rows)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}

// MARK: - Table

/// The table's sort comparator: the column key and direction. Rows are sorted by
/// `ReportSorting` (unknown values last), so the comparator itself never orders rows.
struct ColumnSortKey<Row>: SortComparator, Hashable {
    let key: String
    var order: SortOrder = .forward
    func compare(_ lhs: Row, _ rhs: Row) -> ComparisonResult { .orderedSame }
    static func == (a: Self, b: Self) -> Bool { a.key == b.key && a.order == b.order }
    func hash(into hasher: inout Hasher) { hasher.combine(key); hasher.combine(order == .forward) }
}

/// A sortable table of report rows. Double-click or Return opens the device; the
/// context menu opens it, copies serial numbers or rows, or opens a reference link.
struct SubReportTable<Row: Identifiable>: View {
    @Environment(AppState.self) private var appState
    let rows: [Row]
    let columns: [ReportColumn<Row>]
    @Binding var sort: String
    @Binding var ascending: Bool
    var device: (Row) -> ReportDevice? = { _ in nil }
    var deviceTab: DeviceTab? = nil
    var link: ((Row) -> URL?)? = nil
    /// Overrides opening the device on double-click (the CVE summary drills in instead).
    var activate: ((Row) -> Void)? = nil
    var activateLabel = "Open Device"

    var body: some View {
        if #available(macOS 14.4, *) {
            NativeReportTable(rows: rows, columns: columns, sort: $sort, ascending: $ascending, device: device, deviceTab: deviceTab, link: link, activate: activate, activateLabel: activateLabel)
        } else {
            LegacyReportTable(rows: rows, columns: columns, sort: $sort, ascending: $ascending, device: device, deviceTab: deviceTab)
        }
    }
}

@MainActor
private func tsv<Row>(_ rows: [Row], _ columns: [ReportColumn<Row>]) -> String {
    ([columns.map(\.label)] + rows.map { r in columns.map { $0.text(r).replacingOccurrences(of: "\n", with: "; ") } })
        .map { $0.joined(separator: "\t") }.joined(separator: "\n")
}

@available(macOS 14.4, *)
private struct NativeReportTable<Row: Identifiable>: View {
    @Environment(AppState.self) private var appState
    let rows: [Row]
    let columns: [ReportColumn<Row>]
    @Binding var sort: String
    @Binding var ascending: Bool
    let device: (Row) -> ReportDevice?
    let deviceTab: DeviceTab?
    let link: ((Row) -> URL?)?
    let activate: ((Row) -> Void)?
    let activateLabel: String

    @State private var selection = Set<Row.ID>()

    private var sortOrder: Binding<[ColumnSortKey<Row>]> {
        Binding(get: { [ColumnSortKey(key: sort, order: ascending ? .forward : .reverse)] },
                set: { new in if let first = new.first { sort = first.key; ascending = first.order == .forward } })
    }

    private func selected(_ ids: Set<Row.ID>) -> [Row] { rows.filter { ids.contains($0.id) } }

    private func open(_ row: Row) {
        if let activate { activate(row); return }
        guard let d = device(row), !d.serialNumber.isEmpty else { return }
        appState.open(device: d.serialNumber, tab: deviceTab)
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: sortOrder) {
            TableColumnForEach(columns) { column in
                TableColumn(column.label, sortUsing: ColumnSortKey<Row>(key: column.key)) { row in
                    ReportCell(row: row, column: column, device: device(row), open: { open(row) })
                }
                .width(min: column.kind == .device ? 160 : 70, ideal: Self.idealWidth(column))
            }
        }
        .contextMenu(forSelectionType: Row.ID.self) { ids in
            let picked = selected(ids)
            if picked.count == 1, let row = picked.first {
                if activate != nil || device(row) != nil { Button(activateLabel) { open(row) } }
                if let url = link?(row) { Button("Open Reference in Browser") { NSWorkspace.shared.open(url) } }
                Divider()
            }
            let serials = picked.compactMap { device($0)?.serialNumber }.filter { !$0.isEmpty }
            if !serials.isEmpty {
                Button(serials.count == 1 ? "Copy Serial Number" : "Copy \(serials.count) Serial Numbers") { copy(serials.joined(separator: "\n")) }
                Button(serials.count == 1 ? "Copy Device Name" : "Copy Device Names") { copy(picked.compactMap { device($0)?.displayName }.joined(separator: "\n")) }
            }
            if !picked.isEmpty {
                Button(picked.count == 1 ? "Copy Row" : "Copy \(picked.count) Rows") { copy(tsv(picked, columns)) }
            }
        } primaryAction: { ids in
            if let row = selected(ids).first { open(row) }
        }
        .onCopyCommand {
            let picked = selected(selection)
            guard !picked.isEmpty else { return [] }
            return [NSItemProvider(object: tsv(picked, columns) as NSString)]
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func idealWidth(_ c: ReportColumn<Row>) -> CGFloat {
        switch c.kind {
        case .device: return 220
        case .time: return 120
        case .number: return 90
        case .state: return 130
        case .mono: return 200
        case .text: return 170
        }
    }
}

/// macOS 14.0 to 14.3 have no `TableColumnForEach`; a plain sortable list stands in.
private struct LegacyReportTable<Row: Identifiable>: View {
    @Environment(AppState.self) private var appState
    let rows: [Row]
    let columns: [ReportColumn<Row>]
    @Binding var sort: String
    @Binding var ascending: Bool
    let device: (Row) -> ReportDevice?
    let deviceTab: DeviceTab?

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(rows) { row in
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(columns) { c in
                                ReportCell(row: row, column: c, device: device(row)) {
                                    if let d = device(row) { appState.open(device: d.serialNumber, tab: deviceTab) }
                                }
                                .frame(width: c.kind == .device ? 220 : 160, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 6)
                        Divider()
                    }
                } header: {
                    HStack(spacing: 12) {
                        ForEach(columns) { c in
                            Button {
                                if sort == c.key { ascending.toggle() } else { sort = c.key; ascending = true }
                            } label: {
                                HStack(spacing: 3) {
                                    Text(c.label).appFont(.caption, weight: .semibold)
                                    if sort == c.key { Image(systemName: ascending ? "chevron.up" : "chevron.down").appFont(.caption2) }
                                }
                            }
                            .buttonStyle(.plain)
                            .frame(width: c.kind == .device ? 220 : 160, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color.subtleBackground)
                }
            }
        }
    }
}

/// One cell: the value drawn by the column's kind, with its explanatory second line.
struct ReportCell<Row>: View {
    let row: Row
    let column: ReportColumn<Row>
    let device: ReportDevice?
    var open: () -> Void = {}

    var body: some View {
        let value = column.value(row)
        VStack(alignment: .leading, spacing: 2) {
            switch column.kind {
            case .device:
                Button(action: open) {
                    Text(value ?? column.missing).appFont(.body, weight: .medium).foregroundStyle(Color.accentColor).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .help("Open \(value ?? "the device")")
                if let device, !device.serialNumber.isEmpty, device.serialNumber != value {
                    Text(device.serialNumber).appFont(.caption, design: .monospaced).foregroundStyle(.secondary).textSelection(.enabled)
                }
            case .time:
                if let value, let date = FlexibleDate.parse(value) {
                    Text(TimeFormatting.relative(date)).help(TimeFormatting.exact(date))
                } else {
                    Text(value ?? column.missing).foregroundStyle(.secondary)
                }
            case .state:
                Pill(value ?? column.missing, tone: Self.tone(value ?? column.missing, key: column.key))
            case .mono:
                if let value { Text(value).appFont(.caption, design: .monospaced).textSelection(.enabled).lineLimit(3) } else { Text(column.missing).foregroundStyle(.secondary) }
            case .number:
                Text(value ?? column.missing).monospacedDigit().foregroundStyle(value == nil ? .secondary : .primary)
            case .text:
                if let value { Text(value).lineLimit(4).textSelection(.enabled) } else { Text(column.missing).foregroundStyle(.secondary) }
            }
            if let detail = column.detail?(row) {
                Text(detail).appFont(.caption).foregroundStyle(.secondary).lineLimit(4)
            }
        }
        .padding(.vertical, 2)
    }

    /// Red for a problem, green for a healthy state, blue for pending, amber for unknown or stale.
    static func tone(_ label: String, key: String) -> Tone {
        if key == "exploited" { return label == "Yes" ? .red : label == "No" ? .gray : .yellow }
        switch label {
        case "Failed", "Disabled", "Not activated", "Unsigned", "Not installed", "Not compliant", "Unpatched", "Stopped", "Not found", "Not reported": return .red
        case "Succeeded", "Enabled", "Activated", "Signed", "Within maximum age", "Running", "Installed", "Patched", "Compliant", "None pending reported": return .green
        case "Pending": return .blue
        case "Not applicable": return .gray
        default: return .yellow
        }
    }
}
