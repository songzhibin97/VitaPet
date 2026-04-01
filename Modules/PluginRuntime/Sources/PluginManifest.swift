public struct PluginManifest: Codable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let description: String
    public let capabilities: [String]
    public let triggers: [TriggerRule]

    public init(
        id: String,
        name: String,
        version: String,
        description: String,
        capabilities: [String],
        triggers: [TriggerRule]
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.capabilities = capabilities
        self.triggers = triggers
    }
}

public struct TriggerRule: Codable, Sendable {
    public let event: String
    public let conditions: [String: String]
    public let actions: [PluginAction]

    public init(event: String, conditions: [String: String], actions: [PluginAction]) {
        self.event = event
        self.conditions = conditions
        self.actions = actions
    }
}

public struct PluginAction: Codable, Sendable {
    public let type: String
    public let state: String?
    public let message: String?
    public let title: String?
    public let name: String?
    public let delta: String?
    public let payload: [String: String]?

    public init(
        type: String,
        state: String? = nil,
        message: String? = nil,
        title: String? = nil,
        name: String? = nil,
        delta: String? = nil,
        payload: [String: String]? = nil
    ) {
        self.type = type
        self.state = state
        self.message = message
        self.title = title
        self.name = name
        self.delta = delta
        self.payload = payload
    }
}
