import Foundation
@preconcurrency import Network

public actor WebhookServer: EventSource {
    public nonisolated let sourceId = "webhookServer"

    private let port: UInt16
    private let secret: String
    private var eventBus: EventBus?
    private var isRunning = false
    private var listener: NWListener?

    public init(port: UInt16 = 19280, secret: String = "") {
        self.port = port
        self.secret = secret
    }

    public func start(publishingTo eventBus: EventBus) async {
        guard !isRunning else {
            return
        }

        do {
            let params = NWParameters.tcp
            let nwPort = NWEndpoint.Port(rawValue: port) ?? .init(integerLiteral: 19280)
            let listener = try NWListener(using: params, on: nwPort)

            listener.newConnectionHandler = { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }

                Task {
                    await self.handleConnection(connection)
                }
            }

            listener.stateUpdateHandler = { state in
                if case let .failed(error) = state {
                    print("WebhookServer failed: \(error)")
                }
            }

            self.listener = listener
            self.eventBus = eventBus
            isRunning = true
            listener.start(queue: .main)
        } catch {
            isRunning = false
            self.listener = nil
            self.eventBus = nil
            print("WebhookServer failed to start: \(error)")
        }
    }

    public func stop() async {
        isRunning = false
        listener?.cancel()
        listener = nil
        eventBus = nil
    }

    private func handleConnection(_ connection: NWConnection) async {
        connection.start(queue: .main)
        await receiveRequest(on: connection, accumulatedData: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulatedData: Data) async {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if error != nil {
                connection.cancel()
                return
            }

            var buffer = accumulatedData
            if let data {
                buffer.append(data)
            }

            if Self.requestIsComplete(buffer, isComplete: isComplete) {
                Task {
                    await self.processRequest(data: buffer, connection: connection)
                }
                return
            }

            Task {
                await self.receiveRequest(on: connection, accumulatedData: buffer)
            }
        }
    }

    private func processRequest(data: Data, connection: NWConnection) async {
        guard Self.isLoopbackConnection(connection) else {
            await sendResponse(status: "403 Forbidden", body: #"{"error":"forbidden"}"#, on: connection)
            return
        }

        guard let eventBus, isRunning else {
            await sendResponse(status: "503 Service Unavailable", body: #"{"error":"not ready"}"#, on: connection)
            return
        }

        guard let request = String(data: data, encoding: .utf8),
              let separator = request.range(of: "\r\n\r\n") else {
            await sendResponse(status: "400 Bad Request", body: #"{"error":"bad request"}"#, on: connection)
            return
        }

        let headerText = String(request[..<separator.lowerBound])
        let headerLines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first else {
            await sendResponse(status: "400 Bad Request", body: #"{"error":"bad request"}"#, on: connection)
            return
        }

        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2,
              requestParts[0] == "POST",
              requestParts[1] == "/webhook" else {
            await sendResponse(status: "404 Not Found", body: #"{"error":"not found"}"#, on: connection)
            return
        }

        if !secret.isEmpty {
            let secretHeader = headerLines.first { $0.lowercased().hasPrefix("x-webhook-secret:") }
            let providedSecret = secretHeader.map { $0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "" } ?? ""
            guard providedSecret == secret else {
                await sendResponse(status: "401 Unauthorized", body: #"{"error":"invalid secret"}"#, on: connection)
                return
            }
        }

        let bodyString = String(request[separator.upperBound...])
        guard !bodyString.isEmpty,
              let bodyData = bodyString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            await sendResponse(status: "400 Bad Request", body: #"{"error":"invalid json"}"#, on: connection)
            return
        }

        let title = json["title"] as? String ?? "Webhook"
        let body = json["body"] as? String ?? ""
        let action = json["action"] as? String

        await eventBus.publish(
            .notificationReceived(
                source: "Webhook",
                title: title,
                body: body
            )
        )

        if let action, !action.isEmpty {
            await eventBus.publish(.custom(name: action, payload: [:]))
        }

        await sendResponse(status: "200 OK", body: #"{"status":"ok"}"#, on: connection)
    }

    private func sendResponse(status: String, body: String, on connection: NWConnection) async {
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: application/json\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """

        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private extension WebhookServer {
    nonisolated static func isLoopbackConnection(_ connection: NWConnection) -> Bool {
        if let endpoint = connection.currentPath?.remoteEndpoint,
           isLoopbackEndpoint(endpoint) {
            return true
        }

        return isLoopbackEndpoint(connection.endpoint)
    }

    nonisolated static func isLoopbackEndpoint(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else {
            return false
        }

        let normalizedHost = String(describing: host).lowercased()
        return normalizedHost == "127.0.0.1" || normalizedHost == "::1" || normalizedHost == "localhost"
    }

    nonisolated static func requestIsComplete(_ data: Data, isComplete: Bool) -> Bool {
        guard let request = String(data: data, encoding: .utf8),
              let separator = request.range(of: "\r\n\r\n") else {
            return isComplete
        }

        let headers = String(request[..<separator.lowerBound])
        let body = String(request[separator.upperBound...])
        let contentLength = parseContentLength(from: headers) ?? 0
        return body.utf8.count >= contentLength
    }

    nonisolated static func parseContentLength(from headers: String) -> Int? {
        for line in headers.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                continue
            }

            if parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        return nil
    }
}
