import SwiftUI
import ReportMateKit

// MARK: - Configuration profiles and managed preferences

/// Management › Configuration Profiles and Managed Preferences: one row per device and
/// selected identifier, installed, not installed (only against a fresh, nonempty
/// management inventory) or unknown.
struct ProfilesReportPage: View {
    @Environment(AppState.self) private var appState
    let kind: ProfileKind
    private var key: String { "management.\(kind.tab)" }
    private var state: SubReportState { SubReportState(appState: appState, key: key) }
    private var model: SubReportLoader<ProfileCatalog, ProfilesReportData> { appState.pages.subReport(key) { SubReportLoader() } }
    @State private var expanded: Bool?

    var body: some View {
        let p = state.params
        let catalog = model.catalog
        let ids = ProfilesReportSpec.identifiers(p)
        let hasQuery = !ids.isEmpty
        let columns = ProfilesReportSpec.columns(kind: kind)
        let report = model.report
        let search = p["search"] ?? ""
        let sortKey = columns.contains { $0.key == p["sort"] } ? p["sort"]! : "deviceName"
        let rows = report.map { ReportSorting.sort($0.rows.filter { $0.device.matches(search) || $0.name.lowercased().contains(search.lowercased()) },
                                                   by: columns.first { $0.key == sortKey }, ascending: p["direction"] != "desc", tiebreak: \.device.serialNumber) } ?? []
        let options = catalog?.options(for: kind, platform: appState.platformFilter) ?? []
        let preferenceKey = p["preferenceKey"]

        SubReportScaffold(
            section: .management,
            description: kind == .preference ? "Managed preference domains and their values across devices." : "Configuration profiles installed across devices.",
            footnote: "Last collected management state. Not installed is shown only when the device reported a management inventory within the maximum age; otherwise the row is unknown. A selection is evaluated only on platforms that report it.",
            selectionCount: ids.count + (preferenceKey == nil ? 0 : 1) + p.list("states").count + ScopeSelections.count(p),
            selectionsExpanded: Binding(get: { expanded ?? !hasQuery }, set: { expanded = $0 }),
            chips: ids.map { id in ReportChip(id: id, label: options.first { $0.identifier == id }?.name ?? id) { choose(ids.filter { $0 != id }) } }
                + (preferenceKey.map { k in [ReportChip(id: "key", label: "Key: \(k)") { state.params["preferenceKey"] = nil }] } ?? []),
            loading: model.loading, progress: model.progress, error: model.error ?? model.catalogError,
            canExport: !rows.isEmpty,
            export: {
                guard let report else { return }
                SubReportExport.save(filename: kind == .preference ? "managed-preferences-report" : "configuration-profiles-report",
                                     headers: ProfilesReportSpec.csvHeaders(kind: kind), rows: ProfilesReportSpec.csvRows(rows, generatedAt: report.generatedAt, reportURL: appState.currentReportURL))
            },
            refresh: { load(force: true) },
            clearAll: { state.params = ReportParams() }
        ) {
            SelectionCloud(label: kind == .preference ? "Preference domains" : "Profiles",
                           options: options.map { ReportChoice(value: $0.identifier, label: $0.name, devices: $0.devices) },
                           selected: ids, loading: model.catalogLoading && catalog == nil,
                           toggle: { v in choose(ids.contains(v) ? ids.filter { $0 != v } : ids + [v]) },
                           select: { choose($0) })
            if ids.count >= ProfilesReportSpec.maxSelections {
                Text("Up to \(ProfilesReportSpec.maxSelections) selections.").appFont(.caption).foregroundStyle(.secondary)
            }
            if kind == .preference, !ids.isEmpty {
                let keys = Array(Set(options.filter { ids.contains($0.identifier) }.flatMap(\.keys))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                ChoiceGroup(label: "Show the value of key", choices: keys.prefix(200).map { ReportChoice(value: $0, label: $0) },
                            isOn: { preferenceKey?.lowercased() == $0.lowercased() }, allLabel: "None", allOn: preferenceKey == nil,
                            onAll: { state.params["preferenceKey"] = nil }) { v in state.params["preferenceKey"] = preferenceKey == v ? nil : v }
            }
            ScopeSelections(params: state.binding, options: catalog?.options ?? .empty, freshnessLabel: "Management collection age", defaultMaxAge: 24)
        } status: {
            if hasQuery {
                SubReportStatusBar(summary: model.loading ? "Updating report… \(model.progress)" : report.map { countText(rows.count, $0.total, "rows") } ?? "", search: state.search()) {
                    ChoiceGroup(label: "State", choices: ProfilesReportSpec.states.map { s in ReportChoice(value: s, label: ProfilesReportSpec.stateLabel(s), devices: report.map { $0.summary[s] ?? 0 }) },
                                isOn: { p.list("states").contains($0) }, allLabel: "All", allOn: !p.has("states"), onAll: { state.params["states"] = nil }) { state.params.toggle("states", $0) }
                }
            }
        } content: {
            if !hasQuery {
                SubReportMessage(title: "Choose \(kind.noun) from Selections to build your report.", message: "Pick collected \(kind.noun) to see which devices have them, which lack them, and which are unknown.")
            } else if model.loading, report == nil {
                SubReportMessage(title: "Loading report…", message: model.progress.isEmpty ? nil : "\(model.progress) rows", systemImage: "hourglass")
            } else if report != nil {
                if rows.isEmpty { SubReportMessage(title: "No devices match these filters.") } else {
                    SubReportTable(rows: rows, columns: columns, sort: state.sort(default: "deviceName"), ascending: state.ascending(), device: \.device, deviceTab: .management)
                }
            }
        }
        .task(id: loadKey) { load(force: false) }
        .subReportLinking(state, section: .management, tab: kind.tab) { load(force: $0) }
    }

    private func choose(_ values: [String]) {
        state.params.setJSONList("identifiers", Array(values.prefix(ProfilesReportSpec.maxSelections)))
        state.params["preferenceKey"] = nil
    }

    private var loadKey: String {
        let p = state.params, f = appState.platformFilter
        return "\(SubReportLoader<ProfileCatalog, ProfilesReportData>.key(appState.api, ProfilesReportSpec.optionsQuery(p, platform: f)) ?? "")|\(SubReportLoader<ProfileCatalog, ProfilesReportData>.key(appState.api, ProfilesReportSpec.apiQuery(p, kind: kind, platform: f)) ?? "-")"
    }

    private func load(force: Bool) {
        let api = appState.api, p = state.params, f = appState.platformFilter
        let options = ProfilesReportSpec.optionsQuery(p, platform: f), query = ProfilesReportSpec.apiQuery(p, kind: kind, platform: f)
        model.loadCatalog(key: SubReportLoader<ProfileCatalog, ProfilesReportData>.key(api, options)!, force: force) { try await api.profileCatalog(query: options) }
        model.loadReport(key: SubReportLoader<ProfileCatalog, ProfilesReportData>.key(api, query), force: force) { progress in try await api.profilesReport(query: query ?? [:], progress: progress) }
    }
}

private func countText(_ shown: Int, _ total: Int, _ noun: String) -> String {
    shown == total ? "\(shown.formatted()) \(noun)" : "\(shown.formatted()) of \(total.formatted()) \(noun)"
}

// MARK: - Vulnerabilities

/// The CVE summary or its device rows; the page holds whichever view the link asks for.
enum VulnerabilityData: Sendable {
    case summary(VulnerabilitySummaryData)
    case devices(VulnerabilityDevicesData)
}

/// Security › Vulnerabilities: each collected CVE with distinct device counts; choosing
/// one drills into the devices that report it (`view=devices`).
struct VulnerabilitiesReportPage: View {
    @Environment(AppState.self) private var appState
    private var state: SubReportState { SubReportState(appState: appState, key: "security.vulnerabilities") }
    private var model: SubReportLoader<VulnerabilityCatalog, VulnerabilityData> { appState.pages.subReport("security.vulnerabilities") { SubReportLoader() } }
    @State private var expanded = false

    var body: some View {
        let p = state.params
        let view = VulnerabilitiesReportSpec.view(p)
        let catalog = model.catalog
        let cves = p.jsonList("cves", commaFallback: true)
        let defaultAscending = view == .devices
        let sortKey = p["sort"]
        let ascending = p["dir"].map { $0 == "asc" } ?? defaultAscending
        let summary: VulnerabilitySummaryData? = { if case .summary(let s) = model.report { return s }; return nil }()
        let devices: VulnerabilityDevicesData? = { if case .devices(let d) = model.report { return d }; return nil }()
        let summaryRows = summary.map { s -> [CveSummary] in
            let filtered = VulnerabilitiesReportSpec.filterSummary(s.cves, query: p["q"] ?? "")
            guard let sortKey, let col = VulnerabilitiesReportSpec.summaryColumns.first(where: { $0.key == sortKey }) else { return filtered }
            return ReportSorting.sort(filtered, by: col, ascending: ascending, tiebreak: \.identifier)
        } ?? []
        let search = p["search"] ?? ""
        let deviceRows = devices.map { d in
            ReportSorting.sort(d.rows.filter { $0.device.matches(search) }, by: VulnerabilitiesReportSpec.deviceColumns.first { $0.key == (sortKey ?? "identifier") } ?? VulnerabilitiesReportSpec.deviceColumns[0],
                               ascending: ascending, tiebreak: { "\($0.identifier) \($0.device.serialNumber)" })
        } ?? []
        let coverage = summary?.coverage ?? devices?.coverage
        let visibleCount = view == .summary ? summaryRows.count : deviceRows.count

        SubReportScaffold(
            section: .security, description: "CVEs collected on each device: Windows security updates and macOS unpatched CVEs.",
            footnote: "Last collected state. Severity shows only what the client collected; macOS entries carry none. Windows rows without a CVE id are pending security updates, identified by their update article.",
            selectionCount: cves.count + ["statuses", "severities"].reduce(0) { $0 + p.list($1).count } + (p.has("exploited") ? 1 : 0) + ScopeSelections.count(p),
            selectionsExpanded: $expanded,
            chips: cves.map { c in ReportChip(id: c, label: c) { state.params.setJSONList("cves", cves.filter { $0 != c }) } },
            loading: model.loading, progress: model.progress, error: model.error ?? model.catalogError,
            canExport: visibleCount > 0,
            exportHelp: view == .summary ? "CSV of the CVEs shown, in this order." : "CSV of the filtered rows, with all device and collection fields.",
            export: {
                let url = appState.currentReportURL
                if let summary, view == .summary {
                    SubReportExport.save(filename: "cve-summary", headers: VulnerabilitiesReportSpec.summaryCSVHeaders, rows: VulnerabilitiesReportSpec.summaryCSVRows(summaryRows, generatedAt: summary.generatedAt, reportURL: url))
                } else if let devices {
                    SubReportExport.save(filename: "vulnerabilities-report", headers: VulnerabilitiesReportSpec.deviceCSVHeaders, rows: VulnerabilitiesReportSpec.deviceCSVRows(deviceRows, generatedAt: devices.generatedAt, reportURL: url))
                }
            },
            refresh: { load(force: true) },
            clearAll: { state.params = ReportParams(view == .devices ? ["view": "devices"] : [:]) }
        ) {
            SelectionCloud(label: "CVEs", options: catalog?.cves ?? [], selected: cves, loading: model.catalogLoading && catalog == nil,
                           toggle: { v in state.params.setJSONList("cves", cves.contains(v) ? cves.filter { $0 != v } : cves + [v]) },
                           select: { state.params.setJSONList("cves", $0) })
            VStack(alignment: .leading, spacing: 12) {
                ChoiceGroup(label: "Status", choices: VulnerabilitiesReportSpec.statuses.map { ReportChoice(value: $0, label: SecurityLabels.status($0)) },
                            isOn: { p.list("statuses").contains($0) }, allLabel: "All", allOn: !p.has("statuses"), onAll: { state.params["statuses"] = nil }) { state.params.toggle("statuses", $0) }
                ChoiceGroup(label: "Severity", choices: (catalog?.severities ?? []).map { ReportChoice(value: $0.value, label: $0.label) },
                            isOn: { p.list("severities").contains($0) }, allLabel: "All", allOn: !p.has("severities"), onAll: { state.params["severities"] = nil }) { state.params.toggle("severities", $0) }
                ChoiceGroup(label: "Actively exploited", choices: VulnerabilitiesReportSpec.exploitedChoices.map { ReportChoice(value: $0.0, label: $0.1) },
                            isOn: { (p["exploited"] ?? "all") == $0 }) { v in state.params["exploited"] = v == "all" ? nil : v }
            }
            ScopeSelections(params: state.binding, options: catalog?.options ?? .empty, freshnessLabel: "Security collection age", defaultMaxAge: 168, showScope: false)
        } status: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Picker("View", selection: Binding(get: { view }, set: { v in
                        state.params["view"] = v == .summary ? nil : "devices"
                        state.params.remove(["sort", "dir"])
                    })) {
                        Text("CVE Summary").tag(VulnerabilitiesReportSpec.View.summary)
                        Text("Device Rows").tag(VulnerabilitiesReportSpec.View.devices)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Text(model.loading && model.report == nil ? "Loading…" : view == .summary
                         ? summary.map { countText(summaryRows.count, $0.cves.count, "CVEs") } ?? ""
                         : devices.map { "\(countText(deviceRows.count, $0.total, "rows")) across \(Set(deviceRows.map(\.device.serialNumber)).count.formatted()) devices" } ?? "")
                        .appFont(.callout).foregroundStyle(.secondary).monospacedDigit()
                    if view == .summary {
                        TextField("Filter CVEs", text: Binding(get: { p["q"] ?? "" }, set: { state.params["q"] = $0 })).textFieldStyle(.roundedBorder).frame(width: 220)
                    } else {
                        TextField("Search devices", text: state.search()).textFieldStyle(.roundedBorder).frame(width: 220)
                    }
                    Spacer()
                }
                if let coverage { Text(coverage.vulnerabilityText).appFont(.caption).foregroundStyle(.secondary).padding(.top, 6) }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .overlay(alignment: .bottom) { Divider() }
        } content: {
            if model.loading, model.report == nil {
                SubReportMessage(title: view == .summary ? "Loading CVE summary…" : "Loading vulnerabilities…", message: model.progress.isEmpty ? nil : "\(model.progress) rows", systemImage: "hourglass")
            } else if view == .summary, summary != nil {
                if summaryRows.isEmpty { SubReportMessage(title: "No collected CVEs match these filters.") } else {
                    SubReportTable(rows: summaryRows, columns: VulnerabilitiesReportSpec.summaryColumns,
                                   sort: Binding(get: { sortKey ?? "" }, set: { state.params["sort"] = $0 }), ascending: state.ascending("dir", default: defaultAscending),
                                   link: { $0.link }, activate: { drill($0.identifier) }, activateLabel: "Show Devices Reporting This")
                }
            } else if view == .devices, devices != nil {
                if deviceRows.isEmpty { SubReportMessage(title: "No collected CVE rows match these filters.") } else {
                    SubReportTable(rows: deviceRows, columns: VulnerabilitiesReportSpec.deviceColumns, sort: state.sort(default: "identifier"), ascending: state.ascending("dir", default: true),
                                   device: \.device, deviceTab: .security, link: { $0.link })
                }
            }
        }
        .task(id: loadKey) { load(force: false) }
        .subReportLinking(state, section: .security, tab: "vulnerabilities") { load(force: $0) }
    }

    private func drill(_ identifier: String) {
        state.params["view"] = "devices"
        state.params.setJSONList("cves", [identifier])
        state.params.remove(["sort", "dir", "q"])
    }

    private var loadKey: String {
        let p = state.params, f = appState.platformFilter
        return "\(SubReportLoader<VulnerabilityCatalog, VulnerabilityData>.key(appState.api, VulnerabilitiesReportSpec.optionsQuery(p, platform: f)) ?? "")|\(SubReportLoader<VulnerabilityCatalog, VulnerabilityData>.key(appState.api, VulnerabilitiesReportSpec.apiQuery(p, platform: f)) ?? "")"
    }

    private func load(force: Bool) {
        let api = appState.api, p = state.params, f = appState.platformFilter
        let options = VulnerabilitiesReportSpec.optionsQuery(p, platform: f), query = VulnerabilitiesReportSpec.apiQuery(p, platform: f)
        let summary = VulnerabilitiesReportSpec.view(p) == .summary
        model.loadCatalog(key: SubReportLoader<VulnerabilityCatalog, VulnerabilityData>.key(api, options)!, force: force) { try await api.vulnerabilityCatalog(query: options) }
        model.loadReport(key: SubReportLoader<VulnerabilityCatalog, VulnerabilityData>.key(api, query), force: force) { progress in
            summary ? .summary(try await api.vulnerabilitySummary(query: query)) : .devices(try await api.vulnerabilityDevices(query: query, progress: progress))
        }
    }
}

// MARK: - Threat detections

/// Security › Threat Detections: what endpoint protection collected, in a time window.
struct ThreatsReportPage: View {
    @Environment(AppState.self) private var appState
    private var state: SubReportState { SubReportState(appState: appState, key: "security.threats") }
    private var model: SubReportLoader<DetectionCatalog, DetectionsData> { appState.pages.subReport("security.threats") { SubReportLoader() } }
    @State private var expanded = false

    var body: some View {
        let p = state.params
        let catalog = model.catalog
        let report = model.report
        let days = DetectionsReportSpec.days(p)
        let search = p["search"] ?? ""
        let sortKey = p["sort"] ?? "lastSeenAt"
        let rows = report.map { ReportSorting.sort($0.rows.filter { $0.device.matches(search) }, by: DetectionsReportSpec.columns.first { $0.key == sortKey } ?? DetectionsReportSpec.columns[5],
                                                   ascending: p["dir"].map { $0 == "asc" } ?? false, tiebreak: \.device.serialNumber) } ?? []
        let facet: (String, String, [ReportChoice]) -> ChoiceGroup = { label, key, values in
            ChoiceGroup(label: label, choices: values, isOn: { p.list(key).contains($0) }, allLabel: "All", allOn: !p.has(key), onAll: { state.params[key] = nil }) { state.params.toggle(key, $0) }
        }

        SubReportScaffold(
            section: .security, description: "Threat detections collected from endpoint protection, including blocked attack surface reduction events.",
            footnote: "Last collected detections. A detection without a readable time is left out of a time window. Blocked attack surface reduction events show protection working, not an infection.",
            selectionCount: ["vendors", "categories", "severities", "statuses"].reduce(0) { $0 + p.list($1).count } + ScopeSelections.count(p),
            selectionsExpanded: $expanded,
            loading: model.loading, progress: model.progress, error: model.error ?? model.catalogError,
            canExport: !rows.isEmpty,
            export: {
                guard let report else { return }
                SubReportExport.save(filename: "threat-detections", headers: DetectionsReportSpec.csvHeaders, rows: DetectionsReportSpec.csvRows(rows, generatedAt: report.generatedAt, reportURL: appState.currentReportURL))
            },
            refresh: { load(force: true) },
            clearAll: { state.params = ReportParams() }
        ) {
            VStack(alignment: .leading, spacing: 12) {
                facet("Category", "categories", catalog?.categories ?? [])
                facet("Severity", "severities", catalog?.severities ?? [])
                facet("Status", "statuses", catalog?.statuses ?? [])
            }
            ScopeSelections(params: state.binding, options: catalog?.options ?? .empty)
        } status: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 20) {
                    ChoiceGroup(label: "Detected within", choices: DetectionsReportSpec.dayChoices.map { ReportChoice(value: String($0.0), label: $0.1) },
                                isOn: { String(days) == $0 }) { v in state.params["days"] = v == String(DetectionsReportSpec.defaultDays) ? nil : v }
                    facet("Vendor / product", "vendors", catalog?.vendors ?? [])
                    Spacer()
                }
                HStack(spacing: 12) {
                    Text(model.loading ? "Loading…" : report.map { _ in "\(rows.count.formatted()) detections" } ?? "").appFont(.callout).foregroundStyle(.secondary).monospacedDigit()
                    TextField("Search devices", text: state.search()).textFieldStyle(.roundedBorder).frame(width: 220)
                    Spacer()
                }
                if let report { Text(report.coverage.detectionText).appFont(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .overlay(alignment: .bottom) { Divider() }
        } content: {
            if model.loading, report == nil {
                SubReportMessage(title: "Loading threat detections…", message: model.progress.isEmpty ? nil : "\(model.progress) rows", systemImage: "hourglass")
            } else if report != nil {
                if rows.isEmpty { SubReportMessage(title: "No collected detections match these filters\(days > 0 ? " in this window" : "").") } else {
                    SubReportTable(rows: rows, columns: DetectionsReportSpec.columns, sort: state.sort(default: "lastSeenAt"), ascending: state.ascending("dir", default: false), device: \.device, deviceTab: .security)
                }
            }
        }
        .task(id: loadKey) { load(force: false) }
        .subReportLinking(state, section: .security, tab: "threats") { load(force: $0) }
    }

    private var loadKey: String {
        let p = state.params, f = appState.platformFilter
        return "\(SubReportLoader<DetectionCatalog, DetectionsData>.key(appState.api, DetectionsReportSpec.optionsQuery(p, platform: f)) ?? "")|\(SubReportLoader<DetectionCatalog, DetectionsData>.key(appState.api, DetectionsReportSpec.apiQuery(p, platform: f)) ?? "")"
    }

    private func load(force: Bool) {
        let api = appState.api, p = state.params, f = appState.platformFilter
        let options = DetectionsReportSpec.optionsQuery(p, platform: f), query = DetectionsReportSpec.apiQuery(p, platform: f)
        model.loadCatalog(key: SubReportLoader<DetectionCatalog, DetectionsData>.key(api, options)!, force: force) { try await api.detectionCatalog(query: options) }
        model.loadReport(key: SubReportLoader<DetectionCatalog, DetectionsData>.key(api, query), force: force) { progress in try await api.detectionsReport(query: query, progress: progress) }
    }
}

// MARK: - Identity posture

/// Identity › Sign-in & Recovery Posture: what each device last reported, with quick views.
struct PostureReportPage: View {
    @Environment(AppState.self) private var appState
    private var state: SubReportState { SubReportState(appState: appState, key: "identity.posture") }
    private var model: SubReportLoader<Int, PostureReportData> { appState.pages.subReport("identity.posture") { SubReportLoader() } }
    @State private var expanded = false

    var body: some View {
        let p = state.params
        let platform = appState.platformFilter
        let report = model.report
        let available = PostureReportSpec.availableColumns(platform)
        let columns = PostureReportSpec.columns.filter { available.contains($0.key) }
        let view = ReportView(params: p, available: available, defaults: PostureReportSpec.defaultColumns(platform))
        let visible = view.columns.compactMap { k in columns.first { $0.key == k } }
        let search = p["search"] ?? ""
        let rows = report.map { ReportSorting.sort($0.devices.filter { $0.device.matches(search) || ($0.computerName?.lowercased().contains(search.lowercased()) ?? false) },
                                                   by: columns.first { $0.key == view.sort }, ascending: view.ascending, tiebreak: \.device.serialNumber) } ?? []
        let views = p.list("views")

        SubReportScaffold(
            section: .identity, description: "Sign-in and recovery posture each device last reported.",
            footnote: "Last collected local state. Quick views count only collection within the maximum age; older, missing or unreadable collection is unknown, never compliant. Recovery key shows whether a FileVault key exists on the device, not whether it is escrowed. Activation Lock can be inferred from Find My when the device does not report it.",
            selectionCount: ScopeSelections.count(p),
            selectionsExpanded: $expanded,
            loading: model.loading, progress: model.progress, error: model.error,
            canExport: !rows.isEmpty,
            export: {
                guard let report else { return }
                SubReportExport.save(filename: "identity-posture", headers: PostureReportSpec.csvHeaders, rows: PostureReportSpec.csvRows(rows, generatedAt: report.generatedAt, reportURL: appState.currentReportURL))
            },
            refresh: { load(force: true) },
            clearAll: { state.params = ReportParams() }
        ) {
            ScopeSelections(params: state.binding, options: report?.options ?? .empty, freshnessLabel: "Identity collection age", defaultMaxAge: 168)
        } status: {
            SubReportStatusBar(summary: model.loading ? "Updating report… \(model.progress)" : report.map { countText(rows.count, $0.total, "devices") } ?? "", search: state.search()) {
                ChoiceGroup(label: "Quick views", choices: PostureReportSpec.quickViews(for: platform).map { key, label, _ in
                    var text = label
                    if let report {
                        text += " \(report.summary[key] ?? 0)"
                        if let u = report.unknown[key], u > 0 { text += " · \(u) unknown" }
                    }
                    return ReportChoice(value: key, label: text)
                }, isOn: { views.contains($0) }, allLabel: "All devices", allOn: views.isEmpty, onAll: { state.params["views"] = nil }) { state.params.toggle("views", $0) }
                ColumnsMenu(columns: columns, visible: view.columns) { cols in state.params["columns"] = cols?.joined(separator: ",") }
            }
        } content: {
            if model.loading, report == nil {
                SubReportMessage(title: "Loading posture report…", message: model.progress.isEmpty ? nil : "\(model.progress) devices", systemImage: "hourglass")
            } else if report != nil {
                if rows.isEmpty { SubReportMessage(title: "No devices match these filters.") } else {
                    SubReportTable(rows: rows, columns: visible, sort: state.sort(default: "deviceName"), ascending: state.ascending(), device: \.device, deviceTab: .identity)
                }
            }
        }
        .task(id: loadKey) { load(force: false) }
        .subReportLinking(state, section: .identity, tab: "posture") { load(force: $0) }
    }

    private var loadKey: String {
        SubReportLoader<Int, PostureReportData>.key(appState.api, PostureReportSpec.apiQuery(state.params, platform: appState.platformFilter)) ?? ""
    }

    private func load(force: Bool) {
        let api = appState.api, query = PostureReportSpec.apiQuery(state.params, platform: appState.platformFilter)
        model.loadReport(key: SubReportLoader<Int, PostureReportData>.key(api, query), force: force) { progress in try await api.postureReport(query: query, progress: progress) }
    }
}
