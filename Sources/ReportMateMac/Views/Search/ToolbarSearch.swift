import SwiftUI
import ReportMateKit

/// The web header's search box: an inline field in the toolbar whose results
/// drop down under it, with the matched text highlighted. Enter opens the
/// selected device, or lands on the Devices list filtered by the query when
/// nothing matched; arrows move the selection; Escape clears.
struct ToolbarSearchField: View {
    @Environment(AppState.self) private var appState
    @Binding var query: String
    @Binding var selectedIndex: Int
    var focused: FocusState<Bool>.Binding

    private var results: [DeviceSummary] { DeviceSearch.search(appState.devices, query: query, limit: 8) }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search by name, serial, asset, or hostname", text: $query)
                .textFieldStyle(.plain)
                .focused(focused)
                .onSubmit(openSelected)
                .onKeyPress(.downArrow) { selectedIndex = min(selectedIndex + 1, max(results.count - 1, 0)); return .handled }
                .onKeyPress(.upArrow) { selectedIndex = max(selectedIndex - 1, 0); return .handled }
                .onKeyPress(.escape) { query = ""; focused.wrappedValue = false; return .handled }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .frame(width: 360)
        .background(Color.subtleBackground, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(focused.wrappedValue ? Color.blue.opacity(0.6) : Color.cardBorder))
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .onAppear { Task { await appState.loadDevices() } }
    }

    private func openSelected() {
        if results.indices.contains(selectedIndex) {
            appState.open(device: results[selectedIndex].serialNumber)
        } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            appState.section = .devices
            NotificationCenter.default.post(name: .devicesSearch, object: query)
        }
        query = ""
        focused.wrappedValue = false
    }
}

/// The results list that floats under the toolbar while the field has a query.
struct ToolbarSearchResults: View {
    @Environment(AppState.self) private var appState
    @Binding var query: String
    @Binding var selectedIndex: Int
    var focused: FocusState<Bool>.Binding

    private var results: [DeviceSummary] { DeviceSearch.search(appState.devices, query: query, limit: 8) }

    var body: some View {
        VStack(spacing: 0) {
            if results.isEmpty {
                Text(appState.devicesLoading ? "Loading devices…" : "No devices match “\(query)”")
                    .appFont(.callout).foregroundStyle(.secondary).padding(14)
            } else {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, device in
                    Button { select(device) } label: {
                        HStack(spacing: 10) {
                            Circle().fill(Tone.forStatus(device.status).color).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(SearchHighlight.attributed(device.name, query: query)).appFont(.body, weight: .medium).lineLimit(1)
                                HStack(spacing: 8) {
                                    Text(SearchHighlight.attributed(device.serialNumber, query: query)).appFont(.caption, design: .monospaced)
                                    if let tag = device.inventory.assetTag { Text(SearchHighlight.attributed(tag, query: query)).appFont(.caption, weight: .medium) }
                                    if let host = device.hostname { Text(SearchHighlight.attributed(host, query: query)).appFont(.caption).lineLimit(1) }
                                }
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            PlatformBadge(platform: device.platform)
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary).appFont(.caption)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(index == selectedIndex ? Color.subtleBackground : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { if $0 { selectedIndex = index } }
                    if index < results.count - 1 { Divider() }
                }
            }
        }
        .frame(width: 520)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.cardBorder))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }

    private func select(_ device: DeviceSummary) {
        appState.open(device: device.serialNumber)
        query = ""
        focused.wrappedValue = false
    }
}

/// Marks every occurrence of the query in the text the way the web's search
/// results do, case-insensitively.
enum SearchHighlight {
    static func attributed(_ text: String, query: String) -> AttributedString {
        var out = AttributedString(text)
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return out }
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
            if let lower = AttributedString.Index(found.lowerBound, within: out), let upper = AttributedString.Index(found.upperBound, within: out) {
                out[lower..<upper].backgroundColor = Color.yellow.opacity(0.45)
            }
            searchRange = found.upperBound..<text.endIndex
        }
        return out
    }
}
