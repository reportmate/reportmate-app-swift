import SwiftUI
import Charts
import ReportMateKit

/// The dashboard's insight cards, from the API's cached insights endpoints. The
/// API computes every card in SQL and caches it, so the dashboard never pulls the
/// bulk reports (which held the API at its memory limit).
///
/// Where the API serves one card per request (`/dashboard/insights/{card}`), the
/// cards load in parallel and each paints as soon as it answers; otherwise one
/// request (`/dashboard/insights`) brings them all. A 404 means the server does
/// not have the endpoint yet, and the cards say so at once rather than waiting.
@MainActor
@Observable
final class DashboardInsightsModel {
    /// Each card's section, filled as the cards answer. A card that failed holds `{"error": …}`.
    private(set) var cards: [String: InsightCardData] = [:]
    private(set) var loading = false
    /// The request for every card failed and there is nothing to show.
    private(set) var error: String?
    private var loadedKey: String?
    private var loadedAt: Date?
    private var inFlightKey: String?
    private var generation = 0
    /// Whether this server serves one card per request; learnt on the first load.
    private var perCard: [String: Bool] = [:]

    static let refreshInterval: TimeInterval = 300
    static let notDeployed = "Not available on this server yet"
    static let cardCount = DashboardInsightsDocument.cardKeys.count

    var hasData: Bool { !cards.isEmpty }
    /// Cards that have answered, with data or an error, for "Loading n of 12".
    var answered: Int { cards.count }
    func card(_ key: String) -> InsightCardData? { cards[key] }

    /// Fetch unless the cards for this connection and platform are under five minutes old.
    func load(api: ReportMateAPI, platform: PlatformFilter, includeArchived: Bool, force: Bool = false) async {
        let p = DashboardInsightsDocument.platformParameter(platform)
        let base = api.configuration.normalizedBaseURL
        let key = "\(base)|\(p)|\(includeArchived)"
        if !force, key == loadedKey, let loadedAt, Date().timeIntervalSince(loadedAt) < Self.refreshInterval { return }
        if !force, inFlightKey == key { return }
        if key != loadedKey {
            // Another platform or connection: its cards are not these.
            cards = [:]
            error = nil
        }
        generation += 1
        let mine = generation
        inFlightKey = key
        loading = true
        defer { if mine == generation { loading = false; inFlightKey = nil } }
        let query: [String: String?] = ["platform": p, "includeArchived": includeArchived ? "true" : nil]

        if perCard[base] != false {
            let keys = DashboardInsightsDocument.cardKeys
            // The first card tells whether the server has per-card endpoints.
            let first = await Self.fetchCard(keys[0], api: api, query: query)
            guard mine == generation else { return }
            if case .notFound = first, perCard[base] == nil {
                perCard[base] = false
            } else {
                perCard[base] = true
                apply(first, to: keys[0])
                await withTaskGroup(of: (String, CardResult).self) { group in
                    var next = keys.dropFirst().makeIterator()
                    for _ in 0..<4 { if let k = next.next() { group.addTask { (k, await Self.fetchCard(k, api: api, query: query)) } } }
                    while let (k, result) = await group.next() {
                        guard mine == generation else { group.cancelAll(); return }
                        if let more = next.next() { group.addTask { (more, await Self.fetchCard(more, api: api, query: query)) } }
                        apply(result, to: k)
                    }
                }
                guard mine == generation else { return }
                error = nil
                loadedKey = key
                loadedAt = Date()
                return
            }
        }

        // One request for every card.
        do {
            let json = try await Self.retrying { try await api.getJSON("/dashboard/insights", query: query) }
            guard mine == generation else { return }
            guard json["cards"].object != nil else {
                error = json.isNull ? Self.notDeployed : "The server's insights answer had no cards."
                return
            }
            let doc = DashboardInsightsDocument(json: json)
            cards = doc.cards
            error = nil
            loadedKey = key
            loadedAt = Date()
        } catch {
            guard mine == generation else { return }
            self.error = error.localizedDescription
        }
    }

    enum CardResult: Sendable {
        case card(JSONValue)
        case notFound
        case failed(String)
    }

    private func apply(_ result: CardResult, to key: String) {
        switch result {
        case .card(let json): cards[key] = InsightCardData(json: json)
        case .notFound: cards[key] = InsightCardData(json: .object(["error": .string(Self.notDeployed)]))
        case .failed(let message):
            // A failed refresh keeps the card's last good answer.
            if cards[key] == nil || cards[key]?.error != nil { cards[key] = InsightCardData(json: .object(["error": .string(message)])) }
        }
    }

    nonisolated private static func fetchCard(_ key: String, api: ReportMateAPI, query: [String: String?]) async -> CardResult {
        do {
            let json = try await retrying { try await api.getJSON("/dashboard/insights/\(key)", query: query) }
            if json.isNull { return .notFound }
            // The card on its own, or wrapped as {card: …} or {cards: {key: …}}.
            if json["cards"][key].object != nil { return .card(json["cards"][key]) }
            if json["card"].object != nil { return .card(json["card"]) }
            return .card(json)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// One more try after a pause for a 5xx or a dropped connection.
    nonisolated private static func retrying<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        do { return try await work() } catch {
            let retry: Bool
            switch error as? APIError {
            case .http(let status, _, _): retry = status >= 500
            case .transport: retry = true
            default: retry = false
            }
            guard retry else { throw error }
            try? await Task.sleep(for: .seconds(3))
            return try await work()
        }
    }
}

// MARK: - Card chrome

/// Asks the insights model to fetch again; the dashboard supplies it.
private struct InsightsRetryKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable () -> Void = {}
}

extension EnvironmentValues {
    var insightsRetry: @MainActor @Sendable () -> Void {
        get { self[InsightsRetryKey.self] }
        set { self[InsightsRetryKey.self] = newValue }
    }
}

/// Card chrome shared by the insight cards: a header that opens the report
/// unfiltered, then the card's section of the insights document. Until the first
/// answer it shows a skeleton; a card the server could not compute, or a failed
/// request, shows the error with Retry.
struct InsightCard<Content: View>: View {
    let key: String
    let title: String
    let subtitle: String
    let systemImage: String
    let tone: Tone
    let link: DeepLink
    @ViewBuilder var content: (InsightCardData) -> Content
    @Environment(AppState.self) private var appState
    @Environment(DashboardInsightsModel.self) private var insights
    @Environment(\.insightsRetry) private var retry

    var body: some View {
        let data = insights.card(key)
        Card {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(title, subtitle: subtitle, systemImage: systemImage, tone: tone) { appState.follow(link) }
                    .help(appState.describe(link))
                    .linkContextMenu(link)
                    .accessibilityAddTraits(.isButton)
                Group {
                    if let data, let error = data.error {
                        failure(error)
                    } else if let data {
                        content(data).padding(16)
                    } else if let error = insights.error, !insights.loading {
                        failure(error)
                    } else {
                        InsightBodySkeleton().padding(16).skeletonTimeout(retry: retry)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func failure(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle").appFont(.caption).foregroundStyle(.secondary).lineLimit(3)
            Spacer(minLength: 8)
            Button("Retry") { retry() }.controlSize(.small).disabled(insights.loading)
        }
        .padding(16)
    }
}

/// An item that links when the server gave it a link, and is plain text otherwise.
struct MaybeInsightLink<Label: View>: View {
    let link: DeepLink?
    @ViewBuilder var label: Label
    var body: some View {
        if let link { InsightLink(link: link) { label } } else { label.padding(.horizontal, 4).padding(.vertical, 2) }
    }
}

/// "Label … bar … n of N" compliance row; the link opens the devices that fall short.
struct ComplianceRow: View {
    let label: String
    let on: Int
    let total: Int
    let link: DeepLink?

    var body: some View {
        let pct = total == 0 ? 0 : Double(on) / Double(total)
        let tone: Tone = pct >= 0.9 ? .green : pct >= 0.7 ? .yellow : .red
        MaybeInsightLink(link: link) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(label).appFont(.callout)
                    Spacer()
                    Text("\(on) of \(total)").appFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Text("\(Int((pct * 100).rounded()))%").appFont(.caption, weight: .medium).foregroundStyle(tone.color).monospacedDigit().frame(width: 38, alignment: .trailing)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.12))
                        Capsule().fill(tone.color).frame(width: max(0, geo.size.width * pct))
                    }
                }
                .frame(height: 6)
            }
        }
    }
}

/// One slice of an insight donut, with the link its legend row opens.
struct InsightSlice: Identifiable {
    var id: String { label }
    let label: String
    let count: Int
    let color: Color
    var link: DeepLink? = nil
}

/// Ring plus legend, the dashboard's small donut. Each legend row opens its slice.
struct InsightDonut: View {
    let data: [InsightSlice]
    var center: String? = nil

    var body: some View {
        let total = data.reduce(0) { $0 + $1.count }
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Chart(data) { item in
                    SectorMark(angle: .value("Count", item.count), innerRadius: .ratio(0.64), angularInset: 1)
                        .foregroundStyle(item.color)
                }
                .chartLegend(.hidden)
                .frame(width: 96, height: 96)
                if let center { Text(center).appFont(.callout, weight: .semibold).monospacedDigit() }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(data) { item in
                    let row = HStack(spacing: 6) {
                        Circle().fill(item.color).frame(width: 9, height: 9)
                        Text(item.label).appFont(.callout).lineLimit(1)
                        Spacer(minLength: 6)
                        Text("\(item.count)").appFont(.callout, weight: .medium).monospacedDigit()
                        Text(total == 0 ? "" : "\(Int((Double(item.count) / Double(total) * 100).rounded()))%").appFont(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 34, alignment: .trailing)
                    }
                    if let link = item.link { InsightLink(link: link) { row } } else { row.padding(.horizontal, 4).padding(.vertical, 2) }
                }
            }
        }
    }
}

/// Small "n label" stat chip that opens the devices it counts.
struct StatChip: View {
    let value: Int
    let label: String
    let tone: Tone
    let link: DeepLink?

    var body: some View {
        MaybeInsightLink(link: link) {
            HStack(spacing: 6) {
                Text("\(value)").appFont(.callout, weight: .semibold).foregroundStyle(value == 0 ? Color.secondary : tone.color).monospacedDigit()
                Text(label).appFont(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.subtleBackground, in: Capsule())
            .overlay(Capsule().stroke(Color.cardBorder))
        }
    }
}

/// "Label … bar … n" row for ranked lists (providers, failing items, reasons).
struct InsightBarRow: View {
    let label: String
    let count: Int
    let max: Int
    let tone: Tone
    let link: DeepLink?
    var valueText: String? = nil

    var body: some View {
        MaybeInsightLink(link: link) {
            HStack(spacing: 8) {
                Text(label).appFont(.callout).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.12))
                        Capsule().fill(tone.color.opacity(0.75)).frame(width: max == 0 ? 0 : geo.size.width * CGFloat(count) / CGFloat(max))
                    }
                }
                .frame(width: 70, height: 6)
                Text(valueText ?? "\(count)").appFont(.callout, weight: .medium).monospacedDigit().frame(minWidth: 30, alignment: .trailing)
            }
        }
    }
}

/// A big figure with a caption, for the headline counts on a card.
struct InsightFigure: View {
    let value: Int?
    let label: String
    let tone: Tone
    let link: DeepLink?

    var body: some View {
        MaybeInsightLink(link: link) {
            VStack(alignment: .leading, spacing: 1) {
                Text(value.map(String.init) ?? "–").appFont(.title2, weight: .bold).foregroundStyle((value ?? 0) == 0 ? Color.secondary : tone.color).monospacedDigit()
                Text(label).appFont(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Small caps heading inside a card.
struct InsightHeading: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).appFont(.caption2, weight: .semibold).foregroundStyle(.secondary).padding(.horizontal, 4)
    }
}

/// Wraps chips onto as many lines as they need.
struct InsightChips<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { FlowLayout(spacing: 6) { content } }
}

