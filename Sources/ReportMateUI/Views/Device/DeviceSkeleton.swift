import SwiftUI

/// The device header while the device loads: name, identifiers and status pills.
struct DeviceHeaderSkeleton: View {
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    SkeletonLine(width: 260, height: 22)
                    SkeletonCircle(size: 16)
                }
                HStack(spacing: 12) {
                    SkeletonLine(width: 70, height: 11)
                    SkeletonLine(width: 110, height: 11)
                    SkeletonBlock(width: 120, height: 20, radius: 10)
                    SkeletonLine(width: 90, height: 9)
                }
            }
            Spacer()
            SkeletonBlock(width: 22, height: 22, radius: 11)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider() }
        .skeletonAccessibility("Loading device")
    }
}

/// One device tab while its module loads, shaped like that tab.
struct DeviceTabSkeleton: View {
    let tab: DeviceTab

    var body: some View {
        Group {
            switch tab {
            case .info:
                UniformGrid(minColumnWidth: 300, maxColumns: 6, spacing: 16, fillsHeight: false) {
                    ForEach(0..<6, id: \.self) { i in SkeletonCard { SkeletonRows(count: [6, 4, 5, 5, 4, 6][i]) } }
                }
            case .installs, .applications, .events:
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 16) {
                        ForEach(0..<4, id: \.self) { _ in
                            SkeletonCard(header: false) {
                                VStack(alignment: .leading, spacing: 8) {
                                    SkeletonLine(width: 40, height: 20)
                                    SkeletonLine(width: 90, height: 9)
                                }
                            }
                        }
                    }
                    Card {
                        VStack(spacing: 0) {
                            SkeletonCardHeader()
                            SkeletonTableRows(rows: 12, columns: [nil, 140, 120, 120])
                        }
                    }
                    .skeletonAccessibility()
                }
            case .hardware, .system, .network:
                VStack(alignment: .leading, spacing: 16) {
                    UniformGrid(minColumnWidth: 180, maxColumns: 6, spacing: 12, fillsHeight: false) {
                        ForEach(0..<6, id: \.self) { _ in
                            SkeletonCard(header: false) {
                                VStack(alignment: .leading, spacing: 8) {
                                    SkeletonLine(width: 70, height: 9)
                                    SkeletonLine(width: 110, height: 16)
                                }
                            }
                        }
                    }
                    UniformGrid(minColumnWidth: 340, maxColumns: 3, spacing: 16, fillsHeight: false) {
                        ForEach(0..<3, id: \.self) { _ in SkeletonCard { SkeletonRows(count: 6) } }
                    }
                }
            default:
                UniformGrid(minColumnWidth: 340, maxColumns: 3, spacing: 16, fillsHeight: false) {
                    ForEach(0..<6, id: \.self) { i in
                        SkeletonCard {
                            if i % 3 == 1 { SkeletonDonut() } else { SkeletonRows(count: 5) }
                        }
                    }
                }
            }
        }
        .skeletonAccessibility("Loading \(tab.title.lowercased())")
    }
}
