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
@MainActor
@Observable
public final class ReportMateSession {
    let appState: AppState
    let kiosk = KioskController()

    /// `configuration` replaces the saved connection for this session (an API URL
    /// and credential the host already holds); nil uses the dashboard's own
    /// saved settings, exactly as the standalone app does.
    public init(configuration: AppConfiguration? = nil) {
        appState = AppState(configuration: configuration, embedded: true)
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

    /// Reload the page on screen.
    public func refresh() {
        appState.refreshRequested += 1
    }
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
