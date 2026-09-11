import SwiftUI
import ReportMateKit

@main
struct ReportMateMacApp: App {
    @State private var appState = AppState()
    @State private var kiosk = KioskController()
    @AppStorage(AppFontScale.storageKey) private var fontScale: Double = AppFontScale.default
    @AppStorage(AppAppearance.storageKey) private var appearance: String = AppAppearance.system.rawValue

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        // One window with many sections, not a document app: hide the tab bar items.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(kiosk)
                .appFontScale(kiosk.fontScale ?? fontScale)
                .preferredColorScheme(kiosk.enabled ? kiosk.colorScheme : AppAppearance(rawValue: appearance)?.colorScheme)
                .frame(minWidth: 960, minHeight: 620)
                // The web app is blue throughout (links are blue-600); pin the accent so
                // device links and controls do not follow the Mac's accent colour setting.
                .tint(.blue)
                // A reportmate:// link lands in the window that is already open.
                // Without this a WindowGroup answers every external URL with a
                // new window, so each link opened another copy of the app.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 1380, height: 900)
        .commands {
            AppCommands(kiosk: kiosk)
        }

        Settings {
            SettingsView()
                .environment(appState)
                .environment(kiosk)
                .appFontScale(fontScale)
                .preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
        }
    }
}

/// Menu bar commands: section switching, search, refresh, back/forward.
struct AppCommands: Commands {
    @FocusedValue(\.appState) private var appState
    @Bindable var kiosk: KioskController

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandMenu("Go") {
            ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
                Button(section.title) { appState?.navigate(to: section) }
                    .keyboardShortcut(section.keyEquivalent, modifiers: .command)
            }
            Divider()
            Button("Back") { appState?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!(appState?.canGoBack ?? false))
        }
        CommandGroup(after: .toolbar) {
            Button("Find Device…") { appState?.showSearch = true }
                .keyboardShortcut("k", modifiers: .command)
            Button("Refresh") { appState?.refreshRequested += 1 }
                .keyboardShortcut("r", modifiers: .command)
            Button("Copy Link") {
                guard let appState else { return }
                let link = appState.currentDeepLink
                let text = appState.configuration.normalizedWebURL.flatMap { link.handoffURL(webBase: $0)?.absoluteString } ?? link.url.absoluteString
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            Divider()
            Button("Show All Platforms") { appState?.platformFilter = .all }
                .keyboardShortcut("0", modifiers: [.command, .shift])
            Button("Show macOS Only") { appState?.platformFilter = .macOS }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Show Windows Only") { appState?.platformFilter = .windows }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            Divider()
            Toggle("Kiosk Mode", isOn: Binding(get: { kiosk.enabled }, set: { kiosk.setEnabled($0) }))
                .keyboardShortcut("k", modifiers: [.command, .control])
        }
    }
}

struct AppStateFocusedKey: FocusedValueKey {
    typealias Value = AppState
}

extension FocusedValues {
    var appState: AppState? {
        get { self[AppStateFocusedKey.self] }
        set { self[AppStateFocusedKey.self] = newValue }
    }
}
