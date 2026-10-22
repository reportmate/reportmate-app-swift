import Foundation

/// The management tools' logs across the fleet: `GET /api/v1/management/logs/fleet`
/// (`?hours=24|168&tool=&level=error|warning&message=&platform=`). Per tool, the
/// devices with errors and warnings, their lines, when last seen and a trend; the
/// commonest messages, normalised; and the devices behind them. The MDM agent's own
/// logs are left out, the same rule as the dashboard card.
///
/// Until a server has that endpoint, `init(card:)` builds the same shape from the
/// dashboard's Management Tools Logs card (24 hours, tools and top messages, one
/// example device per message), and `isPartial` says so.
public struct ManagementToolsFleet: Sendable, Hashable {
    public struct TrendPoint: Sendable, Hashable {
        public var at: String
        public var errors: Int
        public var warnings: Int
    }

    public struct Tool: Sendable, Hashable, Identifiable {
        public var id: String { "\(tool)|\(platform ?? "")" }
        public var tool: String
        public var name: String
        public var platform: String?
        public var devices: Int
        public var devicesWithErrors: Int
        public var devicesWithWarnings: Int
        public var errorLines: Int
        public var warningLines: Int
        public var lastSeen: Date?
        public var trend: [TrendPoint]
    }

    public struct Message: Sendable, Hashable, Identifiable {
        public var id: String
        public var message: String
        public var tool: String
        public var name: String
        public var level: String
        public var devices: Int
        public var lines: Int
        public var lastSeen: Date?
    }

    public struct Device: Sendable, Hashable, Identifiable {
        public var id: String { "\(serialNumber)|\(tool)" }
        public var serialNumber: String
        public var deviceName: String
        public var platform: String?
        public var tool: String
        public var name: String
        public var errors: Int
        public var warnings: Int
        public var lastAt: Date?
        /// The messages this device logged, by `Message.id`.
        public var messageIds: [String]
    }

    public var hours: Int
    public var tools: [Tool]
    public var messages: [Message]
    public var devices: [Device]
    /// Built from the dashboard card: 24 hours only, one example device per message.
    public var isPartial: Bool

    /// A message's id: the server's, or its normalised text folded, so `?message=` survives a refresh.
    public static func messageID(tool: String, message: String) -> String {
        let folded = ManagementToolMessages.normalize(message).lowercased()
            .replacingOccurrences(of: #"[^a-z0-9<>]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(tool):\(folded.prefix(80))"
    }

    public init(hours: Int = 24, tools: [Tool] = [], messages: [Message] = [], devices: [Device] = [], isPartial: Bool = false) {
        self.hours = hours
        self.tools = tools
        self.messages = messages
        self.devices = devices
        self.isPartial = isPartial
    }

    /// The fleet endpoint's answer.
    public init(json: JSONValue) {
        let j = json["data"].object != nil ? json["data"] : json
        hours = j.first("hours", "windowHours").int ?? 24
        tools = j["tools"].elements.compactMap(Self.tool).filter { !ManagementToolMessages.isMDMAgent($0.tool) }
        messages = j.first("messages", "topErrors").elements.compactMap(Self.message).filter { !ManagementToolMessages.isMDMAgent($0.tool) }
        devices = j["devices"].elements.compactMap(Self.device).filter { !ManagementToolMessages.isMDMAgent($0.tool) }
        isPartial = false
    }

    /// The dashboard card's answer, as the report's shape (see the type comment).
    public init(card: InsightCardData) {
        hours = card.int("windowHours") ?? 24
        tools = ManagementToolMessages.tools(card).compactMap { Self.tool($0.json) }
        var messages: [Message] = []
        var devices: [String: Device] = [:]
        for group in ManagementToolMessages.topErrors(card) {
            let tool = group.item.string("tool") ?? ""
            let id = Self.messageID(tool: tool, message: group.message)
            messages.append(Message(id: id, message: group.message, tool: tool, name: group.item.string("name") ?? tool, level: "error",
                                    devices: group.devices, lines: group.lines, lastSeen: nil))
            if let serial = group.item.item("sampleDevice")?.string("serialNumber") {
                let key = "\(serial)|\(tool)"
                var d = devices[key] ?? Device(serialNumber: serial, deviceName: serial, platform: nil, tool: tool, name: group.item.string("name") ?? tool,
                                               errors: 0, warnings: 0, lastAt: nil, messageIds: [])
                d.errors += 1
                d.messageIds.append(id)
                devices[key] = d
            }
        }
        self.messages = messages
        self.devices = devices.values.sorted { $0.serialNumber < $1.serialNumber }
        isPartial = true
    }

    /// Narrowed by the report's filters. `level` keeps tools and devices with that level and messages of it.
    public func filtered(tool: String?, level: String?, message: String?) -> ManagementToolsFleet {
        var out = self
        if let tool { out.tools = out.tools.filter { $0.tool == tool }; out.messages = out.messages.filter { $0.tool == tool }; out.devices = out.devices.filter { $0.tool == tool } }
        switch level {
        case "error":
            out.tools = out.tools.filter { $0.devicesWithErrors > 0 }
            out.messages = out.messages.filter { $0.level == "error" }
            out.devices = out.devices.filter { $0.errors > 0 }
        case "warning":
            out.tools = out.tools.filter { $0.devicesWithWarnings > 0 }
            out.messages = out.messages.filter { $0.level == "warning" }
            out.devices = out.devices.filter { $0.warnings > 0 }
        default: break
        }
        if let message { out.devices = out.devices.filter { $0.messageIds.contains(message) } }
        return out
    }

    static func tool(_ t: JSONValue) -> Tool? {
        guard let tool = t["tool"].nonEmptyString else { return nil }
        return Tool(tool: tool, name: t["name"].nonEmptyString ?? tool, platform: t["platform"].nonEmptyString,
                    devices: t["devices"].int ?? 0, devicesWithErrors: t["devicesWithErrors"].int ?? 0, devicesWithWarnings: t["devicesWithWarnings"].int ?? 0,
                    errorLines: t["errorLines"].int ?? 0, warningLines: t["warningLines"].int ?? 0, lastSeen: FlexibleDate.parse(t["lastSeen"]),
                    trend: t["trend"].elements.map { TrendPoint(at: $0.firstString("at", "hour", "day") ?? "", errors: $0["errors"].int ?? 0, warnings: $0["warnings"].int ?? 0) })
    }

    static func message(_ m: JSONValue) -> Message? {
        guard let text = m["message"].nonEmptyString else { return nil }
        let tool = m["tool"].string ?? ""
        let normalised = ManagementToolMessages.normalize(text)
        return Message(id: m["id"].nonEmptyString ?? messageID(tool: tool, message: text), message: normalised, tool: tool,
                       name: m["name"].nonEmptyString ?? tool, level: (m["level"].string ?? "error").lowercased(),
                       devices: m["devices"].int ?? 0, lines: m["lines"].int ?? 0, lastSeen: FlexibleDate.parse(m["lastSeen"]))
    }

    static func device(_ d: JSONValue) -> Device? {
        guard let serial = d["serialNumber"].nonEmptyString else { return nil }
        let tool = d["tool"].string ?? ""
        return Device(serialNumber: serial, deviceName: d["deviceName"].nonEmptyString ?? d["name"].nonEmptyString ?? serial, platform: d["platform"].nonEmptyString,
                      tool: tool, name: d["toolName"].nonEmptyString ?? tool, errors: d["errors"].int ?? 0, warnings: d["warnings"].int ?? 0,
                      lastAt: FlexibleDate.parse(d.first("lastAt", "lastSeen")), messageIds: d["messageIds"].elements.compactMap(\.nonEmptyString))
    }
}
