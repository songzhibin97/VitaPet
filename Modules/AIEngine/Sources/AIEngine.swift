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
    public let parameters: OllamaToolParameters

    public init(name: String, description: String, parameters: OllamaToolParameters) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct OllamaToolParameters: Codable, Sendable {
    public let type: String
    public let properties: [String: OllamaToolProperty]
    public let required: [String]

    public init(type: String = "object", properties: [String: OllamaToolProperty], required: [String]) {
        self.type = type
        self.properties = properties
        self.required = required
    }
}

public struct OllamaToolProperty: Codable, Sendable {
    public let type: String
    public let description: String
    public let `enum`: [String]?

    private enum CodingKeys: String, CodingKey {
        case type
        case description
        case `enum`
    }

    public init(type: String, description: String, enum: [String]? = nil) {
        self.type = type
        self.description = description
        self.`enum` = `enum`
    }
}

public struct PetToolCall: Sendable {
    public let functionName: String
    public let arguments: [String: String]

    public init(functionName: String, arguments: [String: String]) {
        self.functionName = functionName
        self.arguments = arguments
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
                parameters: OllamaToolParameters(
                    properties: [
                        "action": OllamaToolProperty(
                            type: "string",
                            description: "The action for the pet to perform",
                            enum: availableActions
                        )
                    ],
                    required: ["action"]
                )
            )
        )
    }
}

/// AI 引擎协议（Phase 2 实现）
public protocol AIEngineProtocol: Sendable {
    func send(message: String) async throws -> (streamID: UUID, stream: AsyncThrowingStream<String, Error>)
    var status: AIEngineStatus { get async }
}
