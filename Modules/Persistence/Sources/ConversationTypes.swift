import Foundation

public enum ConversationType: String, Codable, Sendable {
    case single
    case group
}

public struct ConversationThread: Identifiable, Codable, Sendable {
    public let id: String
    public let type: ConversationType
    public let participantIds: [UUID]
    public var title: String
    public var lastMessage: String
    public var lastTimestamp: Date
    public var unreadCount: Int

    public init(
        id: String,
        type: ConversationType,
        participantIds: [UUID],
        title: String,
        lastMessage: String = "",
        lastTimestamp: Date = Date(),
        unreadCount: Int = 0
    ) {
        self.id = id
        self.type = type
        self.participantIds = participantIds
        self.title = title
        self.lastMessage = lastMessage
        self.lastTimestamp = lastTimestamp
        self.unreadCount = unreadCount
    }
}
