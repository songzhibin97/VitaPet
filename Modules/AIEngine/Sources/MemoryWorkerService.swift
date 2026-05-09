import Foundation

public enum MemoryWorkerAuthMode: String, Codable, Sendable, CaseIterable {
    case basic
    case bearer
}

public struct MemoryWorkerConfig: Codable, Sendable {
    public var enabled: Bool
    public var endpoint: String
    public var authMode: MemoryWorkerAuthMode
    public var username: String
    public var secret: String
    public var namespace: String
    public var scope: String
    public var subject: String
    public var queryLimit: Int
    public var createHorizon: String

    public init(
        enabled: Bool,
        endpoint: String,
        authMode: MemoryWorkerAuthMode,
        username: String,
        secret: String,
        namespace: String = "default",
        scope: String = "user",
        subject: String,
        queryLimit: Int = 5,
        createHorizon: String = "daily"
    ) {
        self.enabled = enabled
        self.endpoint = endpoint
        self.authMode = authMode
        self.username = username
        self.secret = secret
        self.namespace = namespace
        self.scope = scope
        self.subject = subject
        self.queryLimit = max(1, min(100, queryLimit))
        self.createHorizon = createHorizon
    }
}

public struct MemoryWorkerItem: Decodable, Sendable {
    public let id: Int?
    public let content: String

    private enum CodingKeys: String, CodingKey {
        case id
        case content
    }

    public init(id: Int?, content: String) {
        self.id = id
        self.content = content
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.content = try c.decode(String.self, forKey: .content)
        if let intId = try? c.decode(Int.self, forKey: .id) {
            self.id = intId
        } else if let s = try? c.decode(String.self, forKey: .id), let intId = Int(s) {
            self.id = intId
        } else {
            self.id = nil
        }
    }
}

public actor MemoryWorkerService {
    private var config: MemoryWorkerConfig
    private let urlSession: URLSession

    public init(config: MemoryWorkerConfig, urlSession: URLSession = .shared) {
        self.config = config
        self.urlSession = urlSession
    }

    public func updateConfig(_ newConfig: MemoryWorkerConfig) {
        config = newConfig
    }

    public func queryMemories(q: String? = nil) async throws -> [MemoryWorkerItem] {
        guard config.enabled else {
            return []
        }

        var request = URLRequest(url: try Self.buildURL(from: config.endpoint, path: "/api/memories/query"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try Self.applyAuthorization(to: &request, config: config)

        let trimmedQuery = q?.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = QueryRequest(
            namespace: config.namespace,
            scope: config.scope,
            subject: config.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : config.subject.trimmingCharacters(in: .whitespacesAndNewlines),
            q: (trimmedQuery?.isEmpty == true) ? nil : trimmedQuery,
            limit: max(1, min(100, config.queryLimit))
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await urlSession.data(for: request)
        try Self.validate(response: response, data: data)
        if let parsed = try? JSONDecoder().decode(QueryResponse.self, from: data) {
            return parsed.items
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let rawItems = obj["items"] as? [[String: Any]] {
                return rawItems.compactMap { Self.looseMemoryItem(from: $0) }
            }
            if let rawItems = obj["memories"] as? [[String: Any]] {
                return rawItems.compactMap { Self.looseMemoryItem(from: $0) }
            }
        }
        let preview = String(data: data.prefix(320), encoding: .utf8)
        throw MemoryWorkerServiceError.unexpectedCreateResponse(preview)
    }

    @discardableResult
    public func createMemory(
        content: String,
        category: String? = nil,
        importance: Int? = nil,
        tags: [String] = ["auto"],
        metadata: [String: String]? = nil
    ) async throws -> MemoryWorkerItem {
        guard config.enabled else {
            throw MemoryWorkerServiceError.disabled
        }

        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            throw MemoryWorkerServiceError.invalidInput("content is empty")
        }

        var request = URLRequest(url: try Self.buildURL(from: config.endpoint, path: "/api/memories"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try Self.applyAuthorization(to: &request, config: config)

        var combinedTags = tags
        if let category, !category.isEmpty, !combinedTags.contains(category) {
            combinedTags.append(category)
        }

        var combinedMetadata = metadata ?? [:]
        if let category, !category.isEmpty {
            combinedMetadata["category"] = category
        }
        if let importance {
            combinedMetadata["importance"] = String(max(1, min(3, importance)))
        }

        let payload = CreateRequest(
            namespace: config.namespace,
            scope: config.scope,
            subject: config.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : config.subject.trimmingCharacters(in: .whitespacesAndNewlines),
            content: trimmedContent,
            tags: combinedTags.isEmpty ? nil : combinedTags,
            metadata: combinedMetadata.isEmpty ? nil : combinedMetadata,
            horizon: config.createHorizon
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await urlSession.data(for: request)
        try Self.validate(response: response, data: data)
        if data.isEmpty {
            return MemoryWorkerItem(id: nil, content: trimmedContent)
        }
        return try Self.decodeCreateMemoryItem(from: data, fallbackContent: trimmedContent)
    }

    /// Workers vary: `{ "item": {...} }`, flat `{ "id","content" }`, `{ "ok": true }`, etc.
    private static func decodeCreateMemoryItem(from data: Data, fallbackContent: String) throws -> MemoryWorkerItem {
        let decoder = JSONDecoder()
        struct ItemEnvelope: Decodable {
            let item: MemoryWorkerItem
        }
        struct DataEnvelope: Decodable {
            let data: MemoryWorkerItem
        }
        struct MemoryEnvelope: Decodable {
            let memory: MemoryWorkerItem
        }
        if let env = try? decoder.decode(ItemEnvelope.self, from: data) {
            return env.item
        }
        if let env = try? decoder.decode(DataEnvelope.self, from: data) {
            return env.data
        }
        if let env = try? decoder.decode(MemoryEnvelope.self, from: data) {
            return env.memory
        }
        if let item = try? decoder.decode(MemoryWorkerItem.self, from: data) {
            return item
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let preview = String(data: data.prefix(480), encoding: .utf8)
            throw MemoryWorkerServiceError.unexpectedCreateResponse(preview)
        }
        if let parsed = memoryItemFromLooseJSON(obj, fallbackContent: fallbackContent, allowStatusOnlyFallback: true) {
            return parsed
        }
        for key in ["memory", "data", "result", "record"] {
            if let nested = obj[key] as? [String: Any],
               let parsed = memoryItemFromLooseJSON(nested, fallbackContent: fallbackContent, allowStatusOnlyFallback: true) {
                return parsed
            }
        }
        let preview = String(data: data.prefix(480), encoding: .utf8)
        throw MemoryWorkerServiceError.unexpectedCreateResponse(preview)
    }

    private static func memoryItemFromLooseJSON(
        _ obj: [String: Any],
        fallbackContent: String,
        allowStatusOnlyFallback: Bool
    ) -> MemoryWorkerItem? {
        let id = parseLooseId(from: obj)
        if let content = obj["content"] as? String, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return MemoryWorkerItem(id: id, content: content)
        }
        for key in ["text", "body", "message", "value"] {
            if let s = obj[key] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return MemoryWorkerItem(id: id, content: s)
            }
        }
        if allowStatusOnlyFallback,
           obj["ok"] as? Bool == true || obj["success"] as? Bool == true,
           !fallbackContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return MemoryWorkerItem(id: id, content: fallbackContent)
        }
        return nil
    }

    private static func parseLooseId(from obj: [String: Any]) -> Int? {
        for key in ["id", "memory_id", "memoryId"] {
            if let i = obj[key] as? Int {
                return i
            }
            if let s = obj[key] as? String, let i = Int(s) {
                return i
            }
            if let d = obj[key] as? Double {
                return Int(d)
            }
        }
        return nil
    }

    private static func looseMemoryItem(from obj: [String: Any]) -> MemoryWorkerItem? {
        memoryItemFromLooseJSON(obj, fallbackContent: "", allowStatusOnlyFallback: false)
    }

    private static func buildURL(from endpoint: String, path: String) throws -> URL {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEndpoint.isEmpty,
              var components = URLComponents(string: trimmedEndpoint)
        else {
            throw MemoryWorkerServiceError.invalidEndpoint(endpoint)
        }

        let basePath = normalizedBasePath(from: components.path)
        components.path = (basePath.isEmpty ? "" : basePath) + path

        guard let url = components.url else {
            throw MemoryWorkerServiceError.invalidEndpoint(endpoint)
        }

        return url
    }

    private static func normalizedBasePath(from originalPath: String) -> String {
        var path = originalPath
        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }

        let lowercased = path.lowercased()
        if lowercased.hasSuffix("/api/memories/query") {
            path.removeLast("/api/memories/query".count)
        } else if lowercased.hasSuffix("/api/memories") {
            path.removeLast("/api/memories".count)
        }

        if path == "/" {
            return ""
        }

        return path
    }

    private static func applyAuthorization(to request: inout URLRequest, config: MemoryWorkerConfig) throws {
        switch config.authMode {
        case .basic:
            let username = config.username.trimmingCharacters(in: .whitespacesAndNewlines)
            let secret = config.secret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !username.isEmpty, !secret.isEmpty else {
                throw MemoryWorkerServiceError.missingCredentials("basic")
            }

            let raw = "\(username):\(secret)"
            let encoded = Data(raw.utf8).base64EncodedString()
            request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        case .bearer:
            let token = config.secret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                throw MemoryWorkerServiceError.missingCredentials("bearer")
            }

            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MemoryWorkerServiceError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw MemoryWorkerServiceError.httpStatus(httpResponse.statusCode, body)
        }
    }

    private struct QueryRequest: Encodable {
        let namespace: String
        let scope: String
        let subject: String?
        let q: String?
        let limit: Int
    }

    private struct CreateRequest: Encodable {
        let namespace: String
        let scope: String
        let subject: String?
        let content: String
        let tags: [String]?
        let metadata: [String: String]?
        let horizon: String
    }

    private struct QueryResponse: Decodable {
        let item: MemoryWorkerItem?
        let items: [MemoryWorkerItem]
        let count: Int

        enum CodingKeys: String, CodingKey {
            case item
            case items
            case count
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            item = try c.decodeIfPresent(MemoryWorkerItem.self, forKey: .item)
            items = try c.decodeIfPresent([MemoryWorkerItem].self, forKey: .items) ?? []
            count = try c.decodeIfPresent(Int.self, forKey: .count) ?? items.count
        }
    }
}

public enum MemoryWorkerServiceError: LocalizedError {
    case disabled
    case invalidEndpoint(String)
    case missingCredentials(String)
    case invalidInput(String)
    case httpStatus(Int, String?)
    case invalidResponse
    case unexpectedCreateResponse(String?)

    public var errorDescription: String? {
        switch self {
        case .disabled:
            return "Memory worker is disabled"
        case .invalidEndpoint(let endpoint):
            return "Invalid memory worker endpoint: \(endpoint)"
        case .missingCredentials(let mode):
            return "Missing credentials for \(mode) authentication"
        case .invalidInput(let reason):
            return "Invalid memory input: \(reason)"
        case .httpStatus(let status, let body):
            if let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Memory worker returned HTTP \(status): \(body)"
            }
            return "Memory worker returned HTTP \(status)"
        case .invalidResponse:
            return "Memory worker returned an invalid response"
        case .unexpectedCreateResponse(let preview):
            if let preview, !preview.isEmpty {
                return "Memory worker create response could not be parsed: \(preview)"
            }
            return "Memory worker create response could not be parsed"
        }
    }
}
