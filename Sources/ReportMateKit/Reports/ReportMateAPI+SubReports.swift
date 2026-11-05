import Foundation

/// The fleet sub-report endpoints. Each report loads every page through bounded
/// requests; a selections endpoint (`/filters`) lists the values actually collected.
extension ReportMateAPI {
    public typealias ReportProgress = @Sendable (_ loaded: Int, _ total: Int) -> Void

    private func catalog<T>(_ path: String, query: [String: String], what: String, parse: (JSONValue) -> T?) async throws -> T {
        let json = try await getJSON(path, query: query)
        if json.isNull { throw SubReportError.notAvailable }
        guard let value = parse(json) else { throw SubReportError.malformed("\(what) selections") }
        return value
    }

    private func paged(_ path: String, query: [String: String], rowsKey: String, pageSize: Int, maxRows: Int? = nil, progress: ReportProgress?) async throws -> (envelope: JSONValue, rows: [JSONValue]) {
        try await PagedReport.loadAll(rowsKey: rowsKey, pageSize: pageSize, maxRows: maxRows, fetch: { offset, limit in
            var q: [String: String?] = query.mapValues { Optional($0) }
            q["offset"] = String(offset)
            q["limit"] = String(limit)
            return try await self.getJSON(path, query: q)
        }, progress: progress)
    }

    // MARK: System

    public func serviceCatalog(query: [String: String]) async throws -> ServiceCatalog {
        try await catalog(ServicesReportSpec.api + "/filters", query: query, what: "service", parse: ServiceCatalog.init(json:))
    }

    public func servicesReport(query: [String: String], progress: ReportProgress? = nil) async throws -> ServicesReportData {
        let page = try await paged(ServicesReportSpec.api, query: query, rowsKey: "devices", pageSize: 500, progress: progress)
        return ServicesReportData(envelope: page.envelope, rows: page.rows)
    }

    public func updateCatalog(query: [String: String]) async throws -> UpdateCatalog {
        try await catalog(UpdatesReportSpec.api + "/filters", query: query, what: "update", parse: UpdateCatalog.init(json:))
    }

    public func updatesReport(query: [String: String], progress: ReportProgress? = nil) async throws -> UpdatesReportData {
        let page = try await paged(UpdatesReportSpec.api, query: query, rowsKey: "rows", pageSize: UpdatesReportSpec.pageSize, progress: progress)
        return UpdatesReportData(envelope: page.envelope, rows: page.rows)
    }

    public func itemCatalog(_ spec: ItemReportSpec, query: [String: String]) async throws -> ItemCatalog {
        try await catalog(spec.api + "/filters", query: query, what: "report", parse: ItemCatalog.init(json:))
    }

    public func itemReport(_ spec: ItemReportSpec, query: [String: String], progress: ReportProgress? = nil) async throws -> ItemReportData {
        let page = try await paged(spec.api, query: query, rowsKey: "rows", pageSize: ItemReportSpec.pageSize, maxRows: ItemReportSpec.maxRows, progress: progress)
        return ItemReportData(envelope: page.envelope, rows: page.rows)
    }

    // MARK: Management

    public func profileCatalog(query: [String: String]) async throws -> ProfileCatalog {
        try await catalog(ProfilesReportSpec.api + "/filters", query: query, what: "profile", parse: ProfileCatalog.init(json:))
    }

    public func profilesReport(query: [String: String], progress: ReportProgress? = nil) async throws -> ProfilesReportData {
        let page = try await paged(ProfilesReportSpec.api, query: query, rowsKey: "devices", pageSize: ProfilesReportSpec.pageSize, progress: progress)
        return ProfilesReportData(envelope: page.envelope, rows: page.rows)
    }

    // MARK: Security

    public func vulnerabilityCatalog(query: [String: String]) async throws -> VulnerabilityCatalog {
        try await catalog(VulnerabilitiesReportSpec.api + "/filters", query: query, what: "CVE", parse: VulnerabilityCatalog.init(json:))
    }

    public func vulnerabilitySummary(query: [String: String]) async throws -> VulnerabilitySummaryData {
        try await catalog(VulnerabilitiesReportSpec.api, query: query, what: "CVE summary", parse: VulnerabilitySummaryData.init(json:))
    }

    public func vulnerabilityDevices(query: [String: String], progress: ReportProgress? = nil) async throws -> VulnerabilityDevicesData {
        let page = try await paged(VulnerabilitiesReportSpec.api, query: query, rowsKey: "rows", pageSize: VulnerabilitiesReportSpec.pageSize, progress: progress)
        return VulnerabilityDevicesData(envelope: page.envelope, rows: page.rows)
    }

    public func detectionCatalog(query: [String: String]) async throws -> DetectionCatalog {
        try await catalog(DetectionsReportSpec.api + "/filters", query: query, what: "detection", parse: DetectionCatalog.init(json:))
    }

    public func detectionsReport(query: [String: String], progress: ReportProgress? = nil) async throws -> DetectionsData {
        let page = try await paged(DetectionsReportSpec.api, query: query, rowsKey: "rows", pageSize: DetectionsReportSpec.pageSize, progress: progress)
        return DetectionsData(envelope: page.envelope, rows: page.rows)
    }

    // MARK: Identity

    public func postureReport(query: [String: String], progress: ReportProgress? = nil) async throws -> PostureReportData {
        let page = try await paged(PostureReportSpec.api, query: query, rowsKey: "devices", pageSize: PostureReportSpec.pageSize, progress: progress)
        return PostureReportData(envelope: page.envelope, rows: page.rows)
    }
}
