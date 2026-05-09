import Foundation

actor MCPClient {
    struct ToolDescriptor: Sendable, Equatable {
        let originalName: String
        let exposedName: String
        let description: String
        let inputSchema: JSONValue

        var ollamaTool: OllamaTool {
            OllamaTool.mcpTool(name: exposedName, description: description, inputSchema: inputSchema)
        }
    }

    enum MCPClientError: LocalizedError {
        case disabledServer(String)
        case invalidConfiguration(String)
        case invalidResponse(String)
        case requestTimedOut(String)
        case serverExited(String)
        case protocolError(code: Int, message: String)
        case unknownTool(String)

        var errorDescription: String? {
            switch self {
            case .disabledServer(let name):
                return "MCP server is disabled: \(name)"
            case .invalidConfiguration(let message):
                return "Invalid MCP configuration: \(message)"
            case .invalidResponse(let message):
                return "Invalid MCP response: \(message)"
            case .requestTimedOut(let method):
                return "MCP request timed out: \(method)"
            case .serverExited(let message):
                return "MCP server exited: \(message)"
            case .protocolError(_, let message):
                return message
            case .unknownTool(let name):
                return "Unknown MCP tool: \(name)"
            }
        }
    }

    private let configuration: MCPServerConfiguration
    private let urlSession: URLSession
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var nextRequestID = 1
    private var pendingRequests: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var cachedTools: [ToolDescriptor]?
    private var initialized = false
    private var httpSessionID: String?
    private var recentStderrLines: [String] = []

    private static let protocolVersion = "2025-03-26"
    private static let requestTimeout: Duration = .seconds(20)
    private static let maxRetainedStderrLines = 20

    init(configuration: MCPServerConfiguration, urlSession: URLSession = .shared) {
        self.configuration = configuration
        self.urlSession = urlSession
    }

    func listTools() async throws -> [ToolDescriptor] {
        try await ensureInitialized()

        if let cachedTools {
            return cachedTools
        }

        var allTools: [ToolDescriptor] = []
        var cursor: String?

        repeat {
            var params: [String: JSONValue] = [:]
            if let cursor, !cursor.isEmpty {
                params["cursor"] = .string(cursor)
            }

            let result = try await sendRequest(method: "tools/list", params: .object(params))
            guard let object = result.objectValue else {
                throw MCPClientError.invalidResponse("tools/list must return an object")
            }

            let tools = object["tools"]?.arrayValue ?? []
            for toolValue in tools {
                guard let toolObject = toolValue.objectValue,
                      let name = toolObject["name"]?.stringValue,
                      !name.isEmpty else {
                    continue
                }

                let description = toolObject["description"]?.stringValue ?? "MCP tool from \(configuration.name)"
                let inputSchema = toolObject["inputSchema"] ?? .object([
                    "type": .string("object"),
                    "properties": .object([:])
                ])

                allTools.append(
                    ToolDescriptor(
                        originalName: name,
                        exposedName: Self.exposedToolName(serverName: configuration.name, toolName: name),
                        description: "[MCP:\(configuration.name)] \(description)",
                        inputSchema: inputSchema
                    )
                )
            }

            cursor = object["nextCursor"]?.stringValue
        } while cursor != nil

        cachedTools = allTools
        return allTools
    }

    func callExposedTool(_ name: String, arguments: [String: JSONValue]) async throws -> String {
        let tools = try await listTools()
        guard let descriptor = tools.first(where: { $0.exposedName == name }) else {
            throw MCPClientError.unknownTool(name)
        }

        let result = try await sendRequest(
            method: "tools/call",
            params: .object([
                "name": .string(descriptor.originalName),
                "arguments": .object(arguments)
            ])
        )

        return Self.renderToolCallResult(result)
    }

    func close() async {
        stdoutTask?.cancel()
        stderrTask?.cancel()
        stdoutTask = nil
        stderrTask = nil

        if let stdinHandle {
            try? stdinHandle.close()
        }
        stdinHandle = nil

        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        httpSessionID = nil

        initialized = false
        cachedTools = nil
        resumeAllPending(with: MCPClientError.serverExited(recentStderrLines.joined(separator: "\n")))
    }

    private func ensureInitialized() async throws {
        guard configuration.enabled else {
            throw MCPClientError.disabledServer(configuration.name)
        }

        switch configuration.transport {
        case .stdio:
            try await ensureStdioInitialized()
        case .streamableHTTP:
            try await ensureHTTPInitialized()
        }
    }

    private func ensureStdioInitialized() async throws {
        try await launchProcessIfNeeded()
        guard !initialized else {
            return
        }

        let result = try await sendRequestInternal(
            method: "initialize",
            params: .object([
                "protocolVersion": .string(Self.protocolVersion),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("VitaPet"),
                    "version": .string("1.0.0")
                ])
            ])
        )

        guard let object = result.objectValue,
              let negotiatedVersion = object["protocolVersion"]?.stringValue,
              !negotiatedVersion.isEmpty else {
            throw MCPClientError.invalidResponse("initialize result missing protocolVersion")
        }

        try await sendNotification(method: "notifications/initialized", params: nil)
        initialized = true
    }

    private func ensureHTTPInitialized() async throws {
        guard !initialized else {
            return
        }

        let result = try await sendHTTPRequest(
            method: "initialize",
            params: .object([
                "protocolVersion": .string(Self.protocolVersion),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("VitaPet"),
                    "version": .string("1.0.0")
                ])
            ]),
            includeSessionHeader: false
        )

        guard let object = result.objectValue,
              let negotiatedVersion = object["protocolVersion"]?.stringValue,
              !negotiatedVersion.isEmpty else {
            throw MCPClientError.invalidResponse("initialize result missing protocolVersion")
        }

        try await sendNotification(method: "notifications/initialized", params: nil)
        initialized = true
    }

    private func launchProcessIfNeeded() async throws {
        if let process, process.isRunning {
            return
        }

        let command = configuration.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            throw MCPClientError.invalidConfiguration("command is empty for server \(configuration.name)")
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + configuration.args
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if let workingDirectory = configuration.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workingDirectory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }

        var environment = ProcessInfo.processInfo.environment
        environment.merge(configuration.env) { _, newValue in newValue }
        process.environment = environment

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.initialized = false
        self.cachedTools = nil

        stdoutTask = Task { [stdoutHandle = stdoutPipe.fileHandleForReading, self] in
            do {
                for try await line in stdoutHandle.bytes.lines {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        continue
                    }
                    await handleIncomingLine(trimmed)
                }
                handleStreamTermination(error: nil)
            } catch {
                handleStreamTermination(error: error)
            }
        }

        stderrTask = Task { [stderrHandle = stderrPipe.fileHandleForReading, self] in
            do {
                for try await line in stderrHandle.bytes.lines {
                    recordStderrLine(line)
                }
            } catch {
                recordStderrLine(error.localizedDescription)
            }
        }

        do {
            try process.run()
        } catch {
            stdoutTask?.cancel()
            stderrTask?.cancel()
            stdoutTask = nil
            stderrTask = nil
            self.process = nil
            self.stdinHandle = nil
            throw error
        }
    }

    private func sendRequest(method: String, params: JSONValue?) async throws -> JSONValue {
        try await ensureInitialized()

        switch configuration.transport {
        case .stdio:
            break
        case .streamableHTTP:
            return try await sendHTTPRequest(method: method, params: params ?? .object([:]))
        }

        return try await sendRequestInternal(method: method, params: params)
    }

    private func sendRequestInternal(method: String, params: JSONValue?) async throws -> JSONValue {
        let requestID = nextRequestID
        nextRequestID += 1

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = continuation

            do {
                try sendEncodable(
                    OutgoingRequest(id: requestID, method: method, params: params)
                )

                Task { [self] in
                    try? await Task.sleep(for: Self.requestTimeout)
                    timeoutRequest(id: requestID, method: method)
                }
            } catch {
                pendingRequests.removeValue(forKey: requestID)
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendNotification(method: String, params: JSONValue?) async throws {
        switch configuration.transport {
        case .stdio:
            try sendEncodable(OutgoingNotification(method: method, params: params))
        case .streamableHTTP:
            _ = try await sendHTTPNotification(method: method, params: params)
        }
    }

    private func sendHTTPNotification(method: String, params: JSONValue?) async throws -> JSONValue {
        try await performHTTPRequest(method: method, params: params, requestID: nil)
    }

    private func sendHTTPRequest(
        method: String,
        params: JSONValue?,
        includeSessionHeader: Bool = true
    ) async throws -> JSONValue {
        try await performHTTPRequest(
            method: method,
            params: params,
            requestID: nextJSONRPCRequestID(),
            includeSessionHeader: includeSessionHeader
        )
    }

    private func performHTTPRequest(
        method: String,
        params: JSONValue?,
        requestID: Int?,
        includeSessionHeader: Bool = true
    ) async throws -> JSONValue {
        guard let endpointURL = resolvedEndpointURL() else {
            throw MCPClientError.invalidConfiguration("url is empty or invalid for server \(configuration.name)")
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")

        for (header, value) in configuration.headers {
            request.setValue(value, forHTTPHeaderField: header)
        }

        if includeSessionHeader, let httpSessionID, !httpSessionID.isEmpty {
            request.setValue(httpSessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }

        let encoder = JSONEncoder()
        if let requestID {
            request.httpBody = try encoder.encode(
                OutgoingRequest(id: requestID, method: method, params: params)
            )
        } else {
            request.httpBody = try encoder.encode(
                OutgoingNotification(method: method, params: params)
            )
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPClientError.invalidResponse("MCP HTTP transport did not return an HTTP response")
        }

        if let sessionID = httpResponse.headerValue(named: "Mcp-Session-Id")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionID.isEmpty {
            httpSessionID = sessionID
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw try Self.parseHTTPFailure(
                data: data,
                response: httpResponse,
                fallbackMessage: "HTTP \(httpResponse.statusCode) from MCP server \(configuration.name)"
            )
        }

        guard let requestID else {
            return .null
        }

        let envelopes = try Self.decodeIncomingEnvelopes(
            from: data,
            contentType: httpResponse.headerValue(named: "Content-Type")
        )
        guard let envelope = Self.matchedEnvelope(for: requestID, in: envelopes) else {
            throw MCPClientError.invalidResponse("MCP HTTP response for \(method) did not include id \(requestID)")
        }

        if let error = envelope.error {
            throw MCPClientError.protocolError(code: error.code, message: error.message)
        }

        return envelope.result ?? .null
    }

    private func resolvedEndpointURL() -> URL? {
        let trimmedURL = configuration.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            return nil
        }
        return URL(string: trimmedURL)
    }

    private func nextJSONRPCRequestID() -> Int {
        let requestID = nextRequestID
        nextRequestID += 1
        return requestID
    }

    private func sendMethodNotSupportedResponse(id: JSONRPCID, method: String) {
        do {
            try sendEncodable(
                OutgoingErrorResponse(
                    id: id,
                    error: RPCError(code: -32601, message: "Unsupported client method: \(method)", data: nil)
                )
            )
        } catch {
            recordStderrLineSync("Failed to send MCP error response: \(error.localizedDescription)")
        }
    }

    private func sendEncodable<T: Encodable>(_ message: T) throws {
        guard let stdinHandle else {
            throw MCPClientError.serverExited(recentStderrLines.joined(separator: "\n"))
        }

        let encoder = JSONEncoder()
        let data = try encoder.encode(message)
        try stdinHandle.write(contentsOf: data + Data([0x0a]))
    }

    private func handleIncomingLine(_ line: String) async {
        let data = Data(line.utf8)
        let decoder = JSONDecoder()

        if let batch = try? decoder.decode([IncomingEnvelope].self, from: data) {
            for envelope in batch {
                await handleIncomingEnvelope(envelope)
            }
            return
        }

        guard let envelope = try? decoder.decode(IncomingEnvelope.self, from: data) else {
            recordStderrLineSync("Failed to decode MCP message: \(line)")
            return
        }
        await handleIncomingEnvelope(envelope)
    }

    private func handleIncomingEnvelope(_ envelope: IncomingEnvelope) async {
        if let method = envelope.method {
            if let id = envelope.id {
                sendMethodNotSupportedResponse(id: id, method: method)
                return
            }

            if method == "notifications/tools/list_changed" {
                cachedTools = nil
            }
            return
        }

        guard let requestID = envelope.id?.intValue,
              let continuation = pendingRequests.removeValue(forKey: requestID) else {
            return
        }

        if let error = envelope.error {
            continuation.resume(throwing: MCPClientError.protocolError(code: error.code, message: error.message))
            return
        }

        continuation.resume(returning: envelope.result ?? .null)
    }

    private func timeoutRequest(id: Int, method: String) {
        guard let continuation = pendingRequests.removeValue(forKey: id) else {
            return
        }
        continuation.resume(throwing: MCPClientError.requestTimedOut(method))
    }

    private func handleStreamTermination(error: Error?) {
        let message: String
        if let error {
            message = error.localizedDescription
        } else if recentStderrLines.isEmpty {
            message = "No additional details"
        } else {
            message = recentStderrLines.joined(separator: "\n")
        }

        process = nil
        stdinHandle = nil
        initialized = false
        cachedTools = nil
        resumeAllPending(with: MCPClientError.serverExited(message))
    }

    private func resumeAllPending(with error: Error) {
        let continuations = pendingRequests.values
        pendingRequests.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private func recordStderrLine(_ line: String) {
        recordStderrLineSync(line)
    }

    private func recordStderrLineSync(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        recentStderrLines.append(trimmed)
        if recentStderrLines.count > Self.maxRetainedStderrLines {
            recentStderrLines.removeFirst(recentStderrLines.count - Self.maxRetainedStderrLines)
        }
    }

    private static func exposedToolName(serverName: String, toolName: String) -> String {
        let serverComponent = sanitizedIdentifier(serverName)
        let toolComponent = sanitizedIdentifier(toolName)
        return "mcp_\(serverComponent)_\(toolComponent)"
    }

    private static func sanitizedIdentifier(_ value: String) -> String {
        let lowercased = value.lowercased()
        var output = ""
        var previousWasSeparator = false

        for character in lowercased {
            if character.isLetter || character.isNumber {
                output.append(character)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                output.append("_")
                previousWasSeparator = true
            }
        }

        let trimmed = output.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let fallback = trimmed.isEmpty ? "tool" : trimmed
        if let first = fallback.first, first.isNumber {
            return "tool_\(fallback)"
        }
        return fallback
    }

    private static func renderToolCallResult(_ result: JSONValue) -> String {
        guard let object = result.objectValue else {
            return result.compactJSONString() ?? "{}"
        }

        let parts = (object["content"]?.arrayValue ?? []).compactMap(renderContentItem)
        let joined = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)

        if object["isError"]?.boolValue == true {
            if joined.isEmpty {
                return "Tool execution failed"
            }
            return "Tool execution failed: \(joined)"
        }

        if !joined.isEmpty {
            return joined
        }

        return result.compactJSONString() ?? "{}"
    }

    private static func renderContentItem(_ value: JSONValue) -> String? {
        guard let object = value.objectValue,
              let type = object["type"]?.stringValue else {
            return value.compactJSONString()
        }

        switch type {
        case "text":
            return object["text"]?.stringValue
        case "resource":
            guard let resource = object["resource"]?.objectValue else {
                return "[resource]"
            }
            if let text = resource["text"]?.stringValue, !text.isEmpty {
                return text
            }
            if let uri = resource["uri"]?.stringValue {
                return "[resource: \(uri)]"
            }
            return "[resource]"
        case "image":
            let mimeType = object["mimeType"]?.stringValue ?? "image"
            return "[image result: \(mimeType)]"
        case "audio":
            let mimeType = object["mimeType"]?.stringValue ?? "audio"
            return "[audio result: \(mimeType)]"
        default:
            return value.compactJSONString()
        }
    }

    private static func parseHTTPFailure(
        data: Data,
        response: HTTPURLResponse,
        fallbackMessage: String
    ) throws -> MCPClientError {
        if let envelopes = try? decodeIncomingEnvelopes(
            from: data,
            contentType: response.headerValue(named: "Content-Type")
        ), let envelope = envelopes.first, let error = envelope.error {
            return .protocolError(code: error.code, message: error.message)
        }

        if let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !body.isEmpty {
            return .invalidResponse("\(fallbackMessage): \(body)")
        }

        return .invalidResponse(fallbackMessage)
    }

    private static func decodeIncomingEnvelopes(from data: Data, contentType: String?) throws -> [IncomingEnvelope] {
        if data.isEmpty {
            return []
        }

        let decoder = JSONDecoder()
        if let batch = try? decoder.decode([IncomingEnvelope].self, from: data) {
            return batch
        }
        if let envelope = try? decoder.decode(IncomingEnvelope.self, from: data) {
            return [envelope]
        }

        let decodedText = String(data: data, encoding: .utf8) ?? ""
        let normalizedContentType = contentType?.lowercased() ?? ""
        if normalizedContentType.contains("text/event-stream") || decodedText.contains("data:") {
            return try decodeEventStreamEnvelopes(from: decodedText)
        }

        throw MCPClientError.invalidResponse("Failed to decode MCP HTTP response")
    }

    private static func decodeEventStreamEnvelopes(from text: String) throws -> [IncomingEnvelope] {
        var envelopes: [IncomingEnvelope] = []
        var currentDataLines: [String] = []
        let decoder = JSONDecoder()

        func flushCurrentEvent() throws {
            guard !currentDataLines.isEmpty else {
                return
            }

            let payload = currentDataLines.joined(separator: "\n")
            currentDataLines.removeAll(keepingCapacity: true)
            guard let data = payload.data(using: .utf8) else {
                throw MCPClientError.invalidResponse("Failed to decode MCP SSE payload")
            }

            if let batch = try? decoder.decode([IncomingEnvelope].self, from: data) {
                envelopes.append(contentsOf: batch)
            } else {
                envelopes.append(try decoder.decode(IncomingEnvelope.self, from: data))
            }
        }

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.isEmpty {
                try flushCurrentEvent()
                continue
            }

            guard line.hasPrefix("data:") else {
                continue
            }

            let dataPortion = line.dropFirst(5)
            if dataPortion.first == " " {
                currentDataLines.append(String(dataPortion.dropFirst()))
            } else {
                currentDataLines.append(String(dataPortion))
            }
        }

        try flushCurrentEvent()
        return envelopes
    }

    private static func matchedEnvelope(for requestID: Int, in envelopes: [IncomingEnvelope]) -> IncomingEnvelope? {
        if let matched = envelopes.first(where: { $0.id?.intValue == requestID }) {
            return matched
        }

        if envelopes.count == 1 {
            return envelopes[0]
        }

        return nil
    }
}

private extension HTTPURLResponse {
    func headerValue(named name: String) -> String? {
        for (key, value) in allHeaderFields {
            guard String(describing: key).caseInsensitiveCompare(name) == .orderedSame else {
                continue
            }
            return String(describing: value)
        }
        return nil
    }
}

private enum JSONRPCID: Codable, Sendable, Equatable {
    case int(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        }
    }

    var intValue: Int? {
        if case .int(let value) = self {
            return value
        }
        return nil
    }
}

private struct OutgoingRequest: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: JSONValue?
}

private struct OutgoingNotification: Encodable {
    let jsonrpc = "2.0"
    let method: String
    let params: JSONValue?
}

private struct OutgoingErrorResponse: Encodable {
    let jsonrpc = "2.0"
    let id: JSONRPCID
    let error: RPCError
}

private struct IncomingEnvelope: Decodable {
    let jsonrpc: String
    let id: JSONRPCID?
    let method: String?
    let params: JSONValue?
    let result: JSONValue?
    let error: RPCError?
}

private struct RPCError: Codable, Sendable {
    let code: Int
    let message: String
    let data: JSONValue?
}