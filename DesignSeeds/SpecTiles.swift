// SpecTiles.swift — design seed for the ReportMate native macOS app.
//
// Extracted from FleetMate's Inventory asset sidebar (2026-07-31), where this
// layout debuted before being simplified back to plain rows there. It mirrors
// reportmate-app-web's hardware page: an Apple Silicon "chip capsule" — a
// dashed rounded enclosure grouping the SoC members (CPU red, Memory yellow,
// GPU green, NPU pink) under a "<Chip> Chip · Unified Memory Architecture"
// headline — followed by peripheral tiles (Storage purple, Display blue, and
// Battery green on laptops; desktops show 7 tiles, laptops 8).
//
// Self-contained except for `appFont`, FleetMate's Dynamic-Type-scaling font
// helper — swap for .font(.system(size:weight:)) or the ReportMate equivalent.

import SwiftUI

/// One hardware fact as a tile: tinted icon and label, value in the tint —
/// the same visual grammar ReportMate's web hardware page uses.
struct AssetSpecTile: View {
    struct Model: Identifiable {
        let icon: String
        let label: String
        let tint: Color
        let value: String
        var id: String { label }
    }

    let model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: model.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(model.tint)
                Text(model.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
            }
            Text(model.value)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(model.value == "—" ? Color.secondary : model.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .help("\(model.label): \(model.value)")
    }
}

/// The full section: chip capsule + peripheral grid.
///
/// Feed it the device's spec strings; empty values render as "—" so every
/// machine shows the same shape. `chipName` nil (e.g. Intel) drops the dashed
/// capsule and shows the SoC tiles plainly.
struct SpecTilesSection: View {
    let chipName: String?
    let cpu: String
    let memory: String
    let gpu: String
    let npu: String
    let storage: String
    let display: String
    /// nil on desktops; a value (or "—") on laptops adds the 8th tile.
    let battery: String?

    private var socTiles: [AssetSpecTile.Model] {
        [
            .init(icon: "cpu", label: "CPU", tint: .red,
                  value: cpu == "—" ? (chipName ?? "—") : cpu),
            .init(icon: "memorychip", label: "Memory", tint: .yellow, value: memory),
            .init(icon: "square.3.layers.3d", label: "GPU", tint: .green, value: gpu),
            .init(icon: "brain", label: "NPU", tint: .pink, value: npu),
        ]
    }

    private var peripheralTiles: [AssetSpecTile.Model] {
        var tiles: [AssetSpecTile.Model] = [
            .init(icon: "internaldrive", label: "Storage", tint: .purple, value: storage),
            .init(icon: "display", label: "Display", tint: .blue, value: display),
        ]
        if let battery {
            tiles.append(.init(icon: "battery.75percent", label: "Battery", tint: .green, value: battery))
        }
        return tiles
    }

    private var tileColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let chip = chipName {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(chip) Chip")
                        .font(.subheadline.weight(.bold))
                    Text("Unified Memory Architecture")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                LazyVGrid(columns: tileColumns, spacing: 8) {
                    ForEach(socTiles) { AssetSpecTile(model: $0) }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .foregroundColor(Color.secondary.opacity(0.35))
                )
            } else {
                LazyVGrid(columns: tileColumns, spacing: 8) {
                    ForEach(socTiles) { AssetSpecTile(model: $0) }
                }
            }
            LazyVGrid(columns: tileColumns, spacing: 8) {
                ForEach(peripheralTiles) { AssetSpecTile(model: $0) }
            }
        }
    }
}
