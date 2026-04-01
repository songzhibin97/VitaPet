import ChatUI
import XCTest

final class ChatMessageTests: XCTestCase {
    func testConstruction_userRole() {
        let message = ChatMessage(role: .user, content: "Hello")

        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.content, "Hello")
    }

    func testConstruction_assistantRole() {
        let message = ChatMessage(role: .assistant, content: "Hi")

        XCTAssertEqual(message.role, .assistant)
        XCTAssertEqual(message.content, "Hi")
    }

    func testDefaultId_isUnique() {
        let first = ChatMessage(role: .user, content: "One")
        let second = ChatMessage(role: .user, content: "Two")

        XCTAssertNotEqual(first.id, second.id)
    }

    func testTwoMessages_haveDifferentIds() {
        let first = ChatMessage(role: .assistant, content: "One")
        let second = ChatMessage(role: .assistant, content: "Two")

        XCTAssertNotEqual(first.id, second.id)
    }

    func testDefaultTimestamp_isRecent() {
        let message = ChatMessage(role: .system, content: "Now")

        XCTAssertLessThan(abs(message.timestamp.timeIntervalSinceNow), 1.0)
    }

    func testRoleRawValues() {
        XCTAssertEqual(ChatMessage.Role.user.rawValue, "user")
        XCTAssertEqual(ChatMessage.Role.assistant.rawValue, "assistant")
        XCTAssertEqual(ChatMessage.Role.system.rawValue, "system")
    }

    func testConstruction_petMetadataDefaultsToNil() {
        let message = ChatMessage(role: .assistant, content: "Hi")

        XCTAssertNil(message.petId)
        XCTAssertNil(message.petName)
    }

    func testConstruction_petMetadataCanBeProvided() {
        let petId = UUID()
        let message = ChatMessage(role: .assistant, content: "Hi", petId: petId, petName: "Mochi")

        XCTAssertEqual(message.petId, petId)
        XCTAssertEqual(message.petName, "Mochi")
    }
}
