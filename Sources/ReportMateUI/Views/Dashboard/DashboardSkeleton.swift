import SwiftUI

// The dashboard's columns while the payload loads, in the same layout tiers as
// the loaded page (see `DashboardView.layout`). Insight cards draw their own
// skeleton through `InsightCard`.

/// Fleet Status, the two counters and New Clients.
struct DashboardStatusSkeleton: View {
    var body: some View {
        VStack(spacing: 20) {
            SkeletonCard {
                VStack(spacing: 18) {
                    SkeletonCircle(size: 190, ring: 34).frame(maxWidth: .infinity)
                    VStack(spacing: 12) {
                        ForEach(0..<3, id: \.self) { i in
                            HStack {
                                SkeletonCircle(size: 12)
                                SkeletonLine(width: [60, 48, 56][i], height: 10)
                                Spacer()
                                SkeletonLine(width: 30, height: 10)
                            }
                        }
                    }
                }
            }
            // Install Health: two hero figures over the item lists.
            SkeletonCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        ForEach(0..<2, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 6) {
                                SkeletonBlock(width: 72, height: 52, radius: 10)
                                SkeletonLine(width: 120, height: 10)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    SkeletonBars(count: 4)
                }
            }
            SkeletonCard {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(0..<4, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 5) {
                            SkeletonLine(width: [150, 120, 170, 130][i], height: 11)
                            SkeletonLine(width: 90, height: 8)
                        }
                    }
                }
            }
        }
    }
}

/// Recent Events, Platform Distribution and the OS version charts.
struct DashboardActivitySkeleton: View {
    var body: some View {
        VStack(spacing: 20) {
            Card {
                VStack(spacing: 0) {
                    SkeletonCardHeader(icon: false)
                    SkeletonTableRows(rows: 12, columns: [24, nil, 160, 100])
                }
            }
            .skeletonAccessibility()
            SkeletonCard { SkeletonBars(count: 6) }
            SkeletonCard {
                VStack(spacing: 10) {
                    ForEach(0..<2, id: \.self) { _ in
                        HStack(spacing: 12) {
                            SkeletonBlock(width: 28, height: 28, radius: 6)
                            VStack(alignment: .leading, spacing: 8) {
                                SkeletonLine(width: 120, height: 11)
                                SkeletonLine(height: 8)
                            }
                            SkeletonLine(width: 34, height: 16)
                        }
                        .padding(12)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.cardBorder))
                    }
                }
            }
            HStack(alignment: .top, spacing: 16) {
                ForEach(0..<2, id: \.self) { _ in
                    SkeletonCard(header: false) {
                        VStack(alignment: .leading, spacing: 14) {
                            SkeletonLine(width: 140, height: 12)
                            HStack(alignment: .top, spacing: 14) {
                                SkeletonCircle(size: 150, ring: 26)
                                SkeletonBars(count: 6)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// An insight card's body while its data loads.
struct InsightBodySkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SkeletonDonut()
            SkeletonBars(count: 3)
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { i in SkeletonBlock(width: [96, 80, 70][i], height: 22, radius: 11) }
            }
        }
        .skeletonAccessibility()
    }
}
