import SwiftUI
import AppKit
import ReportMateKit

/// Runs this Mac as a kiosk display, the way the web app treats a viewer
/// session: full screen, the zoom and theme from Settings → Kiosk Displays,
/// and a return to the kiosk home page after the configured idle time. The
/// flag persists in the app's defaults (`kiosk.enabled`) so a managed display
/// can be switched on with a configuration profile or `defaults write`.
@MainActor
@Observable
final class KioskController {
    static let storageKey = "kiosk.enabled"

    private(set) var enabled: Bool
    private(set) var settings = KioskSettings()
    private var appState: AppState?
    private var monitor: Any?
    private var idleTask: Task<Void, Never>?
    private var lastActivity = Date()

    init() {
        enabled = UserDefaults.standard.bool(forKey: Self.storageKey)
    }

    /// The zoom from Settings while kiosk mode is on, else nil.
    var fontScale: Double? { enabled ? AppFontScale.clamp(settings.zoom) : nil }

    /// The theme from Settings while kiosk mode is on; nil follows the system.
    var colorScheme: ColorScheme? {
        switch settings.theme {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    func attach(_ appState: AppState) {
        self.appState = appState
        if enabled { start() }
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.storageKey)
        on ? start() : stop()
    }

    /// Re-read the kiosk section after Settings saved it.
    func apply(_ document: SettingsDocument) {
        settings = document.kiosk
    }

    private func start() {
        guard let appState else { return }
        lastActivity = Date()
        Task {
            if let response = try? await appState.api.settings() {
                settings = response.value.kiosk
                appState.settings = response.value
                appState.settingsLoaded = true
            }
            goHome()
        }
        enterFullScreen()
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]) { event in
                MainActor.assumeIsolated { KioskActivity.shared.touch() }
                return event
            }
        }
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled else { return }
                let minutes = self.settings.idleMinutes
                guard minutes > 0 else { continue }
                if Date().timeIntervalSince(KioskActivity.shared.last) >= Double(minutes) * 60 {
                    self.goHome()
                    KioskActivity.shared.touch()
                }
            }
        }
    }

    private func stop() {
        idleTask?.cancel()
        idleTask = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let window = Self.mainWindow, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }

    /// Open the kiosk home page unless it is already on screen.
    func goHome() {
        guard let appState else { return }
        let path = settings.homePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let link = URL(string: "\(DeepLink.scheme)://\(path)").flatMap(DeepLink.init(url:)) ?? DeepLink(target: .dashboard)
        if appState.currentDeepLink.target != link.target || !appState.path.isEmpty {
            appState.open(deepLink: link)
        }
    }

    private func enterFullScreen() {
        guard let window = Self.mainWindow, !window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }

    /// The fleet window: the widest resizable window, which leaves out Settings.
    private static var mainWindow: NSWindow? {
        NSApp.windows
            .filter { $0.isVisible && $0.styleMask.contains(.resizable) && !($0 is NSPanel) }
            .max { $0.frame.width < $1.frame.width }
    }
}

/// Last input on the display; a plain box so the event monitor's non-isolated
/// closure can stamp it without touching the controller.
@MainActor
final class KioskActivity {
    static let shared = KioskActivity()
    private(set) var last = Date()
    func touch() { last = Date() }
}
