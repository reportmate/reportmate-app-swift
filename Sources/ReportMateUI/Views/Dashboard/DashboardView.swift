import SwiftUI
import Charts
import ReportMateKit

/// The dashboard: fleet status, install error and warning counters, new
/// clients on the left; recent events, platform distribution and OS version
/// charts on the right, and the twelve insight cards. The layout follows the
/// window: two insight columns on a 27-inch display (`wideBreakpoint`), one
/// beside the charts on a desktop (`desktopBreakpoint`), and a grid underneath
/// below that. Refreshes every 30 seconds like the web page.
@MainActor
@Observable
final class DashboardModel {
    var data: DashboardData?
    var loading = false
    var error: String?
    /// The load on arriving at the page is in flight.
    var refreshing = false
    /// A refresh failed while the last good payload stays on screen.
    var refreshError: String?
    var lastUpdate: Date?
    var connectionStatus: ConnectionStatus = .connecting
    /// Bumped every two minutes so relative times re-render.
    var clockTick = 0

    enum ConnectionStatus { case connecting, connected, reconnecting, polling, error }

    private var liveTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private static let maxReconnectAttempts = 5

    var isLive: Bool { connectionStatus == .connected || connectionStatus == .reconnecting }

    func load(api: ReportMateAPI, includeArchived: Bool, initial: Bool) async {
        if initial { loading = data == nil }
        // Only the load on arrival shows as Updating; the 30-second poll stays quiet.
        if initial { refreshing = true }
        defer { if initial { refreshing = false } }
        do {
            let fresh = try await api.dashboard(eventsLimit: 200, includeArchived: includeArchived)
            if var existing = data, !initial {
                // Background refresh: merge, never clear on an empty response.
                if !fresh.devices.isEmpty { existing.devices = fresh.devices; existing.totalDevices = fresh.totalDevices }
                existing.installStats = fresh.installStats
                if !fresh.events.isEmpty {
                    let known = Set(existing.events.map(\.id))
                    let new = fresh.events.filter { !known.contains($0.id) }
                    if !new.isEmpty {
                        existing.events = (new + existing.events).sorted { ($0.ts ?? .distantPast) > ($1.ts ?? .distantPast) }.prefix(1000).map { $0 }
                    }
                }
                existing.lastUpdated = fresh.lastUpdated
                data = existing
            } else {
                var d = fresh
                d.devices.sort { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
                data = d
            }
            error = nil
            refreshError = nil
            if !isLive { connectionStatus = .polling }
            lastUpdate = Date()
        } catch {
            if data == nil {
                if initial { self.error = error.localizedDescription; connectionStatus = .error }
            } else {
                refreshError = error.localizedDescription
            }
        }
        loading = false
    }

    /// Open the Web PubSub event stream like the web dashboard: negotiate a
    /// token, listen, reconnect with exponential backoff up to five times,
    /// then settle on polling. Polling keeps running underneath either way so
    /// the device and install widgets stay fresh.
    func startLive(api: ReportMateAPI) {
        liveTask?.cancel()
        reconnectAttempts = 0
        liveTask = Task { [weak self] in await self?.runLive(api: api) }
    }

    func stopLive() {
        liveTask?.cancel()
        liveTask = nil
    }

    private func runLive(api: ReportMateAPI) async {
        while !Task.isCancelled {
            let negotiated: NegotiateResult
            do {
                negotiated = try await withThrowingTaskGroup(of: NegotiateResult.self) { group in
                    group.addTask { try await api.negotiate() }
                    group.addTask { try await Task.sleep(for: .seconds(10)); throw CancellationError() }
                    let first = try await group.next()!
                    group.cancelAll()
                    return first
                }
            } catch { settle(); return }
            guard negotiated.error == nil, let url = negotiated.url else { settle(); return }
            do {
                for try await frame in LiveEventStream.frames(url: url) {
                    switch frame {
                    case .open:
                        connectionStatus = .connected
                        reconnectAttempts = 0
                        lastUpdate = Date()
                    case .event(let event):
                        insert(event)
                    }
                }
            } catch {
                // Closed: fall through to the reconnect ladder.
            }
            if Task.isCancelled { return }
            guard reconnectAttempts < Self.maxReconnectAttempts else { settle(); return }
            let delay = min(pow(2.0, Double(reconnectAttempts)), 30)
            reconnectAttempts += 1
            connectionStatus = .reconnecting
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func settle() {
        if connectionStatus != .error { connectionStatus = .polling }
    }

    private func insert(_ event: FleetEvent) {
        guard var existing = data else { return }
        guard !existing.events.contains(where: { $0.id == event.id }) else { return }
        existing.events = ([event] + existing.events).prefix(1000).map { $0 }
        data = existing
        lastUpdate = Date()
    }
}

struct DashboardView: View {
    @Environment(AppState.self) private var appState
    /// Kept by `AppState` across navigation: a return shows the last data at once.
    private var model: DashboardModel { appState.pages.dashboard }
    private var insights: DashboardInsightsModel { appState.pages.insights }
    /// Width inside the page padding; drives the switch between layouts.
    private var contentWidth: CGFloat { appState.pages.dashboardWidth }
    /// Draw only the skeleton layout and load nothing: shown while the connection settles.
    var placeholder = false

    /// Content width at which the dashboard goes to three columns, with insight
    /// cards 5–12 in a grid underneath. The web app's matching switch is 1680 px.
    static let desktopBreakpoint: CGFloat = 1500
    /// Content width (a 27-inch display) at which the insight cards take two
    /// columns of their own, dealt alternately. The web app's switch is 2200 px.
    static let wideBreakpoint: CGFloat = 2000
    /// Column 1 and each insight column never go narrower than this.
    static let columnMinimum: CGFloat = 360
    /// Column 2, under New Clients, and column 3, by API key (revision 5 of the spec).
    /// Narrower tiers flow the same order into fewer columns: column 2's cards, then
    /// column 3's. Installs, Management Tools Logs and Check-in Gaps sit in column 1.
    static let column2 = ["directoryServices", "connectivityProblems", "protectionGaps", "expiringCertificates"]
    static let column3 = ["updateDebt", "storage", "appUsage", "softwareRisk", "rebootDebt"]

    private var devices: [DeviceSummary] {
        guard let all = model.data?.devices else { return [] }
        if appState.platformFilter == .all { return all }
        return all.filter { appState.platformFilter.includes($0.platform) }
    }

    private var events: [FleetEvent] {
        guard let all = model.data?.events else { return [] }
        if appState.platformFilter == .all { return all }
        return all.filter { appState.platformFilter.includes($0.platform) }
    }

    var body: some View {
        Group {
            if let error = model.error, model.data == nil {
                ErrorBanner(message: error) { Task { await model.load(api: appState.api, includeArchived: appState.includeArchived, initial: true) } }
                    .padding()
                Spacer()
            } else {
                VStack(spacing: 0) {
                    if let failure = model.refreshError ?? (insights.hasData ? insights.error : nil) {
                        RefreshFailedBanner(message: failure, updatedAt: model.lastUpdate) {
                            Task { await model.load(api: appState.api, includeArchived: appState.includeArchived, initial: false) }
                            Task { await loadInsights(force: true) }
                        }
                    }
                    ScrollView {
                        layout.padding(20)
                    }
                    .overlay(alignment: .top) { progressBar }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width - 40 } action: { appState.pages.dashboardWidth = $0 }
            }
        }
        .navigationTitle("ReportMate")
        .task(id: appState.configuration) {
            guard !placeholder else { return }
            model.startLive(api: appState.api)
            defer { model.stopLive() }
            await model.load(api: appState.api, includeArchived: appState.includeArchived, initial: true)
            Task { await loadInsights() }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                await model.load(api: appState.api, includeArchived: appState.includeArchived, initial: false)
                await loadInsights()
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                model.clockTick += 1
            }
        }
        .onChange(of: appState.platformFilter) { _, _ in Task { await loadInsights() } }
        .environment(insights)
        .environment(\.insightsRetry) { Task { await loadInsights(force: true) } }
        .onChange(of: appState.refreshRequested) { _, _ in
            guard !placeholder else { return }
            Task { await model.load(api: appState.api, includeArchived: appState.includeArchived, initial: model.data == nil) }
            Task { await loadInsights(force: true) }
        }
    }

    /// A sweep until the dashboard payload lands, then "Loading n of 12" as the cards answer; a sweep marked Updating while kept data refreshes.
    @ViewBuilder
    private var progressBar: some View {
        let total = DashboardInsightsModel.cardCount
        if placeholder || model.data == nil, model.error == nil {
            LoadProgressBar()
        } else if insights.loading, insights.answered < total, insights.error == nil {
            LoadProgressBar(loaded: insights.answered, total: total)
        } else if model.refreshing || insights.loading {
            LoadProgressBar(updating: true)
        }
    }

    // MARK: Layouts

    @ViewBuilder
    private var layout: some View {
        if contentWidth >= Self.wideBreakpoint {
            // Wide (27-inch class): fleet status, two insight columns dealt
            // alternately so both grow evenly, then events and charts at double width.
            let unit = max(Self.columnMinimum, (contentWidth - 60) / 5)
            HStack(alignment: .top, spacing: 20) {
                // Cards size to their content rather than to the tallest column.
                statusColumn.frame(width: unit).fixedSize(horizontal: false, vertical: true)
                insightStack(Self.column2, newClients: true).frame(width: unit).fixedSize(horizontal: false, vertical: true)
                insightStack(Self.column3).frame(width: unit).fixedSize(horizontal: false, vertical: true)
                activityColumn.frame(maxWidth: .infinity)
            }
        } else if contentWidth >= Self.desktopBreakpoint {
            // Desktop: fleet status, the first four insights, events and charts;
            // cards 5–12 four across underneath.
            let unit = max(Self.columnMinimum, (contentWidth - 40) / 4)
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 20) {
                    statusColumn.frame(width: unit).fixedSize(horizontal: false, vertical: true)
                    insightStack(Self.column2, newClients: true).frame(width: unit).fixedSize(horizontal: false, vertical: true)
                    activityColumn.frame(maxWidth: .infinity)
                }
                insightGrid(Self.column3, maxColumns: 4)
            }
        } else {
            VStack(alignment: .leading, spacing: 20) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        VStack(spacing: 20) { statusColumn; newClientsCard }.frame(width: Self.columnMinimum)
                        activityColumn
                    }
                    VStack(spacing: 20) {
                        statusColumn
                        newClientsCard
                        activityColumn
                    }
                }
                insightGrid(Self.column2 + Self.column3, maxColumns: 2)
            }
        }
    }

    private func reloadDashboard() {
        Task { await model.load(api: appState.api, includeArchived: appState.includeArchived, initial: true) }
    }

    /// Until the dashboard payload arrives the columns draw as skeletons in the same layout.
    private var awaitingData: Bool { placeholder || model.data == nil }

    private var statusColumn: some View {
        Group {
            if awaitingData {
                DashboardStatusSkeleton().skeletonTimeout(retry: reloadDashboard)
            } else {
                VStack(spacing: 20) {
                    StatusWidget(devices: devices)
                    InstallHealthCard(stats: model.data?.installStats, platform: appState.platformFilter)
                    card("managementToolLogs")
                    card("checkinGaps")
                }
            }
        }
    }

    private var activityColumn: some View {
        Group {
            if awaitingData {
                DashboardActivitySkeleton().skeletonTimeout(retry: reloadDashboard)
            } else {
                VStack(spacing: 20) {
                    RecentEventsWidget(events: events, connectionStatus: model.connectionStatus, lastUpdate: model.lastUpdate)
                    PlatformDistributionWidget(devices: devices)
                    osVersionRow
                }
            }
        }
    }

    private func insightStack(_ cards: [String], newClients: Bool = false) -> some View {
        VStack(spacing: 20) {
            if newClients { newClientsCard }
            ForEach(cards, id: \.self) { card($0) }
        }
    }

    @ViewBuilder
    private var newClientsCard: some View {
        if awaitingData {
            SkeletonCard { SkeletonRows(count: 6) }.skeletonTimeout(retry: reloadDashboard)
        } else {
            NewClientsWidget(devices: devices)
        }
    }

    private func insightGrid(_ cards: [String], maxColumns: Int) -> some View {
        UniformGrid(minColumnWidth: 320, maxColumns: maxColumns, spacing: 20, fillsHeight: false) {
            ForEach(cards, id: \.self) { card($0) }
        }
    }

    // MARK: Insight cards

    /// One request for every card, cached by the API for five minutes and asked again
    /// here at most that often (the 30-second tick finds it fresh).
    private func loadInsights(force: Bool = false) async {
        guard !placeholder, appState.isConfigured else { return }
        async let cards: Void = insights.load(api: appState.api, platform: appState.platformFilter, includeArchived: appState.includeArchived, force: force)
        async let usage: Void = insights.loadAppUsage(api: appState.api, platform: appState.platformFilter, force: force)
        _ = await (cards, usage)
    }

    private func card(_ key: String) -> some View {
        InsightCardView(key: key, platform: appState.platformFilter)
    }

    @ViewBuilder
    private var osVersionRow: some View {
        let showMac = appState.platformFilter != .windows
        let showWin = appState.platformFilter != .macOS
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                if showMac { OSVersionWidget(devices: devices, platform: .macOS) }
                if showWin { OSVersionWidget(devices: devices, platform: .windows) }
            }
            VStack(spacing: 16) {
                if showMac { OSVersionWidget(devices: devices, platform: .macOS) }
                if showWin { OSVersionWidget(devices: devices, platform: .windows) }
            }
        }
    }
}

// MARK: - Fleet status donut

struct StatusWidget: View {
    @Environment(AppState.self) private var appState
    let devices: [DeviceSummary]

    private var slices: [FleetStats.StatusSlice] { FleetStats.statusDistribution(devices) }

    var body: some View {
        Card {
            VStack(spacing: 0) {
                CardHeader("Fleet Status", subtitle: "Click to view all devices", systemImage: "laptopcomputer", tone: .blue) {
                    appState.follow(DashboardLinks.devices())
                }
                .linkContextMenu(DashboardLinks.devices())
                if devices.isEmpty {
                    EmptyStateView(title: "No devices found", message: "Devices will appear here when they report in", systemImage: "laptopcomputer")
                } else {
                    VStack(spacing: 18) {
                        ZStack {
                            Chart(slices) { slice in
                                SectorMark(angle: .value("Devices", slice.count), innerRadius: .ratio(0.62), angularInset: 1)
                                    .foregroundStyle(Color(hex: slice.status.chartColorHex))
                            }
                            .chartLegend(.hidden)
                            .frame(width: 190, height: 190)
                            VStack(spacing: 0) {
                                Text("\(devices.count)").appFont(.title, weight: .bold).monospacedDigit()
                                Text(devices.count == 1 ? "Device" : "Devices").appFont(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { appState.follow(DashboardLinks.devices()) }
                        .linkContextMenu(DashboardLinks.devices())
                        VStack(spacing: 4) {
                            ForEach(slices) { slice in
                                InsightLink(link: DashboardLinks.devices(status: slice.status)) {
                                    HStack {
                                        Circle().fill(Color(hex: slice.status.chartColorHex)).frame(width: 12, height: 12)
                                        Text(slice.status.displayName).appFont(.callout, weight: .medium)
                                        Spacer()
                                        Text("\(slice.count)").appFont(.callout).foregroundStyle(.secondary).monospacedDigit()
                                        Text("\(slice.percentage)%").appFont(.caption).foregroundStyle(.tertiary).monospacedDigit().frame(width: 40, alignment: .trailing)
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}

extension Notification.Name {
    static let devicesStatusFilter = Notification.Name("ReportMate.devicesStatusFilter")
}

extension Notification.Name {
    static let installsFilter = Notification.Name("ReportMate.installsFilter")
}

// MARK: - New clients

struct NewClientsWidget: View {
    @Environment(AppState.self) private var appState
    let devices: [DeviceSummary]

    private var newDevices: [DeviceSummary] { FleetStats.newClients(devices) }

    var body: some View {
        Card {
            VStack(spacing: 0) {
                CardHeader("New Clients", subtitle: "Registered in the last 7 days") { appState.follow(DashboardLinks.devices()) }
                    .linkContextMenu(DashboardLinks.devices())
                if newDevices.isEmpty {
                    EmptyStateView(title: "No new clients", message: "No devices registered in the last 7 days", systemImage: "laptopcomputer")
                        .frame(minHeight: 200)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(newDevices.prefix(10)) { device in
                                Button { appState.open(device: device.serialNumber) } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(device.name).appFont(.body, weight: .medium).lineLimit(1)
                                            Spacer()
                                            PlatformBadge(platform: device.platform)
                                        }
                                        Text(device.identifierLine).appFont(.caption).foregroundStyle(.secondary)
                                        Text("Registered: \(TimeFormatting.relative(device.createdAt))").appFont(.caption2).foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 16).padding(.vertical, 10)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                    .frame(maxHeight: 560)
                }
            }
        }
    }
}

// MARK: - Platform distribution

struct PlatformDistributionWidget: View {
    @Environment(AppState.self) private var appState
    let devices: [DeviceSummary]
    @State private var filters = FleetStats.DistributionFilters()
    @State private var expanded: String?

    private var stats: [FleetStats.PlatformStats] { FleetStats.platformDistribution(devices, filters: filters) }
    private var available: FleetStats.AvailableFilters { FleetStats.availableFilters(devices) }

    var body: some View {
        Card {
            VStack(spacing: 0) {
                CardHeader("Platform Distribution", systemImage: "laptopcomputer", tone: .purple) { appState.follow(DashboardLinks.devices()) }
                    .linkContextMenu(DashboardLinks.devices())
                VStack(alignment: .leading, spacing: 10) {
                    if devices.isEmpty {
                        EmptyStateView(title: "No devices found", message: "Platform distribution will appear when devices are detected")
                    } else if stats.count == 1, let single = stats.first {
                        singlePlatform(single)
                    } else {
                        ForEach(stats) { s in platformCard(s) }
                    }
                    filterPills
                }
                .padding(16)
            }
        }
    }

    private func platformCard(_ s: FleetStats.PlatformStats) -> some View {
        let isOpen = expanded == s.platform.rawValue
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { withAnimation(.easeInOut(duration: 0.15)) { expanded = isOpen ? nil : s.platform.rawValue } } label: {
                    HStack(spacing: 12) {
                        Image(systemName: s.platform.systemImage).appFont(fixed: 22).foregroundStyle(.secondary).frame(width: 28)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(s.platform.chartLabel).appFont(.headline)
                                Text("\(s.percentage)%").appFont(.callout).foregroundStyle(.secondary)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.secondary.opacity(0.12))
                                    Capsule().fill(Color.purple.opacity(0.8)).frame(width: geo.size.width * CGFloat(s.percentage) / 100)
                                }
                            }
                            .frame(height: 8)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(s.platform.chartLabel), \(isOpen ? "collapse" : "expand") details")
                InsightLink(link: devicesLink(s.platform)) {
                    Text("\(s.count)").appFont(.title3, weight: .semibold).monospacedDigit()
                }
                Button { withAnimation(.easeInOut(duration: 0.15)) { expanded = isOpen ? nil : s.platform.rawValue } } label: {
                    Image(systemName: "chevron.down").rotationEffect(.degrees(isOpen ? 180 : 0)).foregroundStyle(.secondary).appFont(.caption)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isOpen ? "Collapse" : "Expand")
            }
            .padding(12)
            if isOpen {
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    drill("Architecture", s.architectures, total: s.count) { archLink(s.platform, $0) }
                    drill("Usage", s.usages, total: s.count) { devicesLink(s.platform, ["usage": $0]) }
                    drill("Catalog", s.catalogs, total: s.count) { devicesLink(s.platform, ["catalog": $0]) }
                    drill("Department", s.departments, total: s.count) { devicesLink(s.platform, ["area": $0]) }
                    ageLine(s.ageStats)
                }
                .padding(12)
                .background(Color.subtleBackground)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.cardBorder))
    }

    private func singlePlatform(_ platform: FleetStats.PlatformStats) -> some View {
        let usages = FleetStats.usageDistribution(devices, filters: filters)
        let known = usages.filter { $0.usage != "Unknown" }
        let unknown = usages.filter { $0.usage == "Unknown" }.reduce(0) { $0 + $1.count }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: platform.platform.systemImage).foregroundStyle(.secondary)
                Text("\(platform.platform.chartLabel) — \(platform.count) \(platform.count == 1 ? "device" : "devices") — by Usage").appFont(.callout, weight: .medium).foregroundStyle(.secondary)
                Spacer()
                if unknown > 0 { Text("\(unknown) unknown").appFont(.caption).foregroundStyle(.tertiary) }
            }
            ForEach(known) { u in
                let isOpen = expanded == "usage:\(u.usage)"
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Button { withAnimation(.easeInOut(duration: 0.15)) { expanded = isOpen ? nil : "usage:\(u.usage)" } } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(u.usage).appFont(.headline)
                                    Text("\(u.percentage)%").appFont(.callout).foregroundStyle(.secondary)
                                }
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.secondary.opacity(0.12))
                                        Capsule().fill(Color.purple.opacity(0.8)).frame(width: geo.size.width * CGFloat(u.percentage) / 100)
                                    }
                                }
                                .frame(height: 8)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        InsightLink(link: devicesLink(platform.platform, ["usage": u.usage])) {
                            Text("\(u.count)").appFont(.title3, weight: .semibold).monospacedDigit()
                        }
                        Button { withAnimation(.easeInOut(duration: 0.15)) { expanded = isOpen ? nil : "usage:\(u.usage)" } } label: {
                            Image(systemName: "chevron.down").rotationEffect(.degrees(isOpen ? 180 : 0)).foregroundStyle(.secondary).appFont(.caption)
                                .frame(width: 20, height: 20).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isOpen ? "Collapse" : "Expand")
                    }
                    .padding(12)
                    if isOpen {
                        Divider()
                        VStack(alignment: .leading, spacing: 12) {
                            drill("Architecture", u.architectures, total: u.count) { archLink(platform.platform, $0) }
                            drill("Catalog", u.catalogs, total: u.count) { devicesLink(platform.platform, ["usage": u.usage, "catalog": $0]) }
                            drill("Department", u.departments, total: u.count) { devicesLink(platform.platform, ["usage": u.usage, "area": $0]) }
                        }
                        .padding(12).background(Color.subtleBackground)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.cardBorder))
            }
        }
    }

    @ViewBuilder
    private func drill(_ title: String, _ data: [String: Int], total: Int, link: @escaping (String) -> DeepLink?) -> some View {
        if !data.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel(title)
                ForEach(data.sorted { $0.value > $1.value }, id: \.key) { entry in
                    if let target = link(entry.key) {
                        InsightLink(link: target) { BarRow(label: entry.key, count: entry.value, total: total) }
                    } else {
                        BarRow(label: entry.key, count: entry.value, total: total).padding(.horizontal, 4)
                    }
                }
            }
        }
    }

    /// `/devices` for one platform, with the widget's own usage and catalog pills carried along.
    private func devicesLink(_ platform: Platform, _ extra: [String: String] = [:]) -> DeepLink {
        var q: [String: String] = [:]
        if let u = filters.usage.first { q["usage"] = u }
        if let c = filters.catalog.first { q["catalog"] = c }
        switch platform {
        case .macOS: q["platform"] = "mac"
        case .windows: q["platform"] = "win"
        default: break
        }
        q.merge(extra) { _, new in new }
        return DashboardLinks.devices(q)
    }

    /// An architecture row opens the Hardware report on its family: arm64 on a Mac is Apple Silicon.
    private func archLink(_ platform: Platform, _ arch: String) -> DeepLink? {
        let a = arch.lowercased()
        let family: String
        switch (platform, a) {
        case (.macOS, "arm64"): family = "Apple Silicon"
        case (.macOS, "x64"), (.macOS, "x86"): family = "Intel"
        case (.windows, "arm64"): family = "ARM64"
        case (.windows, "x64"), (.windows, "x86"): family = "x64"
        default: return nil
        }
        var q = ["arch": family]
        q["platform"] = platform == .macOS ? "mac" : "win"
        return DashboardLinks.report("hardware", q)
    }

    @ViewBuilder
    private func ageLine(_ age: FleetStats.AgeStats) -> some View {
        if age.devicesWithAge > 0 {
            HStack(spacing: 12) {
                SectionLabel("Fleet age")
                Text("avg \(Int(age.averageAgeDays.rounded())) days").appFont(.caption)
                if let n = age.newest { Text("newest \(TimeFormatting.shortDate(n))").appFont(.caption).foregroundStyle(.secondary) }
                if let o = age.oldest { Text("oldest \(TimeFormatting.shortDate(o))").appFont(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder
    private var filterPills: some View {
        let single = stats.count == 1
        if !available.usages.isEmpty || !available.catalogs.isEmpty || !available.architectures.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !single, !available.usages.isEmpty {
                    pillRow("Usage", available.usages.prefix(6).map { $0 }, selected: filters.usage, tone: .purple) { toggle(&filters.usage, $0) }
                }
                if !available.catalogs.isEmpty {
                    pillRow("Catalog", available.catalogs.prefix(6).map { $0 }, selected: filters.catalog, tone: .green) { toggle(&filters.catalog, $0) }
                }
                if !available.architectures.isEmpty {
                    pillRow("Arch", available.architectures, selected: filters.architecture, tone: .blue) { toggle(&filters.architecture, $0) }
                }
                if !filters.isEmpty {
                    Button("Clear filters") { filters = FleetStats.DistributionFilters() }.buttonStyle(.link).appFont(.caption)
                }
            }
            .padding(.top, 4)
        }
    }

    private func pillRow(_ label: String, _ values: [String], selected: Set<String>, tone: Tone, toggle: @escaping (String) -> Void) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label.uppercased()).appFont(.caption2).foregroundStyle(.tertiary).frame(width: 52, alignment: .leading).padding(.top, 4)
            FlowLayout(spacing: 4) {
                ForEach(values, id: \.self) { v in
                    FilterPill(text: v, selected: selected.contains(v), tone: tone, size: 10) { toggle(v) }
                }
            }
        }
    }

    private func toggle(_ set: inout Set<String>, _ value: String) {
        // The web widget keeps a single selection per dimension.
        if set.contains(value) { set = [] } else { set = [value] }
    }
}

// MARK: - OS versions

struct OSVersionWidget: View {
    @Environment(AppState.self) private var appState
    let devices: [DeviceSummary]
    let platform: Platform
    @State private var selectedGroup: String?
    @State private var hovered: String?

    private var nodes: [FleetStats.VersionNode] { FleetStats.osVersions(devices, platform: platform) }

    private var visible: [FleetStats.VersionNode] {
        if let selectedGroup, let g = nodes.first(where: { $0.name == selectedGroup }) { return g.children }
        return nodes
    }

    private var total: Int {
        if let selectedGroup, let g = nodes.first(where: { $0.name == selectedGroup }) { return g.count }
        return nodes.reduce(0) { $0 + $1.count }
    }

    var body: some View {
        Card {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill((platform == .macOS ? Color.red : Color.blue).opacity(0.15))
                        Image(systemName: platform.systemImage).foregroundStyle(platform == .macOS ? Color.red : Color.blue).appFont(fixed: 14)
                    }
                    .frame(width: 30, height: 30)
                    Text("\(platform.displayName) Versions").appFont(.headline)
                        .onTapGesture { appState.follow(DashboardLinks.system()) }
                        .linkContextMenu(DashboardLinks.system())
                        .help("Show the System report")
                    Spacer()
                    if selectedGroup != nil {
                        Button { withAnimation { selectedGroup = nil } } label: { Label("All versions", systemImage: "chevron.left").appFont(.caption) }
                            .buttonStyle(.link)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .overlay(alignment: .bottom) { Divider() }

                if nodes.isEmpty {
                    Text("No \(platform.displayName) devices found").appFont(.callout).foregroundStyle(.secondary).padding(16)
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        Chart(visible) { node in
                            SectorMark(angle: .value("Devices", node.count), innerRadius: .ratio(0.64), angularInset: 1.5)
                                .foregroundStyle(OSVersionWidget.temperatureColor(index: node.index, total: node.siblingCount, lighten: selectedGroup != nil))
                                .opacity(hovered == nil || hovered == node.name ? 1 : 0.4)
                        }
                        .chartLegend(.hidden)
                        .frame(width: 150, height: 150)
                        ScrollView {
                            VStack(spacing: 3) {
                                ForEach(visible) { node in
                                    let maxCount = max(visible.map(\.count).max() ?? 1, 1)
                                    let pct = total > 0 ? Int((Double(node.count) / Double(total) * 100).rounded()) : 0
                                    HStack(spacing: 2) {
                                    Button { appState.follow(DashboardLinks.system(osVersion: node.name)) } label: {
                                        HStack(spacing: 8) {
                                            Text(node.displayName).appFont(.caption, weight: .medium).monospacedDigit().frame(minWidth: 52, alignment: .leading)
                                            GeometryReader { geo in
                                                ZStack(alignment: .leading) {
                                                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12))
                                                    RoundedRectangle(cornerRadius: 4)
                                                        .fill(OSVersionWidget.temperatureColor(index: node.index, total: node.siblingCount, lighten: selectedGroup != nil))
                                                        .frame(width: max(24, geo.size.width * max(CGFloat(node.count) / CGFloat(maxCount), 0.15)))
                                                        .overlay(alignment: .trailing) {
                                                            Text("\(node.count)").appFont(fixed: 10, weight: .medium).foregroundStyle(.white).padding(.trailing, 4)
                                                        }
                                                }
                                            }
                                            .frame(height: 20)
                                            Text("\(pct)%").appFont(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 36, alignment: .trailing)
                                        }
                                        .padding(.horizontal, 4).padding(.vertical, 2)
                                        .background(hovered == node.name ? Color.subtleBackground : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .onHover { hovered = $0 ? node.name : nil }
                                    .help(appState.describe(DashboardLinks.system(osVersion: node.name)))
                                    .linkContextMenu(DashboardLinks.system(osVersion: node.name))
                                    if selectedGroup == nil, !node.children.isEmpty {
                                        Button { withAnimation { selectedGroup = node.name } } label: {
                                            Image(systemName: "chevron.right").appFont(.caption2).foregroundStyle(.secondary).frame(width: 16, height: 20).contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .help("Show \(node.displayName) patch versions")
                                        .accessibilityLabel("Show \(node.displayName) patch versions")
                                    }
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 190)
                    }
                    .padding(14)
                }
            }
        }
    }

    /// Green (newest) through yellow and orange to red (oldest).
    static func temperatureColor(index: Int, total: Int, lighten: Bool) -> Color {
        guard total > 1 else { return lighten ? Color(hex: "#34d399") : Color(hex: "#10B981") }
        let ratio = Double(index) / Double(total - 1)
        let stops: [(Double, Double, Double)] = [(16, 185, 129), (132, 204, 22), (234, 179, 8), (249, 115, 22), (239, 68, 68)]
        let segment = ratio * Double(stops.count - 1)
        let start = Int(segment)
        let end = min(start + 1, stops.count - 1)
        let t = segment - Double(start)
        var r = stops[start].0 + (stops[end].0 - stops[start].0) * t
        var g = stops[start].1 + (stops[end].1 - stops[start].1) * t
        var b = stops[start].2 + (stops[end].2 - stops[start].2) * t
        if lighten {
            let amt = 2.55 * Double(5 + index * 10)
            r = min(255, r + amt); g = min(255, g + amt); b = min(255, b + amt)
        }
        return Color(red: r / 255, green: g / 255, blue: b / 255)
    }
}

extension Notification.Name {
    static let systemVersionFilter = Notification.Name("ReportMate.systemVersionFilter")
}
