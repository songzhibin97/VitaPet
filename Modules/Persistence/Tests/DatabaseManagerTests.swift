import Persistence
import SQLite3
import XCTest

final class DatabaseManagerTests: XCTestCase {
    private var databaseURL: URL!
    private var manager: DatabaseManager!

    override func setUp() {
        super.setUp()
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        databaseURL = directoryURL.appendingPathComponent("vitapet.db")
        manager = DatabaseManager(databaseURL: databaseURL)
    }

    override func tearDown() {
        if let directoryURL = databaseURL?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        manager = nil
        databaseURL = nil
        super.tearDown()
    }

    func testInitialize_createsTablesWithoutError() async throws {
        try await manager.initialize()

        XCTAssertTrue(try tableExists(named: "events"))
        XCTAssertTrue(try tableExists(named: "pet_state"))
        XCTAssertTrue(try tableExists(named: "conversation_turns"))
        XCTAssertTrue(try tableExists(named: "conversations"))
        XCTAssertTrue(try tableExists(named: "ai_memories"))
        XCTAssertTrue(try columnExists(table: "conversation_turns", column: "pet_id"))
        XCTAssertTrue(try columnExists(table: "conversation_turns", column: "pet_name"))
    }

    func testInitialize_isIdempotent() async throws {
        try await manager.initialize()
        try await manager.initialize()

        XCTAssertTrue(try tableExists(named: "events"))
        XCTAssertTrue(try tableExists(named: "pet_state"))
        XCTAssertTrue(try tableExists(named: "conversation_turns"))
        XCTAssertTrue(try tableExists(named: "conversations"))
        XCTAssertTrue(try tableExists(named: "ai_memories"))
        XCTAssertTrue(try columnExists(table: "conversation_turns", column: "pet_id"))
        XCTAssertTrue(try columnExists(table: "conversation_turns", column: "pet_name"))
    }

    func testInsertEvent_succeeds() async throws {
        try await manager.initialize()

        try await manager.insertEvent(source: "timer", payload: "{\"value\":1}")

        XCTAssertEqual(try eventCount(), 1)
    }

    func testInsertEvent_multipleEvents() async throws {
        try await manager.initialize()

        try await manager.insertEvent(source: "timer", payload: "one")
        try await manager.insertEvent(source: "workspace", payload: "two")

        XCTAssertEqual(try eventCount(), 2)
    }

    func testFetchRecentEvents_returnsNewestFirst() async throws {
        try await manager.initialize()
        try insertEventRow(
            timestamp: "2026-03-26 09:00:00",
            source: "older",
            payload: #"{"message":"older"}"#
        )
        try insertEventRow(
            timestamp: "2026-03-26 10:00:00",
            source: "newer",
            payload: #"{"message":"newer"}"#
        )

        let events = try await manager.fetchRecentEvents(limit: 10, offset: 0)

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map(\.source), ["newer", "older"])
        XCTAssertEqual(events.map(\.payload), [#"{"message":"newer"}"#, #"{"message":"older"}"#])
        XCTAssertEqual(events[0].timestamp, makeExpectedDate("2026-03-26 10:00:00"))
        XCTAssertEqual(events[1].timestamp, makeExpectedDate("2026-03-26 09:00:00"))
    }

    func testFetchRecentEvents_appliesLimitAndOffset() async throws {
        try await manager.initialize()
        try insertEventRow(timestamp: "2026-03-26 08:00:00", source: "first", payload: "1")
        try insertEventRow(timestamp: "2026-03-26 09:00:00", source: "second", payload: "2")
        try insertEventRow(timestamp: "2026-03-26 10:00:00", source: "third", payload: "3")

        let events = try await manager.fetchRecentEvents(limit: 1, offset: 1)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].source, "second")
        XCTAssertEqual(events[0].payload, "2")
    }

    func testSavePetState_insertsRow() async throws {
        try await manager.initialize()

        try await manager.savePetState(
            petId: "pet-1",
            state: "idle",
            x: 10,
            y: 20,
            screenId: "screen-1"
        )

        XCTAssertEqual(try petStateCount(), 1)
    }

    func testSavePetState_upserts() async throws {
        try await manager.initialize()

        try await manager.savePetState(
            petId: "pet-1",
            state: "idle",
            x: 10,
            y: 20,
            screenId: "screen-1"
        )
        try await manager.savePetState(
            petId: "pet-1",
            state: "run",
            x: 30,
            y: 40,
            screenId: "screen-2"
        )

        XCTAssertEqual(try petStateCount(), 1)
    }

    func testLoadPetState_notFound_returnsNil() async throws {
        try await manager.initialize()

        let state = try await manager.loadPetState(petId: "missing")

        XCTAssertNil(state)
    }

    func testLoadPetState_returnsCorrectValues() async throws {
        try await manager.initialize()
        try await manager.savePetState(
            petId: "pet-1",
            state: "sleep",
            x: 100,
            y: 200,
            screenId: "main"
        )

        let state = try await manager.loadPetState(petId: "pet-1")

        XCTAssertEqual(state?.petId, "pet-1")
        XCTAssertEqual(state?.animationState, "sleep")
        XCTAssertEqual(state?.positionX, 100)
        XCTAssertEqual(state?.positionY, 200)
        XCTAssertEqual(state?.screenId, "main")
    }

    func testLoadPetState_afterUpsert_returnsUpdated() async throws {
        try await manager.initialize()
        try await manager.savePetState(
            petId: "pet-1",
            state: "idle",
            x: 1,
            y: 2,
            screenId: "screen-1"
        )
        try await manager.savePetState(
            petId: "pet-1",
            state: "jump",
            x: 3,
            y: 4,
            screenId: "screen-2"
        )

        let state = try await manager.loadPetState(petId: "pet-1")

        XCTAssertEqual(state?.animationState, "jump")
        XCTAssertEqual(state?.positionX, 3)
        XCTAssertEqual(state?.positionY, 4)
        XCTAssertEqual(state?.screenId, "screen-2")
    }

    func testInsertEvent_beforeInitialize_throws() async {
        do {
            try await manager.insertEvent(source: "timer", payload: "payload")
            XCTFail("Expected insertEvent to throw before initialize")
        } catch {
            // Expected: insertion fails because tables don't exist yet
            XCTAssertNotNil(error)
        }
    }

    func testInsertConversationTurnAndFetchRecentTurns_returnsOldestFirst() async throws {
        try await manager.initialize()

        try await manager.insertConversationTurn(role: "user", content: "hello", sessionId: "default")
        try await manager.insertConversationTurn(role: "assistant", content: "world", sessionId: "default")

        let turns = try await manager.fetchRecentTurns(limit: 50)

        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].role, "user")
        XCTAssertEqual(turns[0].content, "hello")
        XCTAssertNil(turns[0].petId)
        XCTAssertNil(turns[0].petName)
        XCTAssertEqual(turns[1].role, "assistant")
        XCTAssertEqual(turns[1].content, "world")
        XCTAssertNil(turns[1].petId)
        XCTAssertNil(turns[1].petName)
    }

    func testInsertConversationTurnAndFetchRecentTurns_roundTripsPetMetadata() async throws {
        try await manager.initialize()

        try await manager.insertConversationTurn(
            role: "assistant",
            content: "hello",
            sessionId: "pet-session",
            petId: "pet-1",
            petName: "Mochi"
        )

        let turns = try await manager.fetchRecentTurns(sessionId: "pet-session", limit: 50)

        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].role, "assistant")
        XCTAssertEqual(turns[0].content, "hello")
        XCTAssertEqual(turns[0].petId, "pet-1")
        XCTAssertEqual(turns[0].petName, "Mochi")
    }

    func testFetchRecentTurns_filtersBySessionId() async throws {
        try await manager.initialize()

        try await manager.insertConversationTurn(role: "user", content: "keep", sessionId: "session-a")
        try await manager.insertConversationTurn(role: "assistant", content: "drop", sessionId: "session-b")

        let turns = try await manager.fetchRecentTurns(sessionId: "session-a", limit: 50)

        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].content, "keep")
    }

    func testDeleteOldTurns_keepsSpecifiedCount() async throws {
        try await manager.initialize()

        try await manager.insertConversationTurn(role: "user", content: "one", sessionId: "default")
        try await manager.insertConversationTurn(role: "assistant", content: "two", sessionId: "default")
        try await manager.insertConversationTurn(role: "user", content: "three", sessionId: "default")

        try await manager.deleteOldTurns(keepLast: 2)
        let turns = try await manager.fetchRecentTurns(limit: 50)

        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns.map(\.content), ["two", "three"])
    }

    func testClearConversation_removesAllTurns() async throws {
        try await manager.initialize()

        try await manager.insertConversationTurn(role: "user", content: "hello", sessionId: "default")
        try await manager.insertConversationTurn(role: "assistant", content: "world", sessionId: "default")

        try await manager.clearConversation()
        let turns = try await manager.fetchRecentTurns(limit: 50)

        XCTAssertTrue(turns.isEmpty)
    }

    func testInsertConversationAndFetchConversations_roundTripsValues() async throws {
        try await manager.initialize()
        let participantIds = [UUID(), UUID()]

        try await manager.insertConversation(
            id: "session-a",
            type: ConversationType.group.rawValue,
            participantIds: participantIds,
            title: "Team Chat"
        )

        let conversations = try await manager.fetchConversations()

        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(conversations[0].id, "session-a")
        XCTAssertEqual(conversations[0].type, .group)
        XCTAssertEqual(conversations[0].participantIds, participantIds)
        XCTAssertEqual(conversations[0].title, "Team Chat")
        XCTAssertEqual(conversations[0].lastMessage, "")
        XCTAssertEqual(conversations[0].unreadCount, 0)
    }

    func testUpdateConversationLastMessage_updatesMessageAndTimestamp() async throws {
        try await manager.initialize()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

        try await manager.insertConversation(
            id: "session-a",
            type: ConversationType.single.rawValue,
            participantIds: [UUID()],
            title: "Direct Chat"
        )
        try await manager.updateConversationLastMessage(
            id: "session-a",
            message: "latest message",
            timestamp: timestamp
        )

        let conversations = try await manager.fetchConversations()

        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(conversations[0].lastMessage, "latest message")
        XCTAssertEqual(conversations[0].lastTimestamp, timestamp)
    }

    func testDeleteConversation_removesConversationAndAssociatedTurns() async throws {
        try await manager.initialize()

        try await manager.insertConversation(
            id: "session-a",
            type: ConversationType.single.rawValue,
            participantIds: [UUID()],
            title: "Direct Chat"
        )
        try await manager.insertConversationTurn(role: "user", content: "hello", sessionId: "session-a")
        try await manager.insertConversationTurn(role: "assistant", content: "world", sessionId: "session-a")
        try await manager.insertConversationTurn(role: "assistant", content: "keep", sessionId: "session-b")

        try await manager.deleteConversation(id: "session-a")

        let conversations = try await manager.fetchConversations()
        let remainingTurns = try await manager.fetchRecentTurns(limit: 50)

        XCTAssertTrue(conversations.isEmpty)
        XCTAssertEqual(remainingTurns.count, 1)
        XCTAssertEqual(remainingTurns[0].content, "keep")
    }

    func testFetchConversations_ordersByLastTimestampDescending() async throws {
        try await manager.initialize()

        try insertConversationRow(
            id: "older",
            type: ConversationType.single.rawValue,
            participantIds: [UUID()],
            title: "Older",
            lastMessage: "first",
            lastTimestamp: 100,
            unreadCount: 0
        )
        try insertConversationRow(
            id: "newer",
            type: ConversationType.group.rawValue,
            participantIds: [UUID(), UUID()],
            title: "Newer",
            lastMessage: "second",
            lastTimestamp: 200,
            unreadCount: 2
        )

        let conversations = try await manager.fetchConversations()

        XCTAssertEqual(conversations.map(\.id), ["newer", "older"])
        XCTAssertEqual(conversations.map(\.lastMessage), ["second", "first"])
        XCTAssertEqual(conversations.map(\.unreadCount), [2, 0])
    }

    func testInsertMemoryAndFetchMemories_returnsInsertedMemory() async throws {
        try await manager.initialize()

        try await manager.insertMemory(content: "用户喜欢猫", category: "auto")

        let memories = try await manager.fetchMemories(limit: 20)

        XCTAssertEqual(memories.count, 1)
        XCTAssertEqual(memories[0].content, "用户喜欢猫")
        XCTAssertEqual(memories[0].category, "auto")
    }

    func testDeleteMemory_removesSpecifiedRow() async throws {
        try await manager.initialize()

        try await manager.insertMemory(content: "用户喜欢咖啡", category: "auto")
        let inserted = try await manager.fetchMemories(limit: 20)

        XCTAssertEqual(inserted.count, 1)

        try await manager.deleteMemory(id: inserted[0].id)

        let remaining = try await manager.fetchMemories(limit: 20)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testClearMemories_removesAllRows() async throws {
        try await manager.initialize()

        try await manager.insertMemory(content: "用户叫小明", category: "auto")
        try await manager.insertMemory(content: "用户养猫", category: "auto")

        try await manager.clearMemories()

        let memories = try await manager.fetchMemories(limit: 20)
        XCTAssertTrue(memories.isEmpty)
    }

    func testFetchMemories_ordersByImportanceThenCreatedAt() async throws {
        try await manager.initialize()
        try insertMemoryRow(content: "较早高优先级", category: "auto", createdAt: 100, importance: 3)
        try insertMemoryRow(content: "较晚低优先级", category: "auto", createdAt: 300, importance: 1)
        try insertMemoryRow(content: "较晚高优先级", category: "auto", createdAt: 200, importance: 3)

        let memories = try await manager.fetchMemories(limit: 20)

        XCTAssertEqual(memories.map(\.content), ["较晚高优先级", "较早高优先级", "较晚低优先级"])
    }

    private func openDatabase() throws -> OpaquePointer? {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            defer { if let database { sqlite3_close(database) } }
            throw DatabaseTestError.openFailed
        }
        return database
    }

    private func tableExists(named name: String) throws -> Bool {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        let statement = try prepare(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?;",
            in: database
        )
        defer { sqlite3_finalize(statement) }

        try bind(text: name, at: 1, in: statement)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func columnExists(table: String, column: String) throws -> Bool {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        let statement = try prepare("PRAGMA table_info(\(table));", in: database)
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1).map({ String(cString: $0) }),
               name == column {
                return true
            }
        }

        return false
    }

    private func insertEventRow(timestamp: String, source: String, payload: String) throws {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        let statement = try prepare(
            "INSERT INTO events (timestamp, source, payload) VALUES (?, ?, ?);",
            in: database
        )
        defer { sqlite3_finalize(statement) }

        try bind(text: timestamp, at: 1, in: statement)
        try bind(text: source, at: 2, in: statement)
        try bind(text: payload, at: 3, in: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseTestError.queryFailed
        }
    }

    private func eventCount() throws -> Int {
        try scalarCount(from: "SELECT COUNT(*) FROM events;")
    }

    private func petStateCount() throws -> Int {
        try scalarCount(from: "SELECT COUNT(*) FROM pet_state;")
    }

    private func insertConversationRow(
        id: String,
        type: String,
        participantIds: [UUID],
        title: String,
        lastMessage: String,
        lastTimestamp: Double,
        unreadCount: Int
    ) throws {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        let idsJSON = try JSONEncoder().encode(participantIds.map(\.uuidString))
        let idsString = String(data: idsJSON, encoding: .utf8) ?? "[]"
        let statement = try prepare(
            """
            INSERT INTO conversations (id, type, participant_ids, title, last_message, last_timestamp, unread_count)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }

        try bind(text: id, at: 1, in: statement)
        try bind(text: type, at: 2, in: statement)
        try bind(text: idsString, at: 3, in: statement)
        try bind(text: title, at: 4, in: statement)
        try bind(text: lastMessage, at: 5, in: statement)
        guard sqlite3_bind_double(statement, 6, lastTimestamp) == SQLITE_OK else {
            throw DatabaseTestError.bindFailed
        }
        guard sqlite3_bind_int64(statement, 7, sqlite3_int64(unreadCount)) == SQLITE_OK else {
            throw DatabaseTestError.bindFailed
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseTestError.queryFailed
        }
    }

    private func insertMemoryRow(content: String, category: String, createdAt: Double, importance: Int) throws {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        let statement = try prepare(
            """
            INSERT INTO ai_memories (content, category, created_at, importance)
            VALUES (?, ?, ?, ?);
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }

        try bind(text: content, at: 1, in: statement)
        try bind(text: category, at: 2, in: statement)
        guard sqlite3_bind_double(statement, 3, createdAt) == SQLITE_OK else {
            throw DatabaseTestError.bindFailed
        }
        guard sqlite3_bind_int64(statement, 4, sqlite3_int64(importance)) == SQLITE_OK else {
            throw DatabaseTestError.bindFailed
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseTestError.queryFailed
        }
    }

    private func scalarCount(from sql: String) throws -> Int {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        let statement = try prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseTestError.queryFailed
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func prepare(_ sql: String, in database: OpaquePointer?) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseTestError.prepareFailed
        }
        return statement
    }

    private func bind(text: String, at index: Int32, in statement: OpaquePointer?) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, index, text, -1, transient) == SQLITE_OK else {
            throw DatabaseTestError.bindFailed
        }
    }

    private func makeExpectedDate(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let date = formatter.date(from: value) else {
            XCTFail("Failed to construct expected date for \(value)")
            return Date.distantPast
        }
        return date
    }
}

private enum DatabaseTestError: Error {
    case openFailed
    case prepareFailed
    case bindFailed
    case queryFailed
}
