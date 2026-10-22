import SwiftUI
import Charts
import ReportMateKit

/// Loads the fleet's management tools logs: `/management/logs/fleet`, or, on a server
/// without it, the dashboard's Management Tools Logs card (see `ManagementToolsFleet`).
@MainActor
@Observable
final class ManagementLogsModel {
    private(set) var fleet: ManagementToolsFleet?
    private(set) var loading = false
    private(set) var error: String?
    private(set) var loadedAt: Date?
    private var loadedKey: String?

    /// `message` goes to the server, which lists the devices that logged it; tool and
    /// level narrow on screen.
    func load(api: ReportMateAPI, hours: Int, platform: PlatformFilter, message: String? = nil, force: Bool = false) async {
        let p = DashboardInsightsDocument.platformParameter(platform)
        let key = "\(api.configuration.normalizedBaseURL)|\(hours)|\(p)|\(message ?? "")"
        if !force, key == loadedKey, let loadedAt, Date().timeIntervalSince(loadedAt) < 120 { return }
        if loading, !force { return }
        loading = true
        defer { loading = false }
        if key != loadedKey { fleet = nil }
        do {
            let json = try await api.getJSON("/management/logs/fleet", query: ["hours": String(hours), "platform": p, "message": message])
            if json.isNull {
                // No fleet endpoint on this server yet: the dashboard card has 24 hours of the same data.
                var card = try await api.getJSON("/dashboard/insights/managementToolLogs", query: ["platform": p])
                if card.isNull { card = try await api.getJSON("/dashboard/insights/managementToolErrors", query: ["platform": p]) }
                guard !card.isNull else { throw APIError.http(status: 404, message: DashboardInsightsModel.notDeployed, path: "/management/logs/fleet") }
                let data = DashboardInsightsDocument.card(fromEnvelope: card)
                if let message = data.error { throw APIError.http(status: 500, message: message, path: "/dashboard/insights/managementToolLogs") }
                fleet = ManagementToolsFleet(card: data)
            } else {
                fleet = ManagementToolsFleet(json: json)
            }
            error = nil
            loadedKey = key
            loadedAt = Date()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Management › Tools Logs: the management tools' errors and warnings across the
/// fleet, per tool with a trend, the commonest messages, and the devices behind
/// them. `reportmate://management/logs?tool=&level=&hours=&message=&platform=`.
struct ManagementLogsReportView: View {
    @Environment(AppState.self) private var appState
    private var model: ManagementLogsModel { appState.pages.managementLogs }

    @State private var tool: String?
    @State private var level: String?
    @State private var hours = 24
    @State private var message: String?

    enum ToolColumn { case name, errors, warnings, lines, lastSeen }
    enum DeviceColumn { case device, tool, errors, warnings, lastAt }
    @State private var toolSort: ToolColumn = .errors
    @State private var toolAscending = false
    @State private var deviceSort: DeviceColumn = .errors
    @State private var deviceAscending = false

    private var linkQuery: [String: String] {
        var q: [String: String] = [:]
        if let tool { q["tool"] = tool }
        if let level { q["level"] = level }
        if hours != 24 { q["hours"] = String(hours) }
        if let message { q["message"] = message }
        return q
    }

    private var shown: ManagementToolsFleet? { model.fleet?.filtered(tool: tool, level: level, message: message) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.loading { LoadProgressBar(updating: model.fleet != nil) }
            if let error = model.error, model.fleet != nil, !model.loading {
                RefreshFailedBanner(message: error, updatedAt: model.loadedAt) { reload(force: true) }
            }
            if let fleet = shown {
                if fleet.isPartial || (model.fleet?.isPartial ?? false) {
                    Text(hours == 24
                         ? "This server doesn't serve fleet tool logs yet; showing the dashboard's last 24 hours, with one example device per message."
                         : "This server doesn't serve fleet tool logs yet, so only the last 24 hours are available.")
                        .appFont(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 6)
                        .background(Color.subtleBackground)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        toolsTable(fleet)
                        messagesTable(fleet)
                        devicesTable(fleet)
                    }
                    .padding(16)
                }
            } else if let error = model.error, !model.loading {
                ErrorBanner(message: error) { reload(force: true) }.padding()
                Spacer()
            } else {
                ReportSkeleton(widgets: 0, columns: [180, 90, 90, 90, nil]).skeletonTimeout(fillsPage: true) { reload(force: true) }
            }
        }
        .navigationTitle("Management Tools Logs")
        .task(id: "\(appState.configuration.normalizedBaseURL)|\(hours)|\(appState.platformFilter.rawValue)|\(message ?? "")") {
            await model.load(api: appState.api, hours: hours, platform: appState.platformFilter, message: message)
        }
        .onChange(of: appState.refreshRequested) { _, _ in reload(force: true) }
        .onChange(of: appState.pendingDeepLink, initial: true) { _, _ in
            guard let link = appState.consumeDeepLink(for: .management) else { return }
            tool = link.query["tool"]
            level = ["error", "warning"].contains(link.query["level"] ?? "") ? link.query["level"] : nil
            hours = link.query["hours"] == "168" ? 168 : 24
            message = link.query["message"]
        }
        .onChange(of: linkQuery, initial: true) { _, q in appState.linkQuery = q }
    }

    private func reload(force: Bool) {
        Task { await model.load(api: appState.api, hours: hours, platform: appState.platformFilter, message: message, force: force) }
    }

    // MARK: Header and filters

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ManagementViewSwitch()
                VStack(alignment: .leading, spacing: 2) {
                    Label("Management Tools Logs", systemImage: AppSection.management.systemImage)
                        .appFont(.title3, weight: .semibold).foregroundStyle(AppSection.management.accent)
                    Text("Errors and warnings in the management tools' own logs, MDM agent excluded").appFont(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Window", selection: $hours) { Text("24 hours").tag(24); Text("7 days").tag(168) }
                    .pickerStyle(.segmented).fixedSize()
                Picker("Level", selection: Binding(get: { level ?? "all" }, set: { level = $0 == "all" ? nil : $0 })) {
                    Text("All").tag("all"); Text("Errors").tag("error"); Text("Warnings").tag("warning")
                }
                .pickerStyle(.segmented).fixedSize()
                CSVExportButton(filename: "management-tools-logs", headers: ["Device", "Serial Number", "Tool", "Errors", "Warnings", "Last At"]) {
                    (shown?.devices ?? []).map { [$0.deviceName, $0.serialNumber, $0.name, String($0.errors), String($0.warnings), $0.lastAt.map { TimeFormatting.exact($0) } ?? ""] }
                }
            }
            let chips: [(String, String, () -> Void)] = [
                tool.map { t in ("tool", "Tool: \(model.fleet?.tools.first { $0.tool == t }?.name ?? t)", { self.tool = nil }) },
                message.map { m in ("message", "Message: \(model.fleet?.messages.first { $0.id == m }?.message ?? m)", { self.message = nil }) },
            ].compactMap { $0 }
            if !chips.isEmpty {
                HStack(spacing: 6) {
                    ForEach(chips, id: \.0) { chip in
                        Button(action: chip.2) {
                            HStack(spacing: 4) { Text(chip.1).appFont(.caption, weight: .medium).lineLimit(1); Image(systemName: "xmark").appFont(.caption2) }
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.14), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help("Remove this filter")
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: Tools

    private func sortedTools(_ tools: [ManagementToolsFleet.Tool]) -> [ManagementToolsFleet.Tool] {
        tools.sorted { a, b in
            let order: Bool
            switch toolSort {
            case .name: order = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .errors: order = a.devicesWithErrors < b.devicesWithErrors
            case .warnings: order = a.devicesWithWarnings < b.devicesWithWarnings
            case .lines: order = a.errorLines + a.warningLines < b.errorLines + b.warningLines
            case .lastSeen: order = (a.lastSeen ?? .distantPast) < (b.lastSeen ?? .distantPast)
            }
            return toolAscending ? order : !order
        }
    }

    private func toolsTable(_ fleet: ManagementToolsFleet) -> some View {
        Card {
            VStack(spacing: 0) {
                CardHeader("Tools", subtitle: "Devices with errors and warnings, last \(hours == 24 ? "24 hours" : "7 days")", systemImage: AppSection.management.systemImage, tone: .yellow)
                HStack(spacing: 12) {
                    ReportSortHeader(title: "Tool", column: ToolColumn.name, sortColumn: $toolSort, ascending: $toolAscending)
                    ReportSortHeader(title: "Errors", column: ToolColumn.errors, sortColumn: $toolSort, ascending: $toolAscending, width: 80, alignment: .trailing, descendingFirst: true)
                    ReportSortHeader(title: "Warnings", column: ToolColumn.warnings, sortColumn: $toolSort, ascending: $toolAscending, width: 90, alignment: .trailing, descendingFirst: true)
                    ReportSortHeader(title: "Lines", column: ToolColumn.lines, sortColumn: $toolSort, ascending: $toolAscending, width: 80, alignment: .trailing, descendingFirst: true)
                    ReportHeaderLabel(title: "Trend", width: 120)
                    ReportSortHeader(title: "Last Seen", column: ToolColumn.lastSeen, sortColumn: $toolSort, ascending: $toolAscending, width: 110, descendingFirst: true)
                }
                .padding(.horizontal, 16).padding(.vertical, 8).background(Color.subtleBackground)
                if fleet.tools.isEmpty {
                    Text("No tool logged an error or warning in this window").appFont(.callout).foregroundStyle(.secondary).padding(16)
                }
                ForEach(sortedTools(fleet.tools)) { t in
                    Button { tool = tool == t.tool ? nil : t.tool } label: {
                        HStack(spacing: 12) {
                            Text(t.name).appFont(.callout, weight: tool == t.tool ? .semibold : .regular).frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(t.devicesWithErrors)").foregroundStyle(t.devicesWithErrors == 0 ? Color.secondary : Tone.red.color).frame(width: 80, alignment: .trailing)
                            Text("\(t.devicesWithWarnings)").foregroundStyle(t.devicesWithWarnings == 0 ? Color.secondary : Tone.yellow.color).frame(width: 90, alignment: .trailing)
                            Text((t.errorLines + t.warningLines).formatted()).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                            trend(t).frame(width: 120, height: 22)
                            Text(t.lastSeen.map { TimeFormatting.relative($0) } ?? "–").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                        }
                        .appFont(.callout).monospacedDigit()
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(tool == t.tool ? Color.accentColor.opacity(0.08) : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tool == t.tool ? "Show every tool" : "Show only \(t.name)")
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private func trend(_ t: ManagementToolsFleet.Tool) -> some View {
        if t.trend.count > 1 {
            Chart(Array(t.trend.enumerated()), id: \.offset) { i, p in
                LineMark(x: .value("At", i), y: .value("Errors", p.errors)).foregroundStyle(Tone.red.color)
                LineMark(x: .value("At", i), y: .value("Warnings", p.warnings)).foregroundStyle(Tone.yellow.color)
            }
            .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
            .accessibilityLabel("Trend over the window")
        } else {
            Text("–").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Messages

    private func messagesTable(_ fleet: ManagementToolsFleet) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader("Common messages", subtitle: "Grouped with timestamps and identifiers stripped; click one for its devices", systemImage: "text.bubble", tone: .yellow)
                if fleet.messages.isEmpty {
                    Text("No messages in this window").appFont(.callout).foregroundStyle(.secondary).padding(16)
                }
                ForEach(fleet.messages) { m in
                    Button { message = message == m.id ? nil : m.id } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Image(systemName: m.level == "warning" ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(m.level == "warning" ? Tone.yellow.color : Tone.red.color).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.message).appFont(.callout, weight: message == m.id ? .semibold : .regular).lineLimit(2).textSelection(.enabled)
                                Text(m.name + (m.lastSeen.map { " · last \(TimeFormatting.relative($0))" } ?? "")).appFont(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(m.devices) devices").appFont(.callout).monospacedDigit().frame(width: 100, alignment: .trailing)
                            Text("\(m.lines.formatted()) lines").appFont(.callout).foregroundStyle(.secondary).monospacedDigit().frame(width: 100, alignment: .trailing)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(message == m.id ? Color.accentColor.opacity(0.08) : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { Button("Copy Message") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(m.message, forType: .string) } }
                    Divider()
                }
            }
        }
    }

    // MARK: Devices

    private func sortedDevices(_ devices: [ManagementToolsFleet.Device]) -> [ManagementToolsFleet.Device] {
        devices.sorted { a, b in
            let order: Bool
            switch deviceSort {
            case .device: order = a.deviceName.localizedCaseInsensitiveCompare(b.deviceName) == .orderedAscending
            case .tool: order = a.name < b.name
            case .errors: order = a.errors < b.errors
            case .warnings: order = a.warnings < b.warnings
            case .lastAt: order = (a.lastAt ?? .distantPast) < (b.lastAt ?? .distantPast)
            }
            return deviceAscending ? order : !order
        }
    }

    private func devicesTable(_ fleet: ManagementToolsFleet) -> some View {
        Card {
            VStack(spacing: 0) {
                CardHeader("Devices", subtitle: message == nil ? "Devices that logged errors or warnings" : "Devices that logged the selected message", systemImage: "laptopcomputer", tone: .yellow)
                HStack(spacing: 12) {
                    ReportSortHeader(title: "Device", column: DeviceColumn.device, sortColumn: $deviceSort, ascending: $deviceAscending)
                    ReportSortHeader(title: "Tool", column: DeviceColumn.tool, sortColumn: $deviceSort, ascending: $deviceAscending, width: 140)
                    ReportSortHeader(title: "Errors", column: DeviceColumn.errors, sortColumn: $deviceSort, ascending: $deviceAscending, width: 80, alignment: .trailing, descendingFirst: true)
                    ReportSortHeader(title: "Warnings", column: DeviceColumn.warnings, sortColumn: $deviceSort, ascending: $deviceAscending, width: 90, alignment: .trailing, descendingFirst: true)
                    ReportSortHeader(title: "Last At", column: DeviceColumn.lastAt, sortColumn: $deviceSort, ascending: $deviceAscending, width: 120, descendingFirst: true)
                }
                .padding(.horizontal, 16).padding(.vertical, 8).background(Color.subtleBackground)
                if fleet.devicesTruncated {
                    Text("Showing the first \(fleet.devices.count.formatted()) devices; narrow by tool, level or message to see the rest.").appFont(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 8)
                }
                if fleet.devices.isEmpty {
                    Text(model.fleet?.isPartial == true ? "The device list needs the server's fleet tool logs; each message above links to an example device." : "No devices match these filters")
                        .appFont(.callout).foregroundStyle(.secondary).padding(16)
                }
                ForEach(sortedDevices(fleet.devices)) { d in
                    let link = DeepLink(target: .device(serial: d.serialNumber, tab: "management"), query: ["tool": d.tool, "level": d.errors > 0 ? "error" : "warning"])
                    Button { appState.open(deepLink: link) } label: {
                        HStack(spacing: 12) {
                            Text(d.deviceName).appFont(.callout, weight: .medium).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Text(d.name).frame(width: 140, alignment: .leading)
                            Text("\(d.errors)").foregroundStyle(d.errors == 0 ? Color.secondary : Tone.red.color).frame(width: 80, alignment: .trailing)
                            Text("\(d.warnings)").foregroundStyle(d.warnings == 0 ? Color.secondary : Tone.yellow.color).frame(width: 90, alignment: .trailing)
                            Text(d.lastAt.map { TimeFormatting.relative($0) } ?? "–").foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                        }
                        .appFont(.callout).monospacedDigit()
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open \(d.deviceName)'s \(d.name) log")
                    .linkContextMenu(link)
                    Divider()
                }
            }
        }
    }
}

/// Management's two views, Enrollment and Tools Logs, as a segmented control in each view's header.
struct ManagementViewSwitch: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Picker("View", selection: Binding(get: { appState.pages.managementMode }, set: { mode in
            appState.linkQuery = [:]
            appState.pages.managementMode = mode
        })) {
            Text("Enrollment").tag(PageModels.ManagementMode.enrollment)
            Text("Tools Logs").tag(PageModels.ManagementMode.logs)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("MDM enrollment, or the management tools' logs across the fleet")
    }
}
