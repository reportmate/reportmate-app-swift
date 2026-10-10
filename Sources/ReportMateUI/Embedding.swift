import SwiftUI
import ReportMateKit

/// One dashboard hosted inside another SwiftUI app's window.
///
/// The host keeps the session alive for as long as it shows the dashboard, so
/// the page, filters and loaded devices survive switching away and back:
///
///     @State private var reports = ReportMateSession()
///     ReportMateDashboard(session: reports)
///
/// The window toolbar stays the host's: the dashboard draws its own controls in
/// a header row, and Settings opens as a sheet. Links reach it through `open`.
/// A host whose window already has a search field passes `.hostProvided`
/// chrome and feeds its field into `deviceSearch`.
@MainActor
@Observable
public final class ReportMateSession {
    let appState: AppState
    let kiosk = KioskController()

    /// `configuration` replaces the saved connection for this session (an API URL
    /// and credential the host already holds); nil uses the dashboard's own
    /// saved settings, exactly as the standalone app does.
    public init(configuration: AppConfiguration? = nil, chrome: ReportMateChrome = .standard) {
        appState = AppState(configuration: configuration, embedded: true)
        appState.chrome = chrome
    }

    /// Which of its own controls the dashboard draws.
    public var chrome: ReportMateChrome {
        get { appState.chrome }
        set { appState.chrome = newValue }
    }

    /// The device query from the host's own search field, for a host that hides
    /// the dashboard's field. Any text shows the Devices list filtered by it;
    /// an empty string clears the filter and leaves the page where it is.
    public var deviceSearch: String {
        get { appState.hostSearchQuery }
        set { appState.searchDevices(newValue) }
    }

    /// Open the device that best matches `deviceSearch` (the host's Return key).
    /// Returns false, leaving the filtered list on screen, when nothing matches.
    @discardableResult
    public func openBestDeviceMatch() -> Bool {
        appState.openBestDeviceMatch()
    }

    /// Show the dashboard's Settings, as a sheet over it.
    public func showSettings() {
        appState.settingsSheetShown = true
    }

    /// The connection in use.
    public var configuration: AppConfiguration { appState.configuration }

    /// Whether an API URL and credential are set.
    public var isConfigured: Bool { appState.isConfigured }

    /// Follow a dashboard link: a `reportmate://` URL or a web dashboard URL.
    @discardableResult
    public func open(url: URL) -> Bool {
        guard let link = DeepLink(url: url) else { return false }
        appState.open(deepLink: link)
        return true
    }

    /// Follow a parsed dashboard link.
    public func open(_ link: DeepLink) {
        appState.open(deepLink: link)
    }

    /// Open one device's page by serial number.
    public func openDevice(serial: String) {
        appState.open(device: serial)
    }

    /// The fleet device list as last loaded, empty until the first load.
    public var devices: [DeviceSummary] { appState.devices }

    /// When the device list was last loaded, nil before the first load.
    public var devicesLoadedAt: Date? { appState.devicesLoadedAt }

    /// Load the device list, reusing a copy under five minutes old unless
    /// `force` is set. The dashboard shares the same list, so a host that loads
    /// it early (to search it, say) saves the Devices page a fetch.
    public func loadDevices(force: Bool = false) async {
        guard isConfigured else { return }
        await appState.loadDevices(force: force)
    }

    /// Reload the page on screen.
    public func refresh() {
        appState.refreshRequested += 1
    }
}

/// The controls an embedded dashboard draws above its pages. The standalone
/// app always draws everything in its window toolbar and ignores this.
public struct ReportMateChrome: Equatable, Sendable {
    /// The dashboard's own device search field. Off when the host window already
    /// has one and routes its text in through `ReportMateSession.deviceSearch`;
    /// the Devices page then drops its list filter field as well.
    public var showsSearchField: Bool
    /// Back, platform filter, section tabs and the link, refresh and Settings
    /// buttons on one row, the tabs folding into a Reports menu only when the
    /// row is too narrow for them. Off draws the controls and the tabs as two rows.
    public var singleRow: Bool

    public init(showsSearchField: Bool = true, singleRow: Bool = false) {
        self.showsSearchField = showsSearchField
        self.singleRow = singleRow
    }

    /// The dashboard's full header: search field, controls, then a row of tabs.
    public static let standard = ReportMateChrome()

    /// For a host that supplies search and wants the least vertical space: one
    /// row, no search field of the dashboard's own.
    public static let hostProvided = ReportMateChrome(showsSearchField: false, singleRow: true)
}

/// The whole dashboard as a view, for embedding in another app's window.
public struct ReportMateDashboard: View {
    private let session: ReportMateSession
    @AppStorage(AppFontScale.storageKey) private var fontScale: Double = AppFontScale.default

    public init(session: ReportMateSession) {
        self.session = session
    }

    public var body: some View {
        ContentView()
            .environment(session.appState)
            .environment(session.kiosk)
            .appFontScale(fontScale)
            .tint(.blue)
    }
}
