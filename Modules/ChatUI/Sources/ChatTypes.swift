import Foundation

/// 与 `AIEngine` 中保持结构一致的聊天模型定义。
/// ChatUI 通过闭包接收 AI 回调，避免直接依赖 `AIEngine` 模块。
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

public enum AIEngineStatus: Equatable, Sendable {
    case notConfigured
    case connecting
    case ready
    case error(String)
}
