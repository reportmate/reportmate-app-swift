import SwiftUI

/// The web app's header navigation: Dashboard, Devices, Events, then every
/// report as its own tab. Only when the window is too narrow for all of them
/// do the reports collapse into a menu, like the web's Reports dropdown. The
/// bar carries nothing else: the API endpoint lives in Settings, and a red dot
/// appears here only while the connection is failing.
struct TopNavBar: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 12) {
            if onDevicePage {
                // On one device the page's own tabs are the point; the fleet reports
                // repeat the same module names, so they fold into the menu as on a
                // narrow window.
                HStack(spacing: 4) {
                    ForEach(AppSection.fleet) { tab($0) }
                    reportsMenu
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        ForEach(AppSection.fleet) { tab($0) }
                        Divider().frame(height: 18).padding(.horizontal, 4)
                        ForEach(AppSection.reports) { tab($0) }
                    }
                    HStack(spacing: 4) {
                        ForEach(AppSection.fleet) { tab($0) }
                        reportsMenu
                    }
                }
            }
            Spacer(minLength: 8)
            if let problem = appState.authProblem {
                Circle().fill(Color.red).frame(width: 7, height: 7).help(problem)
            } else if !appState.isConfigured {
                Circle().fill(Color.gray).frame(width: 7, height: 7).help("Not connected: set the API endpoint in Settings")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.cardBackground)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var onDevicePage: Bool {
        switch appState.currentRoute {
        case .device, .localDevice: return true
        default: return false
        }
    }

    private func select(_ section: AppSection) {
        appState.path = NavigationPath()
        appState.section = section
    }

    private func tab(_ section: AppSection) -> some View {
        let active = appState.section == section
        return Button { select(section) } label: {
            HStack(spacing: 5) {
                Image(systemName: section.systemImage).appFont(fixed: 11)
                Text(section.title).appFont(.callout, weight: active ? .semibold : .regular)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(active ? section.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(active ? section.accent : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("\(section.title) (⌘\(String(section.keyEquivalent.character)))")
    }

    private var reportsMenu: some View {
        let current = appState.section.isReport ? appState.section : nil
        return Menu {
            ForEach(AppSection.reports) { section in
                Button { select(section) } label: { Label(section.title, systemImage: section.systemImage) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: current?.systemImage ?? "doc.text.magnifyingglass").appFont(fixed: 11)
                Text(current.map { "Reports · \($0.title)" } ?? "Reports").appFont(.callout, weight: current == nil ? .regular : .semibold)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(current.map { $0.accent.opacity(0.14) } ?? Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(current?.accent ?? Color.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
