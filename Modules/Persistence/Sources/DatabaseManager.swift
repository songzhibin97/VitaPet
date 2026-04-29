import Foundation
import SQLite3

public actor DatabaseManager {
    private let databaseURL: URL
    private var db: OpaquePointer?

    public init() {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let databaseDirectoryURL = baseURL.appendingPathComponent("VitaPet", isDirectory: true)
        self.init(databaseURL: databaseDirectoryURL.appendingPathComponent("vitapet.db"))
    }

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public func close() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    public func initialize() throws {
        let database = try getOrOpenDatabase()

        try Self.execute(
            """
            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT DEFAULT(datetime('now')),
                source TEXT,
                payload TEXT
            );

            CREATE TABLE IF NOT EXISTS pet_state (
                pet_id TEXT PRIMARY KEY,
                animation_state TEXT,
                position_x REAL,
                position_y REAL,
                screen_id TEXT
            );

            CREATE TABLE IF NOT EXISTS conversation_turns (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                timestamp REAL NOT NULL,
                session_id TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS conversations (
                id TEXT PRIMARY KEY,
                type TEXT NOT NULL,
                participant_ids TEXT NOT NULL,
                title TEXT NOT NULL,
                last_message TEXT DEFAULT '',
                last_timestamp REAL DEFAULT 0,
                unread_count INTEGER DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS ai_memories (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                content TEXT NOT NULL,
                category TEXT NOT NULL,
                created_at REAL NOT NULL,
                importance INTEGER DEFAULT 1
            );
            """,
            in: database
        )

        // Migration: add pet columns to conversation_turns
        try? Self.execute("ALTER TABLE conversation_turns ADD COLUMN pet_id TEXT", in: database)
        try? Self.execute("ALTER TABLE conversation_turns ADD COLUMN pet_name TEXT", in: database)
    }

    private func getOrOpenDatabase() throws -> OpaquePointer? {
        if let db {
            return db
        }
        let database = try openDatabase()
        // Enable WAL mode for better concurrent access
        sqlite3_exec(database, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        // Set busy timeout to 5 seconds instead of failing immediately
        sqlite3_busy_timeout(database, 5000)
        self.db = database
        return database
    }

    public func insertEvent(source: String, payload: String) throws {
        let database = try getOrOpenDatabase()

        let statement = try Self.prepare(
            "INSERT INTO events (source, payload) VALUES (?, ?);",
            in: database
        )
        defer { sqlite3_finalize(statement) }

        try Self.bind(text: source, at: 1, in: statement)
        try Self.bind(text: payload, at: 2, in: statement)
        try Self.step(statement, in: database)
    }

    public func pruneOldEvents(keepDays: Int = 30) async throws {
        let database = try getOrOpenDatabase()
        let daysModifier = "-\(max(keepDays, 1)) days"
        let statement = try Self.prepare(
            "DELETE FROM events WHERE timestamp < datetime('now', ?);",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        try Self.bind(text: daysModifier, at: 1, in: statement)
        try Self.step(statement, in: database)
    }

    public func fetchRecentEvents(limit: Int, offset: Int) async throws -> [(id: Int64, timestamp: Date, source: String, payload: String)] {
        let database = try getOrOpenDatabase()

        let statement = try Self.prepare(
            """
            SELECT id, unixepoch(timestamp), source, payload
            FROM events
            ORDER BY timestamp DESC, id DESC
            LIMIT ? OFFSET ?;
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }

        try Self.bind(int: limit, at: 1, in: statement, database: database)
        try Self.bind(int: offset, at: 2, in: statement, database: database)

        var events: [(id: Int64, timestamp: Date, source: String, payload: String)] = []
        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                events.append(
                    (
                        id: sqlite3_column_int64(statement, 0),
                        timestamp: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 1))),
                        source: Self.columnText(at: 2, in: statement),
                        payload: Self.columnText(at: 3, in: statement)
                    )
                )
            case SQLITE_DONE:
                return events
            default:
                throw Self.sqliteError(in: database)
            }
        }
    }

    public func fetchMoodHistory(petId: String?, days: Int) async throws -> [(timestamp: Date, happiness: Int, petName: String)] {
        let database = try getOrOpenDatabase()
        let daysModifier = "-\(max(days, 0)) days"

        let sql: String
        if petId == nil {
            sql = """
            SELECT unixepoch(timestamp), payload
            FROM events
            WHERE source = 'moodChange'
              AND timestamp >= datetime('now', ?)
            ORDER BY timestamp ASC, id ASC;
            """
        } else {
            sql = """
            SELECT unixepoch(timestamp), payload
            FROM events
            WHERE source = 'moodChange'
              AND timestamp >= datetime('now', ?)
              AND payload LIKE ?
            ORDER BY timestamp ASC, id ASC;
            """
        }

        let statement = try Self.prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }

        try Self.bind(text: daysModifier, at: 1, in: statement)
        if let petId {
            try Self.bind(text: "%\"petId\":\"\(petId)\"%", at: 2, in: statement)
        }

        var history: [(timestamp: Date, happiness: Int, petName: String)] = []
        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                let timestamp = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0)))
                let payload = Self.columnText(at: 1, in: statement)
                guard let moodChange = try Self.decodeMoodChangePayload(from: payload) else {
                    continue
                }

                history.append(
                    (
                        timestamp: timestamp,
                        happiness: moodChange.happiness,
                        petName: moodChange.petName
                    )
                )
            case SQLITE_DONE:
                return history
            default:
                throw Self.sqliteError(in: database)
            }
        }
    }

    public func fetchEventCountsBySource(days: Int) async throws -> [(source: String, count: Int)] {
        let database = try getOrOpenDatabase()
        let daysModifier = "-\(max(days, 0)) days"

        let statement = try Self.prepare(
            """
            SELECT source, COUNT(*) as cnt
            FROM events
            WHERE timestamp >= datetime('now', ?)
            GROUP BY source
            ORDER BY cnt DESC;
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }

        try Self.bind(text: daysModifier, at: 1, in: statement)

        var counts: [(source: String, count: Int)] = []
        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                counts.append(
                    (
                        source: Self.columnText(at: 0, in: statement),
                        count: Int(sqlite3_column_int64(statement, 1))
                    )
                )
            case SQLITE_DONE:
                return counts
            default:
                throw Self.sqliteError(in: database)
            }
        }
    }

    public func fetchPetBehaviorCounts(days: Int) async throws -> [(state: String, count: Int, petName: String)] {
        let database = try getOrOpenDatabase()
        let daysModifier = "-\(max(days, 0)) days"

        let statement = try Self.prepare(
            """
            SELECT payload
            FROM events
            WHERE source = 'petBehavior'
              AND timestamp >= datetime('now', ?)
            ORDER BY timestamp ASC, id ASC;
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }

        try Self.bind(text: daysModifier, at: 1, in: statement)

        var countsByBehavior: [PetBehaviorAggregateKey: Int] = [:]
        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                let payload = Self.columnText(at: 0, in: statement)
                guard let behavior = try Self.decodePetBehaviorPayload(from: payload),
                      !behavior.state.isEmpty,
                      !behavior.petName.isEmpty else {
                    continue
                }
                let key = PetBehaviorAggregateKey(state: behavior.state, petName: behavior.petName)
                countsByBehavior[key, default: 0] += 1
            case SQLITE_DONE:
                return countsByBehavior
                    .map { (state: $0.key.state, count: $0.value, petName: $0.key.petName) }
                    .sorted {
                        if $0.count == $1.count {
                            if $0.state == $1.state {
                                return $0.petName < $1.petName
                            }
                            return $0.state < $1.state
                        }
                        return $0.count > $1.count
                    }
            default:
                throw Self.sqliteError(in: database)
            }
        }
    }

    public func fetchDailyEventCounts(days: Int) async throws -> [(date: String, count: Int)] {
        let database = try getOrOpenDatabase()
        let daysModifier = "-\(max(days, 0)) days"

        let statement = try Self.prepare(
            """
            SELECT strftime('%Y-%m-%d', timestamp) as day, COUNT(*) as cnt
            FROM events
            WHERE timestamp >= datetime('now', ?)
            GROUP BY day
            ORDER BY day ASC;
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }

        try Self.bind(text: daysModifier, at: 1, in: statement)

        var counts: [(date: String, count: Int)] = []
        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                counts.append(
                    (
                        date: Self.columnText(at: 0, in: statement),
                        count: Int(sqlite3_column_int64(statement, 1))
                    )
                )
            case SQLITE_DONE:
                return counts
            default:
                throw Self.sqliteError(in: database)
            }
        }
    }

    public func fetchDailyInteractionCounts(days: Int) async throws -> [(date: String, clicks: Int, interactions: Int, games: Int)] {
        let database = try getOrOpenDatabase()
        let daysModifier = "-\(max(days, 0)) days"

        let statement = try Self.prepare(
            """
            SELECT
                strftime('%Y-%m-%d', timestamp) as day,
                SUM(CASE WHEN source = 'petClick' THEN 1 ELSE 0 END) as clicks,
                SUM(CASE WHEN source = 'petInteraction' THEN 1 ELSE 0 END) as interactions,
                SUM(CASE WHEN source = 'gamePlay' THEN 1 ELSE 0 END) as games
            FROM events
            WHERE source IN ('petClick', 'petInteraction', 'gamePlay')
              AND timestamp >= datetime('now', ?)
            GROUP BY day
            ORDER BY day ASC;
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }

        try Self.bind(text: daysModifier, at: 1, in: statement)

        var counts: [(date: String, clicks: Int, interactions: Int, games: Int)] = []
        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                counts.append(
                    (
                        date: Self.columnText(at: 0, in: statement),
                        clicks: Int(sqlite3_column_int64(statement, 1)),
                        interactions: Int(sqlite3_column_int64(statement, 2)),
                        games: Int(sqlite3_column_int64(statement, 3))
                    )
                )
            case SQLITE_DONE:
                return counts
            default:
                throw Self.sqliteError(in: database)
            }
        }
    }

    public func savePetState(
        petId: String,
        state: String,
        x: Double,
        y: Double,
        screenId: String
    ) throws {
        let database = try getOrOpenDatabase()

        let statement = try Self.prepare(
            """
            INSERT INTO pet_state (pet_id, animation_state, position_x, position_y, screen_id)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(pet_id) DO UPDATE SET
                animation_state = excluded.animation_state,
                position_x = excluded.position_x,
                position_y = excluded.position_y,
                screen_id = excluded.screen_id;
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }

        try Self.bind(text: petId, at: 1, in: statement)
        try Self.bind(text: state, at: 2, in: statement)
        guard sqlite3_bind_double(statement, 3, x) == SQLITE_OK else {
            throw Self.sqliteError(in: database)
        }
        guard sqlite3_bind_double(statement, 4, y) == SQLITE_OK else {
            throw Self.sqliteError(in: database)
        }
        try Self.bind(text: screenId, at: 5, in: statement)
        try Self.step(statement, in: database)
    }

    public func loadPetState(petId: String) throws -> PetState? {
        let database = try getOrOpenDatabase()

        let statement = try Self.prepare(
            """
            SELECT pet_id, animation_state, position_x, position_y, screen_id
            FROM pet_state
            WHERE pet_id = ?;
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }

        try Self.bind(text: petId, at: 1, in: statement)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return PetState(
                petId: Self.columnText(at: 0, in: statement),
                animationState: Self.columnText(at: 1, in: statement),
                positionX: sqlite3_column_double(statement, 2),
                positionY: sqlite3_column_double(statement, 3),
                screenId: Self.columnText(at: 4, in: statement)
            )
        case SQLITE_DONE:
            return nil
        default:
            throw Self.sqliteError(in: database)
        }
    }

    public func updateConversationTitle(id: String, title: String) async throws {
        let database = try getOrOpenDatabase()
        let statement = try Self.prepare(
            "UPDATE conversations SET title = ? WHERE id = ?;",
            in: database
        )
        defer { sqlite3_finalize(statement) }

        try Self.bind(text: title, at: 1, in: statement)
        try Self.bind(text: id, at: 2, in: statement)
        try Self.step(statement, in: database)
    }

    public func insertConversationTurn(
        role: String,
        content: String,
        sessionId: String,
        petId: String? = nil,
        petName: String? = nil
    ) async throws {
        let database = try getOrOpenDatabase()

        let statement = try Self.prepare(
            """
            INSERT INTO conversation_turns (role, content, timestamp, session_id, pet_id, pet_name)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }

        try Self.bind(text: role, at: 1, in: statement)
        try Self.bind(text: content, at: 2, in: statement)
        guard sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970) == SQLITE_OK else {
            throw Self.sqliteError(in: database)
        }
        try Self.bind(text: sessionId, at: 4, in: statement)
        try Self.bind(optionalText: petId, at: 5, in: statement, database: database)
        try Self.bind(optionalText: petName, at: 6, in: statement, database: database)
        try Self.step(statement, in: database)
    }

    public func fetchRecentTurns(
        sessionId: String? = nil,
        limit: Int = 50
    ) async throws -> [(role: String, content: String, petId: String?, petName: String?)] {
        let database = try getOrOpenDatabase()

        let sql: String
        if sessionId == nil {
            sql = """
            SELECT role, content, pet_id, pet_name
            FROM conversation_turns
            ORDER BY id DESC
            LIMIT ?;
            """
        } else {
            sql = """
            SELECT role, content, pet_id, pet_name
            FROM conversation_turns
            WHERE session_id = ?
            ORDER BY id DESC
            LIMIT ?;
            """
        }

        let statement = try Self.prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }

        if let sessionId {
            try Self.bind(text: sessionId, at: 1, in: statement)
            try Self.bind(int: limit, at: 2, in: statement, database: database)
        } else {
            try Self.bind(int: limit, at: 1, in: statement, database: database)
        }

        var turns: [(role: String, content: String, petId: String?, petName: String?)] = []
        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                turns.append(
                        (
                            role: Self.columnText(at: 0, in: statement),
                            content: Self.columnText(at: 1, in: statement),
                            petId: Self.optionalColumnText(at: 2, in: statement),
                            petName: Self.optionalColumnText(at: 3, in: statement)
                        )
                )
            case SQLITE_DONE:
                return turns.reversed()
            default:
                throw Self.sqliteError(in: database)
            }
        }
    }

    public func deleteOldTurns(keepLast: Int) async throws {
        let database = try getOrOpenDatabase()

        let statement = try Self.prepare(
            """
            DELETE FROM conversation_turns
            WHERE id NOT IN (
                SELECT id
                FROM conversation_turns
                ORDER BY id DESC
                LIMIT ?
            );
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }

        try Self.bind(int: keepLast, at: 1, in: statement, database: database)
        try Self.step(statement, in: database)
    }

    public func clearConversation() async throws {
        let database = try getOrOpenDatabase()
        try Self.execute("DELETE FROM conversation_turns;", in: database)
    }

    public func insertConversation(
        id: String,
        type: String,
        participantIds: [UUID],
        title: String
    ) async throws {
        let database = try getOrOpenDatabase()
        let idsJSON = try JSONEncoder().encode(participantIds.map(\.uuidString))
        let idsString = String(data: idsJSON, encoding: .utf8) ?? "[]"

        let statement = try Self.prepare(
            """
            INSERT OR IGNORE INTO conversations (id, type, participant_ids, title, last_timestamp)
            VALUES (?, ?, ?, ?, ?);
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }

        try Self.bind(text: id, at: 1, in: statement)
        try Self.bind(text: type, at: 2, in: statement)
        try Self.bind(text: idsString, at: 3, in: statement)
        try Self.bind(text: title, at: 4, in: statement)
        guard sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970) == SQLITE_OK else {
            throw Self.sqliteError(in: database)
        }
        try Self.step(statement, in: database)
    }

    public func fetchConversations() async throws -> [ConversationThread] {
        let database = try getOrOpenDatabase()
        let statement = try Self.prepare(
            """
            SELECT id, type, participant_ids, title, last_message, last_timestamp, unread_count
            FROM conversations
            ORDER BY last_timestamp DESC;
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }

        var conversations: [ConversationThread] = []
        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                let id = Self.columnText(at: 0, in: statement)
                let typeValue = Self.columnText(at: 1, in: statement)
                let participantIdsJSON = Self.columnText(at: 2, in: statement)
                let title = Self.columnText(at: 3, in: statement)
                let lastMessage = Self.columnText(at: 4, in: statement)
                let lastTimestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
                let unreadCount = Int(sqlite3_column_int64(statement, 6))

                let type = ConversationType(rawValue: typeValue) ?? .single
                let participantIds = try Self.decodeParticipantIDs(from: participantIdsJSON)

                conversations.append(
                    ConversationThread(
                        id: id,
                        type: type,
                        participantIds: participantIds,
                        title: title,
                        lastMessage: lastMessage,
                        lastTimestamp: lastTimestamp,
                        unreadCount: unreadCount
                    )
                )
            case SQLITE_DONE:
                return conversations
            default:
                throw Self.sqliteError(in: database)
            }
        }
    }

    public func updateConversationLastMessage(
        id: String,
        message: String,
        timestamp: Date
    ) async throws {
        let database = try getOrOpenDatabase()
        let statement = try Self.prepare(
            """
            UPDATE conversations
            SET last_message = ?, last_timestamp = ?
            WHERE id = ?;
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }

        try Self.bind(text: message, at: 1, in: statement)
        guard sqlite3_bind_double(statement, 2, timestamp.timeIntervalSince1970) == SQLITE_OK else {
            throw Self.sqliteError(in: database)
        }
        try Self.bind(text: id, at: 3, in: statement)
        try Self.step(statement, in: database)
    }

    public func updateConversationParticipantIds(
        id: String,
        participantIds: [UUID]
    ) async throws {
        let database = try getOrOpenDatabase()
        let idsJSON = try JSONEncoder().encode(participantIds.map(\.uuidString))
        let idsString = String(data: idsJSON, encoding: .utf8) ?? "[]"
        let statement = try Self.prepare(
            """
            UPDATE conversations
            SET participant_ids = ?
            WHERE id = ?;
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }

        try Self.bind(text: idsString, at: 1, in: statement)
        try Self.bind(text: id, at: 2, in: statement)
        try Self.step(statement, in: database)
    }

    public func deleteConversation(id: String) async throws {
        let database = try getOrOpenDatabase()

        let deleteConversationStatement = try Self.prepare(
            "DELETE FROM conversations WHERE id = ?;",
            in: database
        )
        defer { sqlite3_finalize(deleteConversationStatement) }

        try Self.bind(text: id, at: 1, in: deleteConversationStatement)
        try Self.step(deleteConversationStatement, in: database)

        let deleteTurnsStatement = try Self.prepare(
            "DELETE FROM conversation_turns WHERE session_id = ?;",
            in: database
        )
        defer { sqlite3_finalize(deleteTurnsStatement) }

        try Self.bind(text: id, at: 1, in: deleteTurnsStatement)
        try Self.step(deleteTurnsStatement, in: database)
    }

    public func insertMemory(content: String, category: String, importance: Int = 1) async throws {
        let database = try getOrOpenDatabase()

        let statement = try Self.prepare(
            """
            INSERT INTO ai_memories (content, category, created_at, importance)
            VALUES (?, ?, ?, ?);
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }

        try Self.bind(text: content, at: 1, in: statement)
        try Self.bind(text: category, at: 2, in: statement)
        guard sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970) == SQLITE_OK else {
            throw Self.sqliteError(in: database)
        }
        try Self.bind(int: importance, at: 4, in: statement, database: database)
        try Self.step(statement, in: database)
    }

    public func fetchMemories(limit: Int = 20) async throws -> [(id: Int64, content: String, category: String)] {
        let database = try getOrOpenDatabase()

        let statement = try Self.prepare(
            """
            SELECT id, content, category
            FROM ai_memories
            ORDER BY importance DESC, created_at DESC
            LIMIT ?;
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }

        try Self.bind(int: limit, at: 1, in: statement, database: database)

        var memories: [(id: Int64, content: String, category: String)] = []
        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                memories.append(
                    (
                        id: sqlite3_column_int64(statement, 0),
                        content: Self.columnText(at: 1, in: statement),
                        category: Self.columnText(at: 2, in: statement)
                    )
                )
            case SQLITE_DONE:
                return memories
            default:
                throw Self.sqliteError(in: database)
            }
        }
    }

    public func deleteMemory(id: Int64) async throws {
        let database = try getOrOpenDatabase()

        let statement = try Self.prepare(
            "DELETE FROM ai_memories WHERE id = ?;",
            in: database
        )
        defer { sqlite3_finalize(statement) }

        guard sqlite3_bind_int64(statement, 1, id) == SQLITE_OK else {
            throw Self.sqliteError(in: database)
        }
        try Self.step(statement, in: database)
    }

    public func clearMemories() async throws {
        let database = try getOrOpenDatabase()
        try Self.execute("DELETE FROM ai_memories;", in: database)
    }
}

extension DatabaseManager {
    private struct PetBehaviorAggregateKey: Hashable {
        let state: String
        let petName: String
    }

    private struct MoodChangePayload: Decodable {
        let petId: String
        let petName: String
        let happiness: Int
    }

    private struct PetBehaviorPayload: Decodable {
        let petName: String
        let state: String
    }

    private var applicationSupportDirectoryURL: URL {
        databaseURL.deletingLastPathComponent()
    }

    private func ensureApplicationSupportDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: applicationSupportDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    private func openDatabase() throws -> OpaquePointer? {
        try ensureApplicationSupportDirectoryExists()

        var database: OpaquePointer?
        let result = sqlite3_open(databaseURL.path, &database)
        guard result == SQLITE_OK, let database else {
            if let database {
                let error = Self.sqliteError(in: database)
                sqlite3_close(database)
                throw error
            }
            throw SQLiteError(message: "Failed to open database.")
        }
        return database
    }

    private static func execute(_ sql: String, in database: OpaquePointer?) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw sqliteError(in: database)
        }
    }

    private static func prepare(_ sql: String, in database: OpaquePointer?) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError(in: database)
        }
        return statement
    }

    private static func bind(text: String, at index: Int32, in statement: OpaquePointer?) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, index, text, -1, transient) == SQLITE_OK else {
            throw SQLiteError(message: "Failed to bind SQLite text parameter.")
        }
    }

    private static func bind(optionalText: String?, at index: Int32, in statement: OpaquePointer?, database: OpaquePointer?) throws {
        if let text = optionalText {
            try bind(text: text, at: index, in: statement)
            return
        }

        guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
            throw sqliteError(in: database)
        }
    }

    private static func bind(int: Int, at index: Int32, in statement: OpaquePointer?, database: OpaquePointer?) throws {
        guard sqlite3_bind_int64(statement, index, sqlite3_int64(int)) == SQLITE_OK else {
            throw sqliteError(in: database)
        }
    }

    private static func step(_ statement: OpaquePointer?, in database: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError(in: database)
        }
    }

    private static func columnText(at index: Int32, in statement: OpaquePointer?) -> String {
        guard let text = sqlite3_column_text(statement, index) else {
            return ""
        }
        return String(cString: text)
    }

    private static func optionalColumnText(at index: Int32, in statement: OpaquePointer?) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: text)
    }

    private static func sqliteError(in database: OpaquePointer?) -> SQLiteError {
        let message = sqlite3_errmsg(database).map { String(cString: $0) } ?? "Unknown SQLite error."
        return SQLiteError(message: message)
    }

    private static func decodeParticipantIDs(from json: String) throws -> [UUID] {
        let data = Data(json.utf8)
        let rawIDs = try JSONDecoder().decode([String].self, from: data)
        return rawIDs.compactMap(UUID.init(uuidString:))
    }

    private static func decodeMoodChangePayload(from json: String) throws -> MoodChangePayload? {
        let data = Data(json.utf8)
        return try? JSONDecoder().decode(MoodChangePayload.self, from: data)
    }

    private static func decodePetBehaviorPayload(from json: String) throws -> PetBehaviorPayload? {
        let data = Data(json.utf8)
        return try? JSONDecoder().decode(PetBehaviorPayload.self, from: data)
    }
}

extension DatabaseManager {
    private struct SQLiteError: LocalizedError, Sendable {
        let message: String

        var errorDescription: String? { message }
    }
}
