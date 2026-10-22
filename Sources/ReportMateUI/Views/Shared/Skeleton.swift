import SwiftUI

// Skeleton loading: grey blocks laid out like the page that is loading, with a
// soft highlight sweeping across them. They take the window's appearance (light,
// dark, increased contrast), and with Reduce Motion on they hold still.

/// The sweep, shared in time by every block on screen so they shimmer together.
private struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.overlay {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let period = 1.6
                    let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                    GeometryReader { geo in
                        let band = max(geo.size.width * 0.5, 80)
                        LinearGradient(colors: [.clear, highlight, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: band)
                            .offset(x: -band + (geo.size.width + band * 2) * t)
                    }
                }
                .mask(content)
                .allowsHitTesting(false)
            }
        }
    }

    private var highlight: Color { scheme == .dark ? Color.white.opacity(0.07) : Color.white.opacity(0.55) }
}

extension View {
    func shimmering() -> some View { modifier(Shimmer()) }

    /// Marks a skeleton as one "Loading" element for VoiceOver.
    func skeletonAccessibility(_ label: String = "Loading") -> some View {
        accessibilityElement(children: .ignore).accessibilityLabel(label)
    }
}

/// The fill every skeleton shape uses.
private struct SkeletonFill: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        let contrast = environment.colorSchemeContrast == .increased
        return environment.colorScheme == .dark ? Color.white.opacity(contrast ? 0.16 : 0.08) : Color.black.opacity(contrast ? 0.14 : 0.07)
    }
}

/// A rounded block: a chart, a tile, a button.
struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat
    var radius: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(SkeletonFill())
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .shimmering()
    }
}

/// A line of text. `width` nil takes the row; a fraction (0…1) takes that share of it.
struct SkeletonLine: View {
    var width: CGFloat? = nil
    var fraction: CGFloat? = nil
    var height: CGFloat = 10

    var body: some View {
        if let fraction {
            GeometryReader { geo in
                SkeletonBlock(width: geo.size.width * fraction, height: height, radius: height / 2)
            }
            .frame(height: height)
        } else {
            SkeletonBlock(width: width, height: height, radius: height / 2)
        }
    }
}

/// A donut, an avatar, an icon.
struct SkeletonCircle: View {
    var size: CGFloat
    var ring: CGFloat? = nil

    var body: some View {
        Group {
            if let ring {
                Circle().stroke(SkeletonFill(), lineWidth: ring).padding(ring / 2)
            } else {
                Circle().fill(SkeletonFill())
            }
        }
        .frame(width: size, height: size)
        .shimmering()
    }
}

/// Table rows: one skeleton line per column. A nil width is the flexible column.
struct SkeletonTableRows: View {
    var rows: Int = 12
    var columns: [CGFloat?] = [220, nil, 120, 110]
    var header = true

    var body: some View {
        VStack(spacing: 0) {
            if header {
                HStack(spacing: 12) {
                    ForEach(columns.indices, id: \.self) { i in cell(columns[i], height: 8, fraction: 0.5) }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.subtleBackground)
                Divider()
            }
            ForEach(0..<rows, id: \.self) { r in
                HStack(spacing: 12) {
                    ForEach(columns.indices, id: \.self) { i in
                        // Vary the lengths so the rows read as text, not a grid.
                        cell(columns[i], height: 10, fraction: [0.85, 0.6, 0.75, 0.5, 0.7][(r + i) % 5])
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 11)
                Divider().opacity(0.6)
            }
        }
        .skeletonAccessibility()
    }

    @ViewBuilder
    private func cell(_ width: CGFloat?, height: CGFloat, fraction: CGFloat) -> some View {
        if let width {
            SkeletonLine(width: width * fraction, height: height).frame(width: width, alignment: .leading)
        } else {
            SkeletonLine(fraction: fraction, height: height).frame(maxWidth: .infinity)
        }
    }
}

/// A card's header: icon tile, title and subtitle.
struct SkeletonCardHeader: View {
    var icon = true
    var body: some View {
        HStack(spacing: 12) {
            if icon { SkeletonBlock(width: 36, height: 36, radius: 8) }
            VStack(alignment: .leading, spacing: 6) {
                SkeletonLine(width: 130, height: 12)
                SkeletonLine(width: 190, height: 8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// A card with a skeleton header over `content`.
struct SkeletonCard<Content: View>: View {
    var header = true
    @ViewBuilder var content: Content

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                if header { SkeletonCardHeader() }
                content.padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .skeletonAccessibility()
    }
}

/// Label-and-value rows, the body of most info cards.
struct SkeletonRows: View {
    var count = 5
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<count, id: \.self) { i in
                HStack {
                    SkeletonLine(width: [90, 120, 70, 100, 80][i % 5], height: 9)
                    Spacer()
                    SkeletonLine(width: [120, 80, 140, 60, 110][i % 5], height: 9)
                }
            }
        }
    }
}

/// Ranked bars: label, bar, count.
struct SkeletonBars: View {
    var count = 4
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(0..<count, id: \.self) { i in
                HStack(spacing: 8) {
                    SkeletonLine(width: [96, 80, 110, 70, 90][i % 5], height: 9)
                    SkeletonLine(fraction: [0.9, 0.6, 0.4, 0.25, 0.15][i % 5], height: 7)
                    SkeletonLine(width: 24, height: 9)
                }
            }
        }
    }
}

/// Donut and legend, as the insight and report donuts draw them.
struct SkeletonDonut: View {
    var size: CGFloat = 96
    var legend = 3
    var body: some View {
        HStack(spacing: 14) {
            SkeletonCircle(size: size, ring: size * 0.18)
            VStack(alignment: .leading, spacing: 9) {
                ForEach(0..<legend, id: \.self) { i in
                    HStack(spacing: 6) {
                        SkeletonCircle(size: 9)
                        SkeletonLine(width: [90, 70, 110][i % 3], height: 9)
                        Spacer(minLength: 6)
                        SkeletonLine(width: 28, height: 9)
                    }
                }
            }
        }
    }
}

/// A report page loading: the widget row as blocks, then the table.
struct ReportSkeleton: View {
    var widgets = 4
    var widgetHeight: CGFloat = 150
    var columns: [CGFloat?] = [220, nil, 130, 120, 110]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(0..<widgets, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 10) {
                        SkeletonLine(width: 100, height: 9)
                        if i % 2 == 0 { SkeletonBars(count: 4) } else { SkeletonDonut(size: 72, legend: 3) }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: widgetHeight, alignment: .topLeading)
                    .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.cardBorder))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .overlay(alignment: .bottom) { Divider() }
            SkeletonTableRows(rows: 14, columns: columns)
            Spacer(minLength: 0)
        }
        .skeletonAccessibility()
    }
}

/// The shimmer only while `active`, for a real layout drawn with `.redacted(reason: .placeholder)`.
struct ShimmerWhile: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.shimmering().accessibilityLabel("Loading") } else { content }
    }
}
