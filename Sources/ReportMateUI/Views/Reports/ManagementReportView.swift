import SwiftUI
import ReportMateKit

/// Fleet management report: providers, enrollment status and type widgets
/// over the enrollment table. Port of `app/management/page.tsx`.
struct ManagementReportView: View {
    @Environment(AppState.self) private var appState
    /// Kept by `AppState` across navigation, so a return shows the last rows at once.
    private var model: FleetReportModel { appState.pages.report("/management") }

    enum Column { case device, provider, status, type, compliance, sync, certificate, deviceId }
    @State private var sortColumn: Column = .device
    @State private var ascending = true
    @State private var providerFilter: String? = nil
    @State private var statusFilter: String? = nil
    @State private var typeFilter: String? = nil
    /// Enrollment health problem filters (`compliance`, `syncOlderThan`, `certExpiring`).
    @State private var health = EnrollmentHealthFilters()

    private func m(_ row: ReportRow) -> ManagementReportRow { ManagementReportRow(json: row.json) }

    private var widgetFilters: [String] { [providerFilter, statusFilter, typeFilter].compactMap { $0 } }

    private func filtered(_ rows: [ReportRow]) -> [(row: ReportRow, m: ManagementReportRow)] {
        rows.map { ($0, m($0)) }.filter { pair in
            if let providerFilter, pair.m.provider != providerFilter { return false }
            if let statusFilter, pair.m.enrollmentStatus != statusFilter { return false }
            if health.count > 0, !health.matches(EnrollmentHealth(json: pair.row.json)) { return false }
            if let typeFilter {
                if typeFilter == "Unmanaged" { if pair.m.enrollmentType != "Unmanaged" { return false } }
                else if (pair.m.bootstrapMethod ?? "Not Enrolled") != typeFilter { return false }
            }
            return true
        }.sorted { a, b in
            let av: String, bv: String
            switch sortColumn {
            case .device: av = a.row.deviceName.lowercased(); bv = b.row.deviceName.lowercased()
            case .provider: av = a.m.provider.lowercased(); bv = b.m.provider.lowercased()
            case .status: av = a.m.enrollmentStatus.lowercased(); bv = b.m.enrollmentStatus.lowercased()
            case .type: av = a.m.enrollmentType.lowercased(); bv = b.m.enrollmentType.lowercased()
            case .deviceId: av = a.m.intuneId.lowercased(); bv = b.m.intuneId.lowercased()
            case .compliance, .sync, .certificate:
                // Unknown values sort last in either direction.
                let x = healthSortKey(a.row), y = healthSortKey(b.row)
                let r = ReportSortKey.compare(x, y, ascending: ascending)
                return r == .orderedSame ? a.row.deviceName.lowercased() < b.row.deviceName.lowercased() : r == .orderedAscending
            }
            return ascending ? av < bv : av > bv
        }
    }

    var body: some View {
        FleetReportContainer(
            section: .management, model: model, activeFilterCount: [providerFilter, statusFilter, typeFilter].compactMap { $0 }.count + health.count, clearFilters: { providerFilter = nil; statusFilter = nil; typeFilter = nil; health = EnrollmentHealthFilters() }, subtitle: "Enrollment status and type, providers, and configurations", searchPlaceholder: "Search devices",
            searchKeys: { row in
                let d = ManagementReportRow(json: row.json)
                return [row.deviceName, row.serialNumber, d.intuneId, d.provider, row.inventory.usage, row.inventory.catalog, row.inventory.assetTag, row.inventory.location, row.inventory.department]
            },
            toolbar: { rows in
                CSVExportButton(filename: "management-report", headers: ["Device Name", "Serial Number", "Asset Tag", "Provider", "Enrollment Status", "Enrollment Type", "Usage", "Catalog", "Location"] + EnrollmentHealth.csvHeaders) {
                    filtered(rows).map { p in [p.row.deviceName, p.row.serialNumber, p.row.inventory.assetTag ?? "", p.m.provider, p.m.enrollmentStatus, p.m.enrollmentType, p.row.inventory.usage ?? "", p.row.inventory.catalog ?? "", p.row.inventory.location ?? ""] + EnrollmentHealth(json: p.row.json).csvValues }
                }
            },
            widgets: { rows in widgets(rows.map(m)) },
            linking: linking
        ) { rows in
            VStack(spacing: 0) {
                ActiveFiltersBar(labels: widgetFilters + health.labels) { providerFilter = nil; statusFilter = nil; typeFilter = nil; health = EnrollmentHealthFilters() }
                EnrollmentHealthFilterBar(filters: $health)
                table(filtered(rows))
            }
        }
    }

    /// `?provider=` and `?enrollmentType=` select the widget rows; `?enrolled=` narrows the rows.
    private var linking: ReportLinking {
        var q: [String: String] = [:]
        if let providerFilter { q["provider"] = providerFilter }
        if let typeFilter { q["enrollmentType"] = typeFilter }
        q.merge(health.query) { a, _ in a }
        return ReportLinking(absorb: { f in
            providerFilter = nil; typeFilter = nil; statusFilter = nil
            health = EnrollmentHealthFilters(query: Dictionary(uniqueKeysWithValues: EnrollmentHealthFilters.params.compactMap { k in f.take(k).first.map { (k, $0) } }))
            let providers = f.values("provider")
            if providers.count == 1 { providerFilter = f.take("provider").first }
            let types = f.values("enrollmentType")
            if types.count == 1 { typeFilter = f.take("enrollmentType").first }
        }, matches: { row, f in f.matches(management: ManagementReportRow(json: row.json), platform: row.platform, lastSeen: row.lastSeen) }, widgetQuery: q)
    }

    private func widgets(_ all: [ManagementReportRow]) -> some View {
        let providers = countLabels(all.map(\.provider)).map { ($0.label, $0.count, providerColor($0.label)) }
        let statuses = countLabels(all.map(\.enrollmentStatus).filter { $0 != "Unknown" && $0 != "N/A" }).map { ($0.label, $0.count) }
        let order = ["Automated", "User Approved", "Manual", "Other"]
        // A device with no bootstrap method is not enrolled; it stays in the donut as its
        // own slice so the percentages are shares of every device the header counts.
        let types = countLabels(all.map { $0.bootstrapMethod ?? "Not Enrolled" }).sorted { (order.firstIndex(of: $0.label) ?? 99) < (order.firstIndex(of: $1.label) ?? 99) }.map { ($0.label, $0.count) }
        return HStack(alignment: .top, spacing: 12) {
            SingleCountListWidget(title: "Providers", counts: providers, selected: $providerFilter, emptyText: "No data available").reportWidgetWidth(300)
            MiniDonutWidget(title: "Enrollment Status", data: statuses, colors: ["Enrolled": .green, "Pending": .orange, "Unenrolled": .red, "Not Enrolled": .red, "Error": .red], selected: $statusFilter).reportWidgetWidth(300)
            MiniDonutWidget(title: "Enrollment Type", data: types, colors: ["Automated": .green, "User Approved": .cyan, "Manual": .red, "Not Enrolled": Color.secondary.opacity(0.5), "Other": Color.secondary.opacity(0.5)], selected: $typeFilter).reportWidgetWidth(300)
        }
    }

    private func providerColor(_ p: String) -> Color { p == "Microsoft Intune" ? .blue : p == "Apple" ? .gray : .purple }
    private func providerTone(_ p: String) -> Tone { p == "Microsoft Intune" ? .blue : p == "Apple" ? .gray : .purple }

    private func statusTone(_ s: String) -> Tone {
        switch s {
        case "Enrolled": return .green
        case "Pending": return .yellow
        case "Not Enrolled", "Unenrolled": return .red
        default: return .gray
        }
    }

    private func table(_ pairs: [(row: ReportRow, m: ManagementReportRow)]) -> some View {
        ReportTable {
            ReportSortHeader(title: "Device", column: .device, sortColumn: $sortColumn, ascending: $ascending, width: 240)
            ReportSortHeader(title: "Provider", column: .provider, sortColumn: $sortColumn, ascending: $ascending, width: 170)
            ReportSortHeader(title: "Status", column: .status, sortColumn: $sortColumn, ascending: $ascending, width: 130)
            ReportSortHeader(title: "Type", column: .type, sortColumn: $sortColumn, ascending: $ascending, width: 140)
            ReportSortHeader(title: "Compliance", column: .compliance, sortColumn: $sortColumn, ascending: $ascending, width: 120)
            ReportSortHeader(title: "Last MDM Sync", column: .sync, sortColumn: $sortColumn, ascending: $ascending, width: 120, descendingFirst: true)
            ReportSortHeader(title: "MDM Certificate", column: .certificate, sortColumn: $sortColumn, ascending: $ascending, width: 150)
            ReportHeaderLabel(title: "Apple MDM", width: 150)
            ReportSortHeader(title: "Device ID", column: .deviceId, sortColumn: $sortColumn, ascending: $ascending)
        } rows: {
            if pairs.isEmpty { ReportEmptyRows(title: "No management records found", message: "No management records match your current search.", systemImage: "checkmark.shield") }
            ForEach(pairs, id: \.row.id) { pair in
                let d = pair.m
                HStack(alignment: .top, spacing: 12) {
                    ReportDeviceCell(row: pair.row, tab: .management).frame(width: 240, alignment: .leading)
                    Pill(d.provider, tone: providerTone(d.provider)).frame(width: 170, alignment: .leading)
                    Pill(d.enrollmentStatus, tone: statusTone(d.enrollmentStatus)).frame(width: 130, alignment: .leading)
                    Group {
                        if let method = d.bootstrapMethod {
                            Pill(method, tone: method == "Automated" ? .emerald : method == "User Approved" ? .cyan : .red).optionalHelp(d.bootstrapHint)
                        } else {
                            Pill("-", tone: .gray)
                        }
                    }
                    .frame(width: 140, alignment: .leading)
                    EnrollmentHealthCells(health: EnrollmentHealth(json: pair.row.json))
                    HStack(spacing: 6) {
                        Text(d.intuneId).appFont(.caption, design: .monospaced).textSelection(.enabled)
                        if d.intuneId != "N/A" { CopyButton(value: d.intuneId) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
                Divider()
            }
        }
    }
}

extension ManagementReportView {
    /// The sort key of the enrollment health column being sorted; nil (unknown) sorts last.
    fileprivate func healthSortKey(_ row: ReportRow) -> ReportSortKey? {
        let h = EnrollmentHealth(json: row.json)
        switch sortColumn {
        case .compliance: return h.complianceState.map { .text($0) }
        case .sync: return h.syncAgeDays().map { .number($0) }
        case .certificate: return h.certificateDaysLeft().map { .number($0) }
        default: return nil
        }
    }
}

/// Compliance, last MDM sync, MDM certificate and Apple MDM cells. A value the device
/// did not collect reads Unknown, never healthy; the Apple flags are Not applicable on Windows.
struct EnrollmentHealthCells: View {
    let health: EnrollmentHealth

    var body: some View {
        Group {
            if let state = health.complianceState {
                Pill(health.complianceLabel, tone: state == "compliant" ? .green : .red)
                    .help(health.complianceSource == "policies" ? "Evaluated from the compliance policy results the device reported" : "Reported by the device")
            } else {
                unknown.help(health.isMac ? "macOS does not report compliance" : "Not collected")
            }
        }
        .frame(width: 120, alignment: .leading)
        Group {
            if health.syncAgeDays() != nil {
                Text(health.syncText()).appFont(.callout).help(TimeFormatting.exact(health.lastMdmSync))
            } else {
                unknown.help(health.isMac ? "macOS does not report a last MDM sync time" : "Not collected")
            }
        }
        .frame(width: 120, alignment: .leading)
        Group {
            if let left = health.certificateDaysLeft() {
                Text(health.certificateText()).appFont(.callout, weight: left <= Double(EnrollmentHealthFilters.certificateExpiryDays) ? .medium : nil)
                    .foregroundStyle(left < 0 ? Color.red : left <= Double(EnrollmentHealthFilters.certificateExpiryDays) ? Color.orange : Color.primary)
                    .help(TimeFormatting.exact(health.mdmCertificateExpires))
            } else {
                unknown
            }
        }
        .frame(width: 150, alignment: .leading)
        Group {
            if health.isMac {
                VStack(alignment: .leading, spacing: 1) {
                    Text("User approved: \(health.appleFlag(health.userApprovedMdm))")
                    Text("ADE installed: \(health.appleFlag(health.installedFromDep))")
                    Text("DEP capable: \(health.appleFlag(health.depCapable))")
                }
                .appFont(.caption)
            } else {
                Text("Not applicable").appFont(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 150, alignment: .leading)
    }

    private var unknown: some View { Text("Unknown").appFont(.caption).foregroundStyle(.secondary) }
}

/// The enrollment health problem filters. A device that did not report a value never matches one.
struct EnrollmentHealthFilterBar: View {
    @Binding var filters: EnrollmentHealthFilters

    var body: some View {
        let syncChoices = Array(Set(EnrollmentHealthFilters.syncAgeChoices + (filters.syncOlderThanDays.map { [$0] } ?? []))).sorted()
        let certDays = filters.certExpiringDays ?? EnrollmentHealthFilters.certificateExpiryDays
        HStack(spacing: 14) {
            Text("ENROLLMENT HEALTH").appFont(.caption2, weight: .medium).foregroundStyle(.secondary)
            FilterPill(text: "Not compliant", selected: filters.nonCompliant) { filters.nonCompliant.toggle() }
            HStack(spacing: 6) {
                Text("MDM sync older than").appFont(.caption).foregroundStyle(.secondary)
                ForEach(syncChoices, id: \.self) { n in
                    FilterPill(text: n == 1 ? "1 day" : "\(n) days", selected: filters.syncOlderThanDays == n) {
                        filters.syncOlderThanDays = filters.syncOlderThanDays == n ? nil : n
                    }
                }
            }
            FilterPill(text: "MDM certificate expiring within \(certDays) days", selected: filters.certExpiringDays != nil) {
                filters.certExpiringDays = filters.certExpiringDays == nil ? EnrollmentHealthFilters.certificateExpiryDays : nil
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .help("Devices that did not report a value are excluded from these filters and shown as Unknown.")
        .overlay(alignment: .bottom) { Divider() }
    }
}
