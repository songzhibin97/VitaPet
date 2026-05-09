import Foundation

/// AI 消息模型
public struct ChatMessage: Identifiable, Sendable {
    public let id: UUID
    public let role: Role
    public let content: String
    public let timestamp: Date
    public let petId: UUID?
    public let petName: String?

    public enum Role: String, Sendable {
        case user
        case assistant
        case system
    }

    public init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        timestamp: Date = Date(),
        petId: UUID? = nil,
        petName: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.petId = petId
        self.petName = petName
    }
}

/// AI 引擎状态
public enum AIEngineStatus: Sendable {
    case notConfigured
    case connecting
    case ready
    case error(String)
}

public enum AIBackend: String, Codable, Sendable, CaseIterable {
    case ollama
    case openAICompatible = "openai-compatible"

    public var defaultModel: String {
        switch self {
        case .ollama:
            return "llama3.2"
        case .openAICompatible:
            return "gpt-4o-mini"
        }
    }
}

public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
        } else if let intValue = try? container.decode(Int.self) {
            self = .number(Double(intValue))
        } else if let doubleValue = try? container.decode(Double.self) {
            self = .number(doubleValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else if let objectValue = try? container.decode([String: JSONValue].self) {
            self = .object(objectValue)
        } else if let arrayValue = try? container.decode([JSONValue].self) {
            self = .array(arrayValue)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            if value.rounded(.towardZero) == value {
                try container.encode(Int(value))
            } else {
                try container.encode(value)
            }
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    public var stringValue: String? {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            if value.rounded(.towardZero) == value {
                return String(Int(value))
            }
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .object, .array, .null:
            return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .number(let value):
            guard value.rounded(.towardZero) == value else { return nil }
            return Int(value)
        case .string(let value):
            return Int(value)
        case .bool, .object, .array, .null:
            return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .string(let value):
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes":
                return true
            case "false", "0", "no":
                return false
            default:
                return nil
            }
        case .number(let value):
            switch value {
            case 0:
                return false
            case 1:
                return true
            default:
                return nil
            }
        case .object, .array, .null:
            return nil
        }
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self {
            return value
        }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self {
            return value
        }
        return nil
    }

    public static func fromJSONObject(_ value: Any) -> JSONValue? {
        switch value {
        case let stringValue as String:
            return .string(stringValue)
        case let boolValue as Bool:
            return .bool(boolValue)
        case let intValue as Int:
            return .number(Double(intValue))
        case let doubleValue as Double:
            return .number(doubleValue)
        case let floatValue as Float:
            return .number(Double(floatValue))
        case let numberValue as NSNumber:
            if CFGetTypeID(numberValue) == CFBooleanGetTypeID() {
                return .bool(numberValue.boolValue)
            }
            return .number(numberValue.doubleValue)
        case let objectValue as [String: Any]:
            var output: [String: JSONValue] = [:]
            for (key, nestedValue) in objectValue {
                guard let jsonValue = JSONValue.fromJSONObject(nestedValue) else {
                    return nil
                }
                output[key] = jsonValue
            }
            return .object(output)
        case let arrayValue as [Any]:
            let mapped = arrayValue.compactMap(JSONValue.fromJSONObject)
            guard mapped.count == arrayValue.count else { return nil }
            return .array(mapped)
        case _ as NSNull:
            return .null
        default:
            return nil
        }
    }

    public func toJSONObject() -> Any {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            if value.rounded(.towardZero) == value {
                return Int(value)
            }
            return value
        case .bool(let value):
            return value
        case .object(let value):
            return value.mapValues { $0.toJSONObject() }
        case .array(let value):
            return value.map { $0.toJSONObject() }
        case .null:
            return NSNull()
        }
    }

    public func compactJSONString() -> String? {
        guard JSONSerialization.isValidJSONObject(toJSONObject()) else {
            return stringValue
        }
        guard let data = try? JSONSerialization.data(withJSONObject: toJSONObject()) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

public struct OllamaTool: Codable, Sendable {
    public let type: String
    public let function: OllamaToolFunction

    public init(type: String = "function", function: OllamaToolFunction) {
        self.type = type
        self.function = function
    }
}

public struct OllamaToolFunction: Codable, Sendable {
    public let name: String
    public let description: String
    public let parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct PetToolCall: Sendable {
    public let id: String?
    public let functionName: String
    public let arguments: [String: JSONValue]

    public init(id: String? = nil, functionName: String, arguments: [String: JSONValue]) {
        self.id = id
        self.functionName = functionName
        self.arguments = arguments
    }
}

public enum MCPTransportType: String, Codable, Sendable, Equatable {
    case stdio
    case streamableHTTP = "streamable_http"
}

public struct MCPServerConfiguration: Codable, Sendable, Equatable {
    public let name: String
    public let transport: MCPTransportType
    public let command: String
    public let args: [String]
    public let env: [String: String]
    public let workingDirectory: String?
    public let url: String
    public let headers: [String: String]
    public let enabled: Bool

    public init(
        name: String,
        transport: MCPTransportType = .stdio,
        command: String = "",
        args: [String] = [],
        env: [String: String] = [:],
        workingDirectory: String? = nil,
        url: String = "",
        headers: [String: String] = [:],
        enabled: Bool = true
    ) {
        self.name = name
        self.transport = transport
        self.command = command
        self.args = args
        self.env = env
        self.workingDirectory = workingDirectory
        self.url = url
        self.headers = headers
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case transport = "type"
        case command
        case args
        case env
        case workingDirectory
        case url
        case headers
        case enabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        name = try container.decode(String.self, forKey: .name)
        transport = try container.decodeIfPresent(MCPTransportType.self, forKey: .transport) ?? .stdio
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(transport, forKey: .transport)
        try container.encode(command, forKey: .command)
        try container.encode(args, forKey: .args)
        try container.encode(env, forKey: .env)
        try container.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
        try container.encode(url, forKey: .url)
        try container.encode(headers, forKey: .headers)
        try container.encode(enabled, forKey: .enabled)
    }
}

public struct PetProfileInfo: Sendable {
    public let id: UUID
    public let name: String
    public let gender: String
    public let age: String
    public let personality: String
    public let hobbies: String

    public init(id: UUID, name: String, gender: String, age: String, personality: String, hobbies: String) {
        self.id = id
        self.name = name
        self.gender = gender
        self.age = age
        self.personality = personality
        self.hobbies = hobbies
    }
}

public extension OllamaTool {
    static func petActionTool(availableActions: [String]) -> OllamaTool {
        OllamaTool(
            function: OllamaToolFunction(
                name: "pet_action",
                description: "Make the pet perform an action. Use this to express emotions.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "action": .object([
                            "type": .string("string"),
                            "description": .string("The action for the pet to perform"),
                            "enum": .array(availableActions.map(JSONValue.string))
                        ]),
                        "count": .object([
                            "type": .string("integer"),
                            "description": .string("Optional repeat count for actions that support it (e.g. somersault). Default 1, max 8.")
                        ])
                    ]),
                    "required": .array([.string("action")])
                ])
            )
        )
    }

    static func mcpTool(name: String, description: String, inputSchema: JSONValue) -> OllamaTool {
        OllamaTool(
            function: OllamaToolFunction(
                name: name,
                description: description,
                parameters: inputSchema
            )
        )
    }
}

public extension MCPServerConfiguration {
    static func decodeList(from json: String) throws -> [MCPServerConfiguration] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        let data = Data(trimmed.utf8)
        let decoder = JSONDecoder()

        if let array = try? decoder.decode([MCPServerConfiguration].self, from: data) {
            return array
        }

        if let wrapper = try? decoder.decode(NamedServerCollection.self, from: data) {
            return wrapper.serverConfigurations
        }

        if let dictionary = try? decoder.decode([String: NamedServerDefinition].self, from: data) {
            return dictionary
                .sorted { $0.key < $1.key }
                .map { $0.value.resolved(named: $0.key) }
        }

        return try decoder.decode([MCPServerConfiguration].self, from: data)
    }

    private struct NamedServerCollection: Decodable {
        let mcpServers: [String: NamedServerDefinition]

        var serverConfigurations: [MCPServerConfiguration] {
            mcpServers
                .sorted { $0.key < $1.key }
                .map { $0.value.resolved(named: $0.key) }
        }
    }

    private struct NamedServerDefinition: Decodable {
        let transport: MCPTransportType?
        let command: String?
        let args: [String]?
        let env: [String: String]?
        let workingDirectory: String?
        let url: String?
        let headers: [String: String]?
        let enabled: Bool?

        private enum CodingKeys: String, CodingKey {
            case transport = "type"
            case command
            case args
            case env
            case workingDirectory
            case url
            case headers
            case enabled
        }

        func resolved(named name: String) -> MCPServerConfiguration {
            MCPServerConfiguration(
                name: name,
                transport: transport ?? .stdio,
                command: command ?? "",
                args: args ?? [],
                env: env ?? [:],
                workingDirectory: workingDirectory,
                url: url ?? "",
                headers: headers ?? [:],
                enabled: enabled ?? true
            )
        }
    }
}

/// AI 引擎协议（Phase 2 实现）
public protocol AIEngineProtocol: Sendable {
    func send(message: String) async throws -> AsyncThrowingStream<String, Error>
    var status: AIEngineStatus { get async }
}
