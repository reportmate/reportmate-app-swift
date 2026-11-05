import Foundation

// Shared plumbing for the fleet sub-reports: the tabs under System, Management,
// Security and Identity that the web serves at `/<module>?tab=<key>`. Every report
// keeps its whole state in web-style query parameters, so a link carries it and the
// app and the web read the same link. Rows are read from `JSONValue`, so a missing
// field reads as not reported and an extra field is ignored.

/// A sub-report's state: the web page's query parameters, without `tab` and `platform`.
public struct ReportParams: Sendable, Hashable {
    public private(set) var values: [String: String]

    public init(_ values: [String: String] = [:]) {
        var clean: [String: String] = [:]
        for (k, v) in values where k != "tab" && k != "platform" {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { clean[k] = t }
        }
        self.values = clean
    }

    public subscript(key: String) -> String? {
        get { values[key] }
        set {
            let t = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            values[key] = t.isEmpty ? nil : t
        }
    }

    public func has(_ key: String) -> Bool { values[key] != nil }
    public var isEmpty: Bool { values.isEmpty }

    /// A comma-separated list.
    public func list(_ key: String) -> [String] {
        (values[key] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A JSON array of exact names (names can hold commas). With `commaFallback`,
    /// a value that is not JSON reads as a comma list, as older links wrote it.
    public func jsonList(_ key: String, commaFallback: Bool = false) -> [String] {
        let value = values[key] ?? ""
        guard value.hasPrefix("[") else { return commaFallback ? list(key) : [] }
        guard let parsed = JSONValue.parse(value)?.array else { return [] }
        return parsed.compactMap { $0.string?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public mutating func setList(_ key: String, _ items: [String]) {
        self[key] = items.isEmpty ? nil : items.joined(separator: ",")
    }

    public mutating func setJSONList(_ key: String, _ items: [String]) {
        guard !items.isEmpty, let data = try? JSONEncoder().encode(items), let text = String(data: data, encoding: .utf8) else { self[key] = nil; return }
        self[key] = text
    }

    /// Adds or removes one value of a comma list.
    public mutating func toggle(_ key: String, _ value: String) {
        var items = list(key)
        if let i = items.firstIndex(of: value) { items.remove(at: i) } else { items.append(value) }
        setList(key, items)
    }

    public mutating func toggleFlag(_ key: String, value: String = "true") {
        self[key] = self[key] == value ? nil : value
    }

    public mutating func remove(_ keys: [String]) { for k in keys { values[k] = nil } }

    /// The parameters among `keys`, for an API request.
    public func picking(_ keys: [String]) -> [String: String] { values.filter { keys.contains($0.key) } }
}

/// The inventory scope every sub-report filters on, on the server.
public enum ReportScope {
    public static let keys = ["usages", "catalogs", "areas", "fleets", "locations", "rooms", "inventoryStates"]
    public static let labels: [String: String] = [
        "usages": "Usage", "catalogs": "Catalog", "areas": "Area", "fleets": "Fleet",
        "locations": "Location", "rooms": "Room", "inventoryStates": "Inventory state",
    ]

    /// The global platform toggle as the sub-report APIs read it.
    public static func apiPlatform(_ filter: PlatformFilter) -> String {
        switch filter {
        case .all: return "all"
        case .macOS: return "macos"
        case .windows: return "windows"
        }
    }
}

/// The scope values the API reports for the selections (`options`).
public struct ReportScopeOptions: Sendable, Hashable {
    public var values: [String: [String]]
    public init(json: JSONValue) {
        var v: [String: [String]] = [:]
        for key in ReportScope.keys { v[key] = json[key].elements.compactMap(\.nonEmptyString) }
        values = v
    }
    public subscript(key: String) -> [String] { values[key] ?? [] }
    public static let empty = ReportScopeOptions(json: .null)
}

/// Whether a device's collection is within the report's maximum age.
public enum ReportFreshness: String, Sendable, Hashable {
    case fresh, stale, unknown
    public init(_ value: JSONValue) { self = ReportFreshness(rawValue: value.string ?? "") ?? .unknown }
    public var label: String {
        switch self {
        case .fresh: return "Within maximum age"
        case .stale: return "Older than maximum age"
        case .unknown: return "Unknown"
        }
    }
}

/// Labels the web reports share.
public enum ReportLabels {
    public static func inventory(_ value: String?) -> String {
        switch value {
        case "checked_out": return "Checked out"
        case "storage": return "Storage"
        case "decommissioning": return "Decommissioning"
        default: return "Unknown"
        }
    }

    public static func yesNo(_ value: Bool?, unknown: String = "Not reported") -> String {
        value.map { $0 ? "Yes" : "No" } ?? unknown
    }

    public static func hours(_ value: Int) -> String {
        switch value {
        case 24: return "24 hours"
        case 168: return "7 days"
        case 720: return "30 days"
        default: return "\(value) hours"
        }
    }

    /// Text of a raw value: booleans read Yes/No, arrays join, empty is nil.
    public static func text(_ value: JSONValue) -> String? {
        switch value {
        case .null: return nil
        case .bool(let b): return b ? "Yes" : "No"
        case .string(let s): return s.isEmpty ? nil : s
        case .number: return value.string
        case .array(let a): let s = a.compactMap { text($0) }.joined(separator: " "); return s.isEmpty ? nil : s
        case .object: return value.prettyPrinted
        }
    }

    /// A tri-state value as the API sends it: true, false, or null for not collected.
    public static func tri(_ value: JSONValue) -> Bool? {
        switch value {
        case .bool(let b): return b
        case .number: return value.int.map { $0 != 0 }
        default: return nil
        }
    }
}

/// The device fields every sub-report row carries.
public struct ReportDevice: Sendable, Hashable {
    public var serialNumber: String
    public var deviceName: String?
    public var hostname: String?
    public var assetTag: String?
    public var platform: String
    public var usage: String?
    public var catalog: String?
    public var area: String?
    public var fleet: String?
    public var location: String?
    public var room: String?
    public var archived: Bool
    public var inventoryState: String?
    public var lastSeen: String?
    public var collectedAt: String?

    public init(json: JSONValue) {
        serialNumber = json.firstString("serialNumber", "serial_number") ?? ""
        deviceName = json["deviceName"].nonEmptyString
        hostname = json["hostname"].nonEmptyString
        assetTag = json["assetTag"].nonEmptyString
        platform = json["platform"].nonEmptyString ?? "Unknown"
        usage = json["usage"].nonEmptyString
        catalog = json["catalog"].nonEmptyString
        area = json["area"].nonEmptyString
        fleet = json["fleet"].nonEmptyString
        location = json["location"].nonEmptyString
        room = json["room"].nonEmptyString
        archived = json["archived"].bool ?? false
        inventoryState = json["inventoryState"].nonEmptyString
        lastSeen = json["lastSeen"].nonEmptyString
        collectedAt = json["collectedAt"].nonEmptyString
    }

    /// The name a table shows: the device name, else the serial number.
    public var displayName: String { deviceName ?? serialNumber }
    public var inventoryLabel: String { ReportLabels.inventory(inventoryState) + (archived ? " (archived)" : "") }

    public var appPlatform: Platform {
        let p = platform.lowercased()
        if p.contains("mac") || p.contains("darwin") { return .macOS }
        if p.contains("win") { return .windows }
        return .unknown
    }

    /// Matches the device search box: name, hostname, serial, asset tag and inventory fields.
    public func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return [deviceName, hostname, serialNumber, assetTag, usage, catalog, area, fleet, location, room].contains { $0?.lowercased().contains(q) ?? false }
    }
}

// MARK: - Columns and sorting

/// A sortable value: numbers and dates compare as numbers, text with numeric collation.
public enum ReportSortKey: Sendable, Hashable {
    case number(Double)
    case text(String)

    /// nil sorts last in either direction, as the web reports do.
    public static func compare(_ a: ReportSortKey?, _ b: ReportSortKey?, ascending: Bool) -> ComparisonResult {
        switch (a, b) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (a?, b?):
            let r: ComparisonResult
            switch (a, b) {
            case let (.number(x), .number(y)): r = x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame
            case let (.text(x), .text(y)): r = x.localizedStandardCompare(y)
            case (.number, .text): r = .orderedAscending
            case (.text, .number): r = .orderedDescending
            }
            if r == .orderedSame { return r }
            return ascending ? r : (r == .orderedAscending ? .orderedDescending : .orderedAscending)
        }
    }

    public static func time(_ text: String?) -> ReportSortKey? {
        FlexibleDate.parse(text).map { .number($0.timeIntervalSince1970) }
    }

    public static func string(_ text: String?) -> ReportSortKey? {
        guard let text, !text.isEmpty else { return nil }
        return .text(text)
    }
}

/// How a column's cell draws its value.
public enum ReportColumnKind: Sendable, Hashable {
    case device, text, mono, time, state, number
}

/// One table column: label, display/CSV text and sort key.
public struct ReportColumn<Row>: Identifiable, @unchecked Sendable {
    public let key: String
    public let label: String
    public let kind: ReportColumnKind
    /// Display text; nil reads as the column's unknown text.
    public let value: (Row) -> String?
    public let sortKey: (Row) -> ReportSortKey?
    /// The text a missing value shows: "Not reported", "Unknown", "Not applicable".
    public let missing: String
    /// A second, smaller line under the value (an explanation for an unknown state).
    public let detail: ((Row) -> String?)?

    public var id: String { key }

    public init(_ key: String, _ label: String, kind: ReportColumnKind = .text, missing: String? = nil,
                value: @escaping (Row) -> String?, sortKey: ((Row) -> ReportSortKey?)? = nil, detail: ((Row) -> String?)? = nil) {
        self.key = key
        self.label = label
        self.kind = kind
        self.value = value
        self.missing = missing ?? (kind == .time ? "Unknown" : kind == .state ? "Unknown" : "Not reported")
        self.detail = detail
        if let sortKey {
            self.sortKey = sortKey
        } else if kind == .time {
            self.sortKey = { ReportSortKey.time(value($0)) }
        } else {
            self.sortKey = { ReportSortKey.string(value($0)) }
        }
    }

    /// The column's text for a row, its missing text when there is no value.
    public func text(_ row: Row) -> String { value(row) ?? missing }
}

public enum ReportSorting {
    /// Rows sorted by `column`, unknown values last, ties broken by `tiebreak`.
    public static func sort<Row>(_ rows: [Row], by column: ReportColumn<Row>?, ascending: Bool, tiebreak: (Row) -> String) -> [Row] {
        guard let column else { return rows }
        let keyed = rows.map { (row: $0, key: column.sortKey($0), tie: tiebreak($0)) }
        return keyed.sorted { a, b in
            let r = ReportSortKey.compare(a.key, b.key, ascending: ascending)
            if r != .orderedSame { return r == .orderedAscending }
            return a.tie.localizedStandardCompare(b.tie) == .orderedAscending
        }.map(\.row)
    }
}

/// The visible columns, sort column and direction a report keeps in `columns`, `sort`, `direction`.
public struct ReportView: Sendable, Hashable {
    public var columns: [String]
    public var sort: String
    public var ascending: Bool

    public init(params: ReportParams, available: [String], defaults: [String], defaultSort: String = "deviceName",
                defaultAscending: Bool = true, sortKey: String = "sort", directionKey: String = "direction", alwaysShown: String? = "deviceName") {
        let requested = params.has("columns") ? params.list("columns") : defaults
        let visible = available.filter { $0 == alwaysShown || requested.contains($0) }
        columns = visible
        let requestedSort = params[sortKey]
        sort = requestedSort.flatMap { s in visible.contains(s) || alwaysShown == nil ? s : nil } ?? defaultSort
        if let d = params[directionKey] { ascending = d != "desc" } else { ascending = defaultAscending }
    }
}

// MARK: - CSV

public enum SubReportCSV {
    public static func text(headers: [String], rows: [[String?]]) -> String {
        CSVText.encode(headers: headers, rows: rows.map { $0.map { $0 ?? "" } })
    }

    public static func number(_ value: Int?) -> String? { value.map(String.init) }
}

// MARK: - Paged loading

public enum SubReportError: LocalizedError, Sendable, Equatable {
    case notAvailable
    case malformed(String)
    case changed
    case incomplete
    case tooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .notAvailable: return "This report is not available on this server yet."
        case .malformed(let what): return "The \(what) could not be read. Please retry."
        case .changed: return "The report changed while loading. Please retry."
        case .incomplete: return "The report returned an incomplete page. Please retry."
        case .tooLarge(let n): return "This report has \(n.formatted()) rows. Select fewer items or narrow the filters."
        }
    }
}

/// Loads every page of a bounded, paged report. A report that changes between pages
/// is rejected rather than shown partially, as the web does.
public enum PagedReport {
    /// - Returns: the first page's envelope and every row.
    public static func loadAll(rowsKey: String, pageSize: Int, maxRows: Int? = nil,
                               fetch: (_ offset: Int, _ limit: Int) async throws -> JSONValue,
                               progress: (@Sendable (_ loaded: Int, _ total: Int) -> Void)? = nil) async throws -> (envelope: JSONValue, rows: [JSONValue]) {
        var rows: [JSONValue] = []
        var envelope: JSONValue?
        var total: Int?
        repeat {
            let page = try await fetch(rows.count, pageSize)
            if page.isNull { throw SubReportError.notAvailable }
            guard let pageRows = page[rowsKey].array, let pageTotal = page["total"].int, pageTotal >= 0 else { throw SubReportError.malformed("report") }
            if let offset = page["offset"].int, offset != rows.count { throw SubReportError.changed }
            if let total, total != pageTotal { throw SubReportError.changed }
            if let maxRows, pageTotal > maxRows { throw SubReportError.tooLarge(pageTotal) }
            total = pageTotal
            if envelope == nil { envelope = page }
            if page["queryRequired"].bool == true { break }
            if pageRows.isEmpty, rows.count < pageTotal { throw SubReportError.incomplete }
            rows.append(contentsOf: pageRows)
            if rows.count > pageTotal { throw SubReportError.changed }
            progress?(rows.count, pageTotal)
            try Task.checkCancellation()
        } while rows.count < (total ?? 0)
        guard let envelope else { throw SubReportError.malformed("report") }
        return (envelope, rows)
    }
}

/// A selection the reports offer: a value, its label and the devices that report it.
public struct ReportChoice: Sendable, Hashable, Identifiable {
    public var value: String
    public var label: String
    public var devices: Int?
    public var id: String { value }
    public init(value: String, label: String, devices: Int? = nil) {
        self.value = value
        self.label = label
        self.devices = devices
    }
}
