import SwiftUI
import ReportMateKit

/// The window: the web app's header navigation over the current section,
/// with device pages and drill-downs pushed on a navigation stack.
struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings
    @Environment(KioskController.self) private var kiosk
    @State private var searchQuery = ""
    @State private var searchIndex = 0
    @FocusState private var searchFocused: Bool
    @State private var windowWidth: CGFloat = 1400

    var body: some View {
        @Bindable var state = appState
        ZStack(alignment: .top) {
            NavigationStack(path: $state.path) {
                sectionView
                    .navigationDestination(for: Route.self) { route in
                        // Keyed on the route so a link to the same page with another tab
                        // or filter builds a fresh view instead of reusing the one in place.
                        destination(for: route).id(route)
                    }
            }
            // The search results drop down under the toolbar field, like the web header.
            if searchFocused, !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                ToolbarSearchResults(query: $searchQuery, selectedIndex: $searchIndex, focused: $searchFocused)
                    .padding(.top, 6)
                    .zIndex(10)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { appState.goBack() } label: { Image(systemName: "chevron.left") }
                    .help("Back (⌘[)")
                    .disabled(!appState.canGoBack)
            }
            // One row, like the web header: platform toggle on the left, search dead
            // centre, the sections on the right. Fixed items only: a fit-to-width
            // view inside a toolbar item makes the whole toolbar overflow.
            // The dashboard is the app's front door: it carries the app icon and name
            // where the web shows its logo and wordmark.
            if appState.section == .dashboard, appState.path.isEmpty {
                ToolbarItem(placement: .navigation) {
                    Image(nsImage: AppLogo.image).resizable().aspectRatio(contentMode: .fit).frame(height: 24)
                }
            }
            ToolbarItem(placement: .principal) {
                HStack(spacing: 10) {
                    PlatformToggle()
                    ToolbarSearchField(query: $searchQuery, selectedIndex: $searchIndex, focused: $searchFocused)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                TopNavBar(inline: true, compact: windowWidth < 1900)
                CopyLinkMenu()
                Button { appState.refreshRequested += 1 } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh (⌘R)")
                if let problem = appState.authProblem {
                    Button { openSettings() } label: {
                        Label("Authentication", systemImage: "lock.trianglebadge.exclamationmark")
                            .foregroundStyle(.red)
                    }
                    .help(problem)
                }
                Button { openSettings() } label: { Label("Settings", systemImage: "gearshape") }
                    .help("Settings (⌘,)")
            }
        }
        .background(GeometryReader { geo in Color.clear.onAppear { windowWidth = geo.size.width }.onChange(of: geo.size.width) { _, w in windowWidth = w } })
        .focusedSceneValue(\.appState, appState)
        .task { kiosk.attach(appState) }
        .onOpenURL { url in
            if let link = DeepLink(url: url) { appState.open(deepLink: link) }
        }
        // ⌘K (and the Find Device menu item) puts the cursor in the toolbar search.
        .onChange(of: appState.showSearch) { _, wants in
            if wants { searchFocused = true; appState.showSearch = false }
        }
        .task(id: appState.configuration) {
            guard appState.isConfigured else { return }
            await appState.loadSettings()
            await appState.loadDevices()
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .device(let serial, let tab, let filter):
            DeviceDetailView(serial: serial, initialTab: tab, initialFilter: filter)
        case .applicationUsage(let appName, let days, let usages, let catalogs, let locations):
            ApplicationUsageDetailView(appName: appName, initialDays: days, usages: usages, catalogs: catalogs, locations: locations)
        case .applicationCoverage:
            ApplicationCoverageView()
        case .localDevice(let tab, let filter):
            DeviceDetailView(serial: "this-mac", initialTab: tab, initialFilter: filter, isLocal: true)
        }
    }

    @ViewBuilder
    private var sectionView: some View {
        if !appState.isConfigured {
            NotConfiguredView()
        } else {
            switch appState.section {
            case .dashboard: DashboardView()
            case .devices: DevicesView()
            case .events: EventsView()
            case .installs: InstallsReportView()
            case .applications: ApplicationsReportView()
            case .system: SystemReportView()
            case .management: ManagementReportView()
            case .identity: IdentityReportView()
            case .hardware: HardwareReportView()
            case .peripherals: PeripheralsReportView()
            case .security: SecurityReportView()
            case .network: NetworkReportView()
            }
        }
    }
}

/// Mac / Windows toggle in the toolbar; clicking the active one returns to All.
struct PlatformToggle: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 2) {
            toggle(.macOS, image: "apple.logo", help: "macOS only")
            toggle(.windows, image: "square.grid.2x2.fill", help: "Windows only")
        }
        .padding(2)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
    }

    private func toggle(_ filter: PlatformFilter, image: String, help: String) -> some View {
        let active = appState.platformFilter == filter
        return Button {
            appState.platformFilter = active ? .all : filter
        } label: {
            Image(systemName: image)
                .appFont(fixed: 12, weight: .medium)
                .frame(width: 28, height: 20)
                .background(active ? Color.cardBackground : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(active ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(active ? "Showing \(help), click to show all" : "Filter to \(help)")
    }
}

/// Copy Link: the web handoff URL when a web dashboard is configured (it
/// opens the app when installed and the web page otherwise), plus the raw
/// `reportmate://` and web forms.
/// One button: copies the link that opens this exact view in the app and falls
/// back to the web dashboard when a web URL is configured, otherwise the plain
/// app link. No choices to make; the fallback is a Settings concern.
struct CopyLinkMenu: View {
    @Environment(AppState.self) private var appState
    @State private var copied = false

    private var link: DeepLink { appState.currentDeepLink }
    private var webBase: URL? { appState.configuration.normalizedWebURL }

    var body: some View {
        Button {
            if let webBase, let handoff = link.handoffURL(webBase: webBase) { copy(handoff.absoluteString) } else { copy(link.url.absoluteString) }
        } label: {
            Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "link")
        }
        .help("Copy a link to this exact view (⌘⇧C)")
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }
}

/// The bare ReportMate logo artwork (the clipboard on a laptop), as the web
/// header shows it, without the app icon's rounded background.
@MainActor
enum AppLogo {
    static let image: NSImage = {
        if let url = Bundle.main.url(forResource: "reportmate-logo", withExtension: "png"), let image = NSImage(contentsOf: url) { return image }
        return NSApp.applicationIconImage
    }()
}
