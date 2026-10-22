import Foundation

/// The links behind every number, bar, legend row and chip on the dashboard.
/// They are the web dashboard's routes and parameters (`docs/DASHBOARD-WIDGETS.md`
/// in the web repo), so a link copied from a card is the same in every app.
public enum DashboardLinks {
    public static func report(_ name: String, _ query: [String: String] = [:]) -> DeepLink {
        DeepLink(target: .report(name), query: query)
    }

    // MARK: Devices

    public static func devices(_ query: [String: String] = [:]) -> DeepLink { DeepLink(target: .devices, query: query) }
    public static func devices(status: DeviceStatus) -> DeepLink { devices(["status": status.rawValue]) }

    // MARK: Installs

    public static func installs(filter: String? = nil) -> DeepLink { report("installs", filter.map { ["filter": $0] } ?? [:]) }
    public static func installs(item: String, filter: String? = nil) -> DeepLink {
        var q = ["item": item]
        if let filter { q["filter"] = filter }
        return report("installs", q)
    }
    public static var installsStale: DeepLink { report("installs", ["stale": "1"]) }

    // MARK: Check-ins

    public static func failures(hours: Int = 24, reason: String? = nil) -> DeepLink {
        var q = ["hours": String(hours)]
        if let reason { q["reason"] = reason }
        return DeepLink(target: .eventsFailures, query: q)
    }

    // MARK: System

    public static func system(_ query: [String: String] = [:]) -> DeepLink { report("system", query) }
    public static func system(osVersion: String) -> DeepLink { system(["osVersion": osVersion]) }

    // MARK: Applications

    public static func applicationUsage(_ app: String, days: Int = 30) -> DeepLink {
        DeepLink(target: .applicationUsage(app: app), query: ["days": String(days)])
    }
}
