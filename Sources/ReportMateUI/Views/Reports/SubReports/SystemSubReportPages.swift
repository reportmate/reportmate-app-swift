import SwiftUI
import ReportMateKit

/// A sub-report's filters, kept in `PageModels` and taken from a link.
@MainActor
struct SubReportState {
    let appState: AppState
    let key: String

    var params: ReportParams {
        get { appState.pages.subReportParams[key] ?? ReportParams() }
        nonmutating set { appState.pages.subReportParams[key] = newValue }
    }

    var binding: Binding<ReportParams> { Binding(get: { params }, set: { params = $0 }) }

    func search() -> Binding<String> {
        Binding(get: { params["search"] ?? "" }, set: { params["search"] = $0 })
    }

    func sort(_ key: String = "sort", default fallback: String) -> Binding<String> {
        Binding(get: { params[key] ?? fallback }, set: { params[key] = $0 })
    }

    func ascending(_ key: String = "direction", default fallback: Bool = true) -> Binding<Bool> {
        Binding(get: { params[key].map { $0 != "desc" } ?? fallback }, set: { params[key] = $0 ? "asc" : "desc" })
    }
}

extension View {
    /// Wires a sub-report to links, Copy Link and Refresh: a link to `section`/`tab` replaces
    /// its filters, its filters become the page's link, and Command-R reloads it.
    func subReportLinking(_ state: SubReportState, section: AppSection, tab: String, reload: @escaping (Bool) -> Void) -> some View {
        modifier(SubReportLinking(state: state, section: section, tab: tab, reload: reload))
    }
}

private struct SubReportLinking: ViewModifier {
    @Environment(AppState.self) private var appState
    let state: SubReportState
    let section: AppSection
    let tab: String
    let reload: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: appState.pendingDeepLink, initial: true) { _, _ in
                guard let link = appState.consumeDeepLink(for: section, tab: tab) else { return }
                state.params = ReportParams(link.query)
            }
            .onChange(of: state.params, initial: true) { _, p in appState.linkQuery = p.values }
            .onChange(of: appState.refreshRequested) { _, _ in reload(true) }
    }
}

private func countText(_ shown: Int, _ total: Int, _ noun: String) -> String {
    shown == total ? "\(shown.formatted()) \(noun)" : "\(shown.formatted()) of \(total.formatted()) \(noun)"
}

// MARK: - Services

/// System › Services: chosen services (and optionally application versions) across devices.
struct ServicesReportPage: View {
    @Environment(AppState.self) private var appState
    private var state: SubReportState { SubReportState(appState: appState, key: "system.services") }
    private var model: SubReportLoader<ServiceCatalog, ServicesReportData> { appState.pages.subReport("system.services") { SubReportLoader() } }
    @State private var expanded: Bool?
    @State private var showApplications = false

    var body: some View {
        let p = state.params
        let catalog = model.catalog
        let services = ServicesReportSpec.selectedServices(p, catalog: catalog)
        let apps = ServicesReportSpec.selectedApplications(p, catalog: catalog)
        let hasQuery = ServicesReportSpec.hasQuery(p)
        let hasApp = ServicesReportSpec.hasApplication(p)
        let columns = ServicesReportSpec.columns(hasApplication: hasApp)
        let view = ReportView(params: p, available: columns.map(\.key), defaults: ServicesReportSpec.defaultColumns)
        let visible = view.columns.compactMap { k in columns.first { $0.key == k } }
        let report = model.report
        let rows = report.map { ReportSorting.sort(ServicesReportSpec.filter($0.devices, params: p), by: columns.first { $0.key == view.sort }, ascending: view.ascending, tiebreak: \.device.serialNumber) } ?? []

        SubReportScaffold(
            section: .system, description: "Service coverage and installed versions across devices.",
            footnote: "Last collected local state; matching evidence can be stale. Device check-in is ReportMate activity. A running service does not prove vendor connectivity.",
            selectionCount: services.count + apps.count + p.list("versions").count + p.list("states").count + p.list("startups").count + ScopeSelections.count(p) + (p.has("evidence") ? 1 : 0) + (p.has("checkin") ? 1 : 0),
            selectionsExpanded: Binding(get: { expanded ?? !hasQuery }, set: { expanded = $0 }),
            chips: chips(p, services: services, apps: apps, catalog: catalog),
            loading: model.loading, progress: model.progress, error: model.error ?? model.catalogError,
            canExport: !rows.isEmpty,
            export: {
                guard let report else { return }
                SubReportExport.save(filename: "services-report", headers: ServicesReportSpec.csvHeaders,
                                     rows: ServicesReportSpec.csvRows(rows, generatedAt: report.generatedAt, reportURL: appState.currentReportURL, maximumCheckinHours: ServicesReportSpec.checkinMaximum(p)))
            },
            refresh: { load(force: true) },
            clearAll: { state.params = ReportParams() }
        ) {
            selections(p, catalog: catalog, services: services, apps: apps, hasApp: hasApp)
        } status: {
            if hasQuery {
                SubReportStatusBar(summary: model.loading ? "Updating report… \(model.progress)" : report.map { countText(rows.count, $0.total, "devices") } ?? "", search: state.search()) {
                    ChoiceGroup(label: "Service state", choices: ServicesReportSpec.states.map { s in ReportChoice(value: s, label: ServicesReportSpec.stateLabel(s), devices: report?.summary[s]) },
                                isOn: { p.list("states").contains($0) }, allLabel: "All states", allOn: !p.has("states"), onAll: { state.params["states"] = nil }) { state.params.toggle("states", $0) }
                    ColumnsMenu(columns: columns, visible: view.columns) { cols in state.params["columns"] = cols?.joined(separator: ",") }
                }
            }
        } content: {
            if !hasQuery {
                SubReportMessage(title: "Choose services from Selections to build your report.", message: "Pick the collected services you want to compare. Results update as you select.")
            } else if model.loading, report == nil {
                SubReportMessage(title: "Loading services report…", message: model.progress.isEmpty ? nil : "\(model.progress) devices", systemImage: "hourglass")
            } else if report != nil {
                if rows.isEmpty { SubReportMessage(title: "No devices match these filters.") } else {
                    SubReportTable(rows: rows, columns: visible, sort: state.sort(default: "deviceName"), ascending: state.ascending(), device: \.device, deviceTab: .system)
                }
            }
        }
        .task(id: loadKey) { load(force: false) }
        .subReportLinking(state, section: .system, tab: "services") { load(force: $0) }
    }

    private var loadKey: String {
        let p = state.params
        return [SubReportLoader<ServiceCatalog, ServicesReportData>.key(appState.api, ServicesReportSpec.optionsQuery(p, platform: appState.platformFilter)),
                SubReportLoader<ServiceCatalog, ServicesReportData>.key(appState.api, ServicesReportSpec.apiQuery(p, platform: appState.platformFilter))].map { $0 ?? "-" }.joined(separator: "|")
    }

    private func load(force: Bool) {
        let api = appState.api, p = state.params, platform = appState.platformFilter
        let options = ServicesReportSpec.optionsQuery(p, platform: platform)
        model.loadCatalog(key: SubReportLoader<ServiceCatalog, ServicesReportData>.key(api, options)!, force: force) { try await api.serviceCatalog(query: options) }
        let query = ServicesReportSpec.apiQuery(p, platform: platform)
        model.loadReport(key: SubReportLoader<ServiceCatalog, ServicesReportData>.key(api, query), force: force) { progress in
            try await api.servicesReport(query: query ?? [:], progress: progress)
        }
    }

    private func chips(_ p: ReportParams, services: [String], apps: [String], catalog: ServiceCatalog?) -> [ReportChip] {
        var c: [ReportChip] = []
        if let legacy = p["service"] { c.append(ReportChip(id: "legacyService", label: legacy) { state.params["service"] = nil }) } else {
            c += services.map { name in ReportChip(id: "service-\(name)", label: catalog?.services.first { $0.name == name }?.displayName ?? name) {
                state.params.setJSONList("serviceNames", services.filter { $0 != name })
            } }
        }
        if let legacy = p["application"] { c.append(ReportChip(id: "legacyApp", label: legacy) { state.params["application"] = nil; state.params["versions"] = nil }) } else {
            c += apps.map { name in ReportChip(id: "app-\(name)", label: name) { state.params.setJSONList("applicationNames", apps.filter { $0 != name }); state.params["versions"] = nil } }
        }
        c += p.list("versions").map { v in ReportChip(id: "version-\(v)", label: v) { state.params.toggle("versions", v) } }
        return c
    }

    @ViewBuilder
    private func selections(_ p: ReportParams, catalog: ServiceCatalog?, services: [String], apps: [String], hasApp: Bool) -> some View {
        HStack(alignment: .top, spacing: 20) {
            SelectionCloud(label: "Services", options: (catalog?.services ?? []).map { ReportChoice(value: $0.name, label: $0.displayName ?? $0.name, devices: $0.devices) },
                           selected: services, loading: model.catalogLoading && catalog == nil,
                           toggle: { v in choose("serviceNames", "service", services.contains(v) ? services.filter { $0 != v } : services + [v]) },
                           select: { choose("serviceNames", "service", $0) })
            if showApplications || hasApp {
                SelectionCloud(label: "Applications", options: (catalog?.applications ?? []).map { ReportChoice(value: $0.name, label: $0.name, devices: $0.devices) },
                               selected: apps, loading: model.catalogLoading && catalog == nil,
                               toggle: { v in choose("applicationNames", "application", apps.contains(v) ? apps.filter { $0 != v } : apps + [v]); state.params["versions"] = nil },
                               select: { choose("applicationNames", "application", $0); state.params["versions"] = nil })
            }
        }
        if !showApplications && !hasApp { Button("Add Application Versions") { showApplications = true }.buttonStyle(.link) }
        if hasApp {
            let versions = Array(Set((catalog?.applications ?? []).filter { apps.contains($0.name) }.flatMap(\.versions))).sorted { $0.localizedStandardCompare($1) == .orderedDescending }
            ChoiceGroup(label: "Versions", choices: versions.map { ReportChoice(value: $0, label: $0) }, isOn: { p.list("versions").contains($0) },
                        allLabel: "All versions", allOn: !p.has("versions"), onAll: { state.params["versions"] = nil }) { state.params.toggle("versions", $0) }
        }
        VStack(alignment: .leading, spacing: 12) {
            let startups = Array(Set((catalog?.services ?? []).filter { services.contains($0.name) }.flatMap(\.startups))).sorted()
            if !startups.isEmpty {
                ChoiceGroup(label: "Startup type", choices: startups.map { ReportChoice(value: $0, label: ServicesReportSpec.stateLabel($0)) }, isOn: { p.list("startups").contains($0) },
                            allLabel: "All", allOn: !p.has("startups"), onAll: { state.params["startups"] = nil }) { state.params.toggle("startups", $0) }
            }
            ChoiceGroup(label: "Matching evidence", choices: ServicesReportSpec.evidenceChoices.filter { hasApp || $0.0 != "applications" }.map { ReportChoice(value: $0.0, label: $0.1) },
                        isOn: { ServicesReportSpec.evidence(p) == $0 }) { v in state.params["evidence"] = v == "all" ? nil : v }
            ChoiceGroup(label: "Device check-in age", choices: ServicesReportSpec.checkinChoices.map { ReportChoice(value: $0.0, label: $0.1) },
                        isOn: { ServicesReportSpec.checkin(p) == $0 }) { v in state.params["checkin"] = v == "all" ? nil : v }
            let max = ServicesReportSpec.checkinMaximum(p)
            ChoiceGroup(label: "Maximum check-in age", choices: Array(Set([24, 168, 720, max])).sorted().map { ReportChoice(value: String($0), label: ReportLabels.hours($0)) },
                        isOn: { String(max) == $0 }) { v in state.params["checkinAgeHours"] = v == "168" ? nil : v }
        }
        ScopeSelections(params: state.binding, options: catalog?.options ?? .empty, freshnessLabel: "Service collection age", defaultMaxAge: 24)
    }

    private func choose(_ key: String, _ legacy: String, _ values: [String]) {
        state.params[legacy] = nil
        state.params.setJSONList(key, values)
    }
}

// MARK: - Updates

/// System › Updates: pending (and with a selection, installed) operating system updates.
struct UpdatesReportPage: View {
    @Environment(AppState.self) private var appState
    private var state: SubReportState { SubReportState(appState: appState, key: "system.updates") }
    private var model: SubReportLoader<UpdateCatalog, UpdatesReportData> { appState.pages.subReport("system.updates") { SubReportLoader() } }
    @State private var expanded = false

    var body: some View {
        let p = state.params
        let catalog = model.catalog
        let selectedUpdates = p.jsonList("updates", commaFallback: true)
        let selectedCves = p.jsonList("cves", commaFallback: true)
        let hasSelection = UpdatesReportSpec.hasSelection(p)
        let columns = UpdatesReportSpec.columns
        let view = ReportView(params: p, available: columns.map(\.key), defaults: UpdatesReportSpec.defaultColumns)
        let visible = view.columns.compactMap { k in columns.first { $0.key == k } }
        let report = model.report
        let search = p["search"] ?? ""
        let rows = report.map { ReportSorting.sort($0.rows.filter { $0.device.matches(search) }, by: columns.first { $0.key == view.sort }, ascending: view.ascending,
                                                     tiebreak: { "\($0.device.serialNumber) \($0.title ?? "")" }) } ?? []

        SubReportScaffold(
            section: .system, description: "Pending and installed operating system updates across devices.",
            footnote: "Last collected local state. Stale, missing or malformed collection is Unknown. Age is days since macOS first offered the update, or since the Windows update was released.",
            selectionCount: selectedUpdates.count + selectedCves.count + p.list("states").count + ScopeSelections.count(p) + ["securityOnly", "rebootRequired", "deferred", "minAgeDays"].filter { p.has($0) }.count,
            selectionsExpanded: $expanded,
            chips: selectedUpdates.map { k in ReportChip(id: "u-\(k)", label: catalog?.updates.first { $0.key == k }?.label ?? k) { state.params.setJSONList("updates", selectedUpdates.filter { $0 != k }) } }
                + selectedCves.map { c in ReportChip(id: "c-\(c)", label: c) { state.params.setJSONList("cves", selectedCves.filter { $0 != c }) } },
            loading: model.loading, progress: model.progress, error: model.error ?? model.catalogError,
            canExport: !rows.isEmpty,
            export: {
                guard let report else { return }
                SubReportExport.save(filename: "updates-report", headers: UpdatesReportSpec.csvHeaders, rows: UpdatesReportSpec.csvRows(rows, generatedAt: report.generatedAt, reportURL: appState.currentReportURL))
            },
            refresh: { load(force: true) },
            clearAll: { state.params = ReportParams() }
        ) {
            HStack(alignment: .top, spacing: 20) {
                SelectionCloud(label: "Updates", options: (catalog?.updates ?? []).map { u in
                    ReportChoice(value: u.key, label: u.label + (appState.platformFilter == .all ? (u.platform == "windows" ? " (Windows)" : " (macOS)") : ""), devices: u.pendingDevices + u.installedDevices)
                }, selected: selectedUpdates, loading: model.catalogLoading && catalog == nil,
                   toggle: { v in state.params.setJSONList("updates", selectedUpdates.contains(v) ? selectedUpdates.filter { $0 != v } : selectedUpdates + [v]) },
                   select: { state.params.setJSONList("updates", $0) })
                SelectionCloud(label: "CVEs", options: catalog?.cves ?? [], selected: selectedCves, loading: model.catalogLoading && catalog == nil,
                               toggle: { v in state.params.setJSONList("cves", selectedCves.contains(v) ? selectedCves.filter { $0 != v } : selectedCves + [v]) },
                               select: { state.params.setJSONList("cves", $0) })
            }
            Text("Counts are devices reporting the update pending or installed. CVEs come from pending Windows updates; macOS does not report CVEs.").appFont(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                ChoiceGroup(label: "Update type", choices: [ReportChoice(value: "securityOnly", label: "Security only"), ReportChoice(value: "rebootRequired", label: "Restart required")],
                            isOn: { p[$0] == "true" }) { state.params.toggleFlag($0) }
                ChoiceGroup(label: "Deferred (macOS)", choices: [("all", "All"), ("yes", "Deferred"), ("no", "Not deferred")].map { ReportChoice(value: $0.0, label: $0.1) },
                            isOn: { (p["deferred"] ?? "all") == $0 }) { v in state.params["deferred"] = v == "all" ? nil : v }
                let minAge = p["minAgeDays"] ?? "0"
                ChoiceGroup(label: "Pending at least", choices: Array(Set(["0", "7", "30", "90", minAge])).sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }.map { ReportChoice(value: $0, label: $0 == "0" ? "Any age" : "\($0) days") },
                            isOn: { minAge == $0 }) { v in state.params["minAgeDays"] = v == "0" ? nil : v }
            }
            ScopeSelections(params: state.binding, options: catalog?.options ?? .empty, freshnessLabel: "Update collection age", defaultMaxAge: 24, showScope: false)
        } status: {
            VStack(spacing: 0) {
                SubReportStatusBar(summary: model.loading ? "Updating report… \(model.progress)" : report.map { _ in "\(rows.count.formatted()) rows across \(Set(rows.map(\.device.serialNumber)).count.formatted()) devices" } ?? "", search: state.search()) {
                    ChoiceGroup(label: "State", choices: UpdatesReportSpec.stateChoices(p).map { s in ReportChoice(value: s, label: UpdatesReportSpec.stateLabel(s), devices: report.map { $0.summary[s] ?? 0 }) },
                                isOn: { p.list("states").contains($0) }, allLabel: "All states", allOn: !p.has("states"), onAll: { state.params["states"] = nil }) { state.params.toggle("states", $0) }
                    ColumnsMenu(columns: columns, visible: view.columns) { cols in state.params["columns"] = cols?.joined(separator: ",") }
                }
                Text(hasSelection
                     ? "Each device in scope shows the selected updates as pending or installed. Not reported means the update is in neither the pending list nor the recent install history, which is not proof it is missing."
                     : "One row per device and pending update. Devices with an empty pending list show once as None pending reported; clients send an empty list both when nothing is pending and when the update search failed.")
                    .appFont(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .overlay(alignment: .bottom) { Divider() }
            }
        } content: {
            if model.loading, report == nil {
                SubReportMessage(title: "Loading updates report…", message: model.progress.isEmpty ? nil : "\(model.progress) rows", systemImage: "hourglass")
            } else if report != nil {
                if rows.isEmpty { SubReportMessage(title: "No rows match these filters.") } else {
                    SubReportTable(rows: rows, columns: visible, sort: state.sort(default: "deviceName"), ascending: state.ascending(), device: \.device, deviceTab: .system)
                }
            }
        }
        .task(id: loadKey) { load(force: false) }
        .subReportLinking(state, section: .system, tab: "updates") { load(force: $0) }
    }

    private var loadKey: String {
        let p = state.params, f = appState.platformFilter
        return "\(SubReportLoader<UpdateCatalog, UpdatesReportData>.key(appState.api, UpdatesReportSpec.optionsQuery(p, platform: f)) ?? "")|\(SubReportLoader<UpdateCatalog, UpdatesReportData>.key(appState.api, UpdatesReportSpec.apiQuery(p, platform: f)) ?? "")"
    }

    private func load(force: Bool) {
        let api = appState.api, p = state.params, f = appState.platformFilter
        let options = UpdatesReportSpec.optionsQuery(p, platform: f), query = UpdatesReportSpec.apiQuery(p, platform: f)
        model.loadCatalog(key: SubReportLoader<UpdateCatalog, UpdatesReportData>.key(api, options)!, force: force) { try await api.updateCatalog(query: options) }
        model.loadReport(key: SubReportLoader<UpdateCatalog, UpdatesReportData>.key(api, query), force: force) { progress in try await api.updatesReport(query: query, progress: progress) }
    }
}

// MARK: - Background items and extensions

/// System › Background and Extensions: one row per device and reported item.
struct ItemReportPage: View {
    @Environment(AppState.self) private var appState
    let spec: ItemReportSpec
    private var key: String { "system.\(spec.tab)" }
    private var state: SubReportState { SubReportState(appState: appState, key: key) }
    private var model: SubReportLoader<ItemCatalog, ItemReportData> { appState.pages.subReport(key) { SubReportLoader() } }
    @State private var expanded: Bool?

    var body: some View {
        let p = state.params
        let notApplicable = spec.macOnly && appState.platformFilter == .windows
        let catalog = model.catalog
        let selected = spec.selectedItems(p)
        let kinds = p.list("kinds")
        let hasQuery = spec.hasQuery(p) && !notApplicable
        let view = ReportView(params: p, available: spec.columns.map(\.key), defaults: spec.defaultColumns)
        let visible = view.columns.compactMap { k in spec.columns.first { $0.key == k } }
        let report = model.report
        let rows = report.map { ReportSorting.sort(spec.filter($0.rows, params: p), by: spec.columns.first { $0.key == view.sort }, ascending: view.ascending,
                                                     tiebreak: { "\($0.device.serialNumber) \($0.name ?? "")" }) } ?? []
        let activeCount = selected.count + kinds.count + spec.filters.reduce(0) { $0 + p.list($1.param).count } + ScopeSelections.count(p)

        SubReportScaffold(
            section: .system, description: spec.description, footnote: spec.footnote,
            selectionCount: activeCount,
            selectionsExpanded: Binding(get: { expanded ?? !hasQuery }, set: { expanded = $0 }),
            chips: selected.map { v in ReportChip(id: v, label: "\(spec.kindLabel(String(v.prefix { $0 != ":" }))): \(v.drop { $0 != ":" }.dropFirst())") {
                state.params.setJSONList("items", selected.filter { $0 != v })
            } },
            loading: model.loading, progress: model.progress, error: notApplicable ? nil : (model.error ?? model.catalogError),
            canExport: !rows.isEmpty && !notApplicable,
            exportHelp: "CSV includes every column, including hidden ones, for the filtered and sorted rows.",
            export: {
                guard let report else { return }
                SubReportExport.save(filename: spec.csvName, headers: spec.csvHeaders, rows: spec.csvRows(rows, generatedAt: report.generatedAt, reportURL: appState.currentReportURL))
            },
            refresh: { load(force: true) },
            clearAll: { state.params = ReportParams() }
        ) {
            if notApplicable {
                Text("This report covers Macs only. Choose All or macOS in the platform filter.").appFont(.callout).foregroundStyle(.secondary)
            } else {
                ChoiceGroup(label: "Kind", choices: spec.kinds, isOn: { kinds.contains($0) }, allLabel: "All kinds", allOn: kinds.isEmpty, onAll: { state.params["kinds"] = nil }) { state.params.toggle("kinds", $0) }
                SelectionCloud(label: "Items", options: (catalog?.items ?? []).filter { kinds.isEmpty || kinds.contains($0.kind) }.map { ReportChoice(value: $0.value, label: $0.key, devices: $0.devices) },
                               selected: selected, loading: model.catalogLoading && catalog == nil,
                               toggle: { v in state.params.setJSONList("items", selected.contains(v) ? selected.filter { $0 != v } : selected + [v]) },
                               select: { state.params.setJSONList("items", $0) })
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(spec.filters, id: \.param) { f in
                        let choices = f.fromTeamCatalog ? (catalog?.team ?? []) : f.choices.map { c in
                            ReportChoice(value: c.value, label: c.label, devices: f.summaryKey.flatMap { k in report?.summary["\(k):\(c.value)"] ?? (report == nil ? nil : 0) })
                        }
                        ChoiceGroup(label: f.label, choices: choices, isOn: { p.list(f.param).contains($0) }, allLabel: "All", allOn: !p.has(f.param), onAll: { state.params[f.param] = nil }) { state.params.toggle(f.param, $0) }
                    }
                }
                ScopeSelections(params: state.binding, options: catalog?.options ?? .empty, freshnessLabel: "System collection age", defaultMaxAge: 24)
            }
        } status: {
            if hasQuery {
                SubReportStatusBar(summary: model.loading ? "Updating report… \(model.progress)" : report.map { r in
                    var s = countText(rows.count, r.total, "rows")
                    if let reporting = r.devicesReporting, let scope = r.devicesInScope { s += " · \(reporting.formatted()) of \(scope.formatted()) devices report this inventory" }
                    return s
                } ?? "", search: state.search()) {
                    ColumnsMenu(columns: spec.columns, visible: view.columns) { cols in state.params["columns"] = cols?.joined(separator: ",") }
                }
            }
        } content: {
            if notApplicable {
                SubReportMessage(title: "Not applicable to Windows.", message: spec.footnote, systemImage: "applelogo")
            } else if !hasQuery {
                SubReportMessage(title: spec.prompt)
            } else if model.loading, report == nil {
                SubReportMessage(title: "Loading report…", message: model.progress.isEmpty ? nil : "\(model.progress) rows", systemImage: "hourglass")
            } else if let report {
                if report.applicable == false {
                    SubReportMessage(title: "Not applicable to the devices in scope.", message: spec.footnote, systemImage: "applelogo")
                } else if rows.isEmpty {
                    SubReportMessage(title: "No reported items match these filters.", message: "A device that does not list an item is not proof the item is absent.")
                } else {
                    SubReportTable(rows: rows, columns: visible, sort: state.sort(default: "deviceName"), ascending: state.ascending(), device: \.device, deviceTab: .system)
                }
            }
        }
        .task(id: loadKey) { load(force: false) }
        .subReportLinking(state, section: .system, tab: spec.tab) { load(force: $0) }
    }

    private var loadKey: String {
        let p = state.params, f = appState.platformFilter
        return "\(SubReportLoader<ItemCatalog, ItemReportData>.key(appState.api, spec.optionsQuery(p, platform: f)) ?? "")|\(SubReportLoader<ItemCatalog, ItemReportData>.key(appState.api, spec.apiQuery(p, platform: f)) ?? "-")"
    }

    private func load(force: Bool) {
        let api = appState.api, p = state.params, f = appState.platformFilter, spec = spec
        guard !(spec.macOnly && f == .windows) else { model.loadReport(key: nil) { _ in throw CancellationError() }; return }
        let options = spec.optionsQuery(p, platform: f), query = spec.apiQuery(p, platform: f)
        model.loadCatalog(key: SubReportLoader<ItemCatalog, ItemReportData>.key(api, options)!, force: force) { try await api.itemCatalog(spec, query: options) }
        model.loadReport(key: SubReportLoader<ItemCatalog, ItemReportData>.key(api, query), force: force) { progress in try await api.itemReport(spec, query: query ?? [:], progress: progress) }
    }
}
