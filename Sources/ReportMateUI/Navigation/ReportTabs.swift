import SwiftUI
import ReportMateKit

/// The tabs of each module report, with the web's `?tab=` keys. The first tab,
/// key "", is the module's main report.
enum ReportTabs {
    struct Tab: Hashable, Identifiable {
        let key: String
        let title: String
        var id: String { key }
    }

    static func tabs(for section: AppSection) -> [Tab] {
        switch section {
        case .system:
            return [Tab(key: "", title: "Operating System Information"), Tab(key: "services", title: "Services"), Tab(key: "updates", title: "Updates"),
                    Tab(key: "background", title: "Background Items"), Tab(key: "extensions", title: "Extensions")]
        case .management:
            return [Tab(key: "", title: "Device Management Service"), Tab(key: "profiles", title: "Configuration Profiles"),
                    Tab(key: "preferences", title: "Managed Preferences"), Tab(key: "logs", title: "Management Tools Logs")]
        case .security:
            return [Tab(key: "", title: "Fleet Security"), Tab(key: "vulnerabilities", title: "Vulnerabilities"), Tab(key: "threats", title: "Threat Detections")]
        case .identity:
            return [Tab(key: "", title: "Identity & Users"), Tab(key: "posture", title: "Sign-in & Recovery Posture")]
        default:
            return []
        }
    }

    /// A link's `tab` as this module's key: the web's names for the main tab
    /// (`os`, `enrollment`, `posture` on Security, `users`) and unknown values read as "".
    static func normalized(_ section: AppSection, _ tab: String?) -> String {
        let t = (tab ?? "").lowercased()
        if section == .security, t == "posture" { return "" }
        return tabs(for: section).contains { $0.key == t } ? t : ""
    }

    static func title(_ section: AppSection, _ key: String) -> String {
        tabs(for: section).first { $0.key == key }?.title ?? section.title
    }
}

/// A module report's title: a segmented control between its tabs, as the web
/// draws the title as the switch. Too narrow for the segments, it becomes a menu.
struct ReportTabSwitch: View {
    @Environment(AppState.self) private var appState
    let section: AppSection

    private var selection: Binding<String> {
        Binding(get: { appState.pages.tab(section) }, set: { appState.selectReportTab($0, in: section) })
    }

    var body: some View {
        let tabs = ReportTabs.tabs(for: section)
        ViewThatFits(in: .horizontal) {
            picker(tabs).pickerStyle(.segmented).controlSize(.large)
            picker(tabs).pickerStyle(.menu).controlSize(.large)
        }
        .labelsHidden()
        .fixedSize()
        .help("\(section.title) reports. Switch with Shift-Command-] and Shift-Command-[.")
        .accessibilityLabel("\(section.title) report")
    }

    private func picker(_ tabs: [ReportTabs.Tab]) -> some View {
        Picker(section.title, selection: selection) {
            ForEach(tabs) { Text($0.title).tag($0.key) }
        }
    }
}

/// Routes a module report to the tab chosen in its switch.
struct ModuleReportHost<Main: View>: View {
    @Environment(AppState.self) private var appState
    let section: AppSection
    @ViewBuilder var main: Main

    var body: some View {
        switch (section, appState.pages.tab(section)) {
        case (.system, "services"): ServicesReportPage()
        case (.system, "updates"): UpdatesReportPage()
        case (.system, "background"): ItemReportPage(spec: .background)
        case (.system, "extensions"): ItemReportPage(spec: .extensions)
        case (.management, "profiles"): ProfilesReportPage(kind: .profile)
        case (.management, "preferences"): ProfilesReportPage(kind: .preference)
        case (.management, "logs"): ManagementLogsReportView()
        case (.security, "vulnerabilities"): VulnerabilitiesReportPage()
        case (.security, "threats"): ThreatsReportPage()
        case (.identity, "posture"): PostureReportPage()
        default: main
        }
    }
}
