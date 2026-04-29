import ChatUI
import Persistence
import XCTest

@MainActor
final class ChatViewModelTests: XCTestCase {
    func testLoadConversations_selectsFirstByDefault() {
        let viewModel = ChatViewModel()
        let first = ConversationThread(id: "c1", type: .single, participantIds: [UUID()], title: "First")
        let second = ConversationThread(id: "c2", type: .group, participantIds: [UUID(), UUID()], title: "Second")

        viewModel.loadConversations([first, second])

        XCTAssertEqual(viewModel.conversations.map(\.id), ["c1", "c2"])
        XCTAssertEqual(viewModel.selectedConversationId, "c1")
        XCTAssertTrue(viewModel.messages.isEmpty)
    }

    func testSelectConversation_switchesCurrentMessages() {
        let viewModel = ChatViewModel()
        let first = ConversationThread(id: "c1", type: .single, participantIds: [UUID()], title: "First")
        let second = ConversationThread(id: "c2", type: .single, participantIds: [UUID()], title: "Second")
        let firstMessage = ChatMessage(role: .user, content: "First message")
        let secondMessage = ChatMessage(role: .assistant, content: "Second message")

        viewModel.loadConversations([first, second])
        viewModel.loadMessages(for: "c1", messages: [firstMessage])
        viewModel.loadMessages(for: "c2", messages: [secondMessage])

        XCTAssertEqual(viewModel.messages.map(\.content), ["First message"])

        viewModel.selectConversation("c2")

        XCTAssertEqual(viewModel.selectedConversationId, "c2")
        XCTAssertEqual(viewModel.messages.map(\.content), ["Second message"])
    }

    func testCreateGroupChat_addsConversationAndInvokesCallback() {
        let viewModel = ChatViewModel()
        let participantIds = [UUID(), UUID()]
        var createdTitle: String?
        var createdParticipants: [UUID]?
        viewModel.onCreateGroup = { title, ids in
            createdTitle = title
            createdParticipants = ids
        }

        let thread = viewModel.createGroupChat(title: "Group", participantIds: participantIds)

        XCTAssertEqual(thread.type, .group)
        XCTAssertEqual(thread.title, "Group")
        XCTAssertEqual(thread.participantIds, participantIds)
        XCTAssertTrue(thread.id.hasPrefix("group_"))
        XCTAssertTrue(viewModel.conversations.contains(where: { $0.id == thread.id }))
        XCTAssertEqual(createdTitle, "Group")
        XCTAssertEqual(createdParticipants, participantIds)
        XCTAssertEqual(viewModel.selectedConversationId, thread.id)
        XCTAssertTrue(viewModel.messages.isEmpty)
    }

    func testDeleteConversation_updatesSelectedConversationAndMessages() {
        let viewModel = ChatViewModel()
        let first = ConversationThread(id: "c1", type: .single, participantIds: [UUID()], title: "First")
        let second = ConversationThread(id: "c2", type: .group, participantIds: [UUID(), UUID()], title: "Second")
        viewModel.loadConversations([first, second])
        viewModel.loadMessages(for: "c1", messages: [ChatMessage(role: .user, content: "one")])
        viewModel.loadMessages(for: "c2", messages: [ChatMessage(role: .assistant, content: "two")])
        viewModel.selectConversation("c2")

        viewModel.deleteConversation("c2")

        XCTAssertEqual(viewModel.conversations.map(\.id), ["c1"])
        XCTAssertEqual(viewModel.selectedConversationId, "c1")
        XCTAssertEqual(viewModel.messages.map(\.content), ["one"])
    }

    func testMessages_emptyByDefault() {
        let viewModel = ChatViewModel()

        XCTAssertTrue(viewModel.messages.isEmpty)
    }

    func testAiStatus_defaultIsNotConfigured() {
        let viewModel = ChatViewModel()

        XCTAssertEqual(String(describing: viewModel.aiStatus), String(describing: "notConfigured"))
    }

    func testSendMessage_addsUserMessage() {
        let viewModel = ChatViewModel()
        viewModel.inputText = "Hello"

        viewModel.sendMessage()
        wait(for: viewModel, count: 1)

        XCTAssertEqual(viewModel.messages.first?.role, .user)
        XCTAssertEqual(viewModel.messages.first?.content, "Hello")
    }

    func testSendMessage_clearsInputText() {
        let viewModel = ChatViewModel()
        viewModel.inputText = "Hello"

        viewModel.sendMessage()
        wait(for: viewModel, count: 1)

        XCTAssertEqual(viewModel.inputText, "")
    }

    func testSendMessage_emptyInput_doesNotSend() {
        let viewModel = ChatViewModel()
        viewModel.inputText = "   \n"

        viewModel.sendMessage()

        XCTAssertTrue(viewModel.messages.isEmpty)
    }

    func testSendMessage_addsAssistantReply_whenNotConfigured() {
        let viewModel = ChatViewModel()
        viewModel.inputText = "Hello"

        viewModel.sendMessage()
        wait(for: viewModel, count: 2)

        XCTAssertEqual(viewModel.messages.last?.role, .assistant)
        XCTAssertEqual(viewModel.messages.last?.content, "AI 尚未配置")
    }

    func testSendMessage_messageCountIncreasesBy2() {
        let viewModel = ChatViewModel()
        viewModel.inputText = "Hello"

        viewModel.sendMessage()
        wait(for: viewModel, count: 2)

        XCTAssertEqual(viewModel.messages.count, 2)
    }

    func testSendMessage_preservesOrder() {
        let viewModel = ChatViewModel()
        viewModel.inputText = "Hello"

        viewModel.sendMessage()
        wait(for: viewModel, count: 2)

        XCTAssertEqual(viewModel.messages.map(\.role), [.user, .assistant])
    }

    func testSendMessage_multipleMessages_accumulate() {
        let viewModel = ChatViewModel()
        viewModel.inputText = "First"
        viewModel.sendMessage()
        wait(for: viewModel, count: 2)
        viewModel.inputText = "Second"
        viewModel.sendMessage()
        wait(for: viewModel, count: 4)

        XCTAssertEqual(viewModel.messages.count, 4)
        XCTAssertEqual(viewModel.messages[0].content, "First")
        XCTAssertEqual(viewModel.messages[2].content, "Second")
    }

    func testSendMessage_streamsAssistantReply() {
        let expectation = XCTestExpectation(description: "assistant replied")
        let viewModel = ChatViewModel(
            sendToAI: { _, _ in
                (streamID: UUID(), stream: AsyncThrowingStream { continuation in
                    continuation.yield("Hello")
                    continuation.yield(", ")
                    continuation.yield("World")
                    continuation.finish()
                })
            },
            getAIStatus: { .ready }
        )
        viewModel.onAssistantReplied = {
            expectation.fulfill()
        }

        viewModel.inputText = "Hi"
        viewModel.sendMessage()
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(viewModel.messages.last?.role, .assistant)
        XCTAssertEqual(viewModel.messages.last?.content, "Hello, World")
    }

    func testSendMessage_storesMessagesInSelectedConversation() {
        let expectation = XCTestExpectation(description: "assistant replied")
        let viewModel = ChatViewModel(
            sendToAI: { _, _ in
                (streamID: UUID(), stream: AsyncThrowingStream { continuation in
                    continuation.yield("reply")
                    continuation.finish()
                })
            },
            getAIStatus: { .ready }
        )
        let thread = ConversationThread(id: "c1", type: .single, participantIds: [UUID()], title: "Chat 1")
        viewModel.loadConversations([thread])
        viewModel.onAssistantReplied = {
            expectation.fulfill()
        }

        viewModel.inputText = "hello"
        viewModel.sendMessage()
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(viewModel.selectedConversationId, "c1")
        XCTAssertEqual(viewModel.messages.map(\.content), ["hello", "reply"])
        XCTAssertEqual(viewModel.conversations.first?.lastMessage, "reply")
    }

    func testSwitchingConversation_updatesCurrentMessagesAfterSending() {
        let replyExpectation = XCTestExpectation(description: "assistant replied")
        let viewModel = ChatViewModel(
            sendToAI: { input, _ in
                (streamID: UUID(), stream: AsyncThrowingStream { continuation in
                    continuation.yield("reply to \(input)")
                    continuation.finish()
                })
            },
            getAIStatus: { .ready }
        )
        let first = ConversationThread(id: "c1", type: .single, participantIds: [UUID()], title: "First")
        let second = ConversationThread(id: "c2", type: .single, participantIds: [UUID()], title: "Second")
        viewModel.loadConversations([first, second])
        viewModel.loadMessages(for: "c2", messages: [ChatMessage(role: .assistant, content: "existing")])
        viewModel.onAssistantReplied = {
            replyExpectation.fulfill()
        }

        viewModel.inputText = "hello"
        viewModel.sendMessage()
        wait(for: [replyExpectation], timeout: 1.0)
        XCTAssertEqual(viewModel.messages.map(\.content), ["hello", "reply to hello"])

        viewModel.selectConversation("c2")

        XCTAssertEqual(viewModel.messages.map(\.content), ["existing"])
    }

    func testInputText_defaultIsEmpty() {
        let viewModel = ChatViewModel()

        XCTAssertEqual(viewModel.inputText, "")
    }

    func testAddAssistantMessage_preservesPetMetadata() {
        let viewModel = ChatViewModel()
        let petId = UUID()

        viewModel.addAssistantMessage("Hi", petId: petId, petName: "Mochi")

        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(viewModel.messages[0].role, .assistant)
        XCTAssertEqual(viewModel.messages[0].petId, petId)
        XCTAssertEqual(viewModel.messages[0].petName, "Mochi")
    }

    private func wait(for viewModel: ChatViewModel, count: Int, timeout: TimeInterval = 1.0) {
        let start = Date()
        while viewModel.messages.count < count && Date().timeIntervalSince(start) < timeout {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }

        XCTAssertGreaterThanOrEqual(viewModel.messages.count, count)
    }
}
