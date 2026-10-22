import SwiftUI

/// Every page's model, owned by `AppState` instead of the page view, so leaving a
/// page and coming back shows the data it had at once and refreshes it in the
/// background. Skeletons appear only on a page's very first load. A new
/// connection starts a fresh set.
@MainActor
@Observable
final class PageModels {
    let dashboard = DashboardModel()
    let insights = DashboardInsightsModel()
    /// The dashboard's last content width, so a return lays out in its columns at once.
    var dashboardWidth: CGFloat = 0
    let events = EventsFeedModel()
    let installs = InstallsReportModel()
    let applications = ApplicationsReportModel()
    /// Management's two views: MDM enrollment, or the management tools' logs.
    enum ManagementMode { case enrollment, logs }
    var managementMode: ManagementMode = .enrollment
    let managementLogs = ManagementLogsModel()

    @ObservationIgnored private var reports: [String: FleetReportModel] = [:]
    @ObservationIgnored private var devices: [String: DeviceDetailModel] = [:]
    @ObservationIgnored private var deviceOrder: [String] = []
    private static let devicesKept = 12

    /// The bulk report model for `/security`, `/management`, …
    func report(_ path: String) -> FleetReportModel {
        if let m = reports[path] { return m }
        let m = FleetReportModel(path: path)
        reports[path] = m
        return m
    }

    /// A device page's model; the last dozen devices opened are kept.
    func device(_ serial: String, isLocal: Bool) -> DeviceDetailModel {
        let key = (isLocal ? "local:" : "") + serial
        if let m = devices[key] {
            deviceOrder.removeAll { $0 == key }
            deviceOrder.append(key)
            return m
        }
        let m = DeviceDetailModel(serial: serial, isLocal: isLocal)
        devices[key] = m
        deviceOrder.append(key)
        if deviceOrder.count > Self.devicesKept { devices[deviceOrder.removeFirst()] = nil }
        return m
    }
}
