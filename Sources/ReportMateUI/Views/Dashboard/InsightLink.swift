import SwiftUI
import ReportMateKit

extension AppState {
    /// A dashboard link with the platform toggle on it, as the web header adds `?platform=` to every link.
    func withPlatform(_ link: DeepLink) -> DeepLink {
        var l = link
        if l.query["platform"] == nil {
            switch platformFilter {
            case .macOS: l.query["platform"] = "mac"
            case .windows: l.query["platform"] = "win"
            case .all: break
            }
        }
        return l
    }

    /// Open a dashboard link: the report it names, with its filter on.
    func follow(_ link: DeepLink) { open(deepLink: withPlatform(link)) }

    /// The link to share: the web handoff when a web dashboard is configured, else the app link.
    func shareURL(_ link: DeepLink) -> URL {
        let l = withPlatform(link)
        if let base = configuration.normalizedWebURL, let handoff = l.handoffURL(webBase: base) { return handoff }
        return l.url
    }

    /// Words for a link's tooltip: "Management: Provider: Unmanaged".
    func describe(_ link: DeepLink) -> String {
        let title: String
        var filter = ""
        switch link.target {
        case .devices:
            title = "Devices"
            filter = link.query.filter { $0.key != "platform" }.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        case .report(let name):
            title = AppSection(rawValue: name)?.title ?? name
            filter = ReportLinkFilter(report: name, query: link.query).chips.map(\.label).joined(separator: ", ")
        case .eventsFailures:
            title = "Check-in failures"
            filter = ReportLinkFilter(report: "failures", query: link.query).chips.map(\.label).joined(separator: ", ")
        case .applicationUsage(let app): title = "Usage of \(app)"
        case .device: title = "Device"
        default: title = "ReportMate"
        }
        return filter.isEmpty ? "Show \(title)" : "Show \(title) — \(filter)"
    }
}

/// A dashboard item (a count, bar, legend row or chip) that opens its report
/// with the item's filter on. It highlights on hover, says where it goes in its
/// tooltip, and its context menu copies the link the web and Windows apps share.
struct InsightLink<Label: View>: View {
    @Environment(AppState.self) private var appState
    let link: DeepLink
    @ViewBuilder var label: Label
    @State private var hovered = false

    var body: some View {
        Button { appState.follow(link) } label: {
            label
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(hovered ? Color.secondary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(appState.describe(link))
        .linkContextMenu(link)
        .accessibilityHint(appState.describe(link))
    }
}

extension View {
    /// Open, Copy Link and Copy App Link for a dashboard link.
    func linkContextMenu(_ link: DeepLink) -> some View { modifier(LinkContextMenu(link: link)) }
}

private struct LinkContextMenu: ViewModifier {
    @Environment(AppState.self) private var appState
    let link: DeepLink

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Open") { appState.follow(link) }
            Divider()
            Button("Copy Link") { copy(appState.shareURL(link)) }
            if appState.configuration.normalizedWebURL != nil {
                Button("Copy App Link") { copy(appState.withPlatform(link).url) }
            }
        }
    }

    private func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}
