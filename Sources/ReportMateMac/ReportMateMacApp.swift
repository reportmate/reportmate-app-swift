import SwiftUI
import ReportMateUI

@main
struct ReportMateMacApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        // One window with many sections, not a document app: hide the tab bar items.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        ReportMateScenes()
    }
}
