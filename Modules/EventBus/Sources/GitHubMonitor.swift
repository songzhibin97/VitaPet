import Foundation

public actor GitHubMonitor: EventSource {
    public nonisolated let sourceId = "githubMonitor"

    private var eventBus: EventBus?
    private var isRunning = false
    private var pollTask: Task<Void, Never>?
    private var lastCheckedAt: Date?
    private let pollInterval: TimeInterval = 300
    private let tokenProvider: @Sendable () async -> String
    private let session: URLSession

    public init(
        session: URLSession = .shared,
        tokenProvider: @escaping @Sendable () async -> String
    ) {
        self.session = session
        self.tokenProvider = tokenProvider
    }

    public func start(publishingTo eventBus: EventBus) async {
        guard !isRunning else {
            return
        }

        isRunning = true
        self.eventBus = eventBus

        pollTask = Task { [weak self] in
            guard let self else {
                return
            }

            while !Task.isCancelled {
                await self.checkNotifications()
                try? await Task.sleep(for: .seconds(self.pollInterval))
            }
        }
    }

    public func stop() async {
        isRunning = false
        pollTask?.cancel()
        pollTask = nil
        eventBus = nil
    }

    private func checkNotifications() async {
        guard isRunning, let eventBus else {
            return
        }

        let token = await tokenProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return
        }

        var components = URLComponents(string: "https://api.github.com/notifications")
        if let lastCheckedAt {
            components?.queryItems = [
                URLQueryItem(
                    name: "since",
                    value: Self.makeTimestampString(from: lastCheckedAt)
                )
            ]
        }

        guard let url = components?.url else {
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("X-GitHub-Api-Version", forHTTPHeaderField: "2022-11-28")
        request.timeoutInterval = 15

        let requestTime = Date()

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return
            }

            if httpResponse.statusCode == 304 {
                lastCheckedAt = requestTime
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                return
            }

            let decoder = JSONDecoder()
            let notifications = try decoder.decode([GitHubNotification].self, from: data)

            // 用请求发起时刻作为游标，避免处理期间的窗口丢通知
            lastCheckedAt = requestTime

            for notification in notifications where notification.unread {
                await eventBus.publish(
                    .notificationReceived(
                        source: "GitHub",
                        title: "[\(notification.subject.type)] \(notification.repository.fullName)",
                        body: notification.subject.title
                    )
                )
            }
        } catch {
            // Ignore transient network and decoding failures.
        }
    }
}

private extension GitHubMonitor {
    nonisolated static func makeTimestampString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

private struct GitHubNotification: Decodable {
    let id: String
    let unread: Bool
    let subject: Subject
    let repository: Repository

    struct Subject: Decodable {
        let title: String
        let type: String
    }

    struct Repository: Decodable {
        let fullName: String

        private enum CodingKeys: String, CodingKey {
            case fullName = "full_name"
        }
    }
}
