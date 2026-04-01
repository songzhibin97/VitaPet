import AppKit
import Foundation

@MainActor
protocol ClipboardPasteboard: AnyObject {
    var changeCount: Int { get }
    func stringContent() -> String?
}

@MainActor
final class ClipboardReader: @unchecked Sendable {
    private let readChangeCount: @MainActor () -> Int
    private let readStringContent: @MainActor () -> String?

    init(pasteboard: any ClipboardPasteboard) {
        readChangeCount = { pasteboard.changeCount }
        readStringContent = { pasteboard.stringContent() }
    }

    func changeCount() -> Int {
        readChangeCount()
    }

    func stringContent() -> String? {
        readStringContent()
    }
}

@MainActor
extension NSPasteboard: ClipboardPasteboard {
    func stringContent() -> String? {
        string(forType: .string)
    }
}

public actor ClipboardMonitor: EventSource {
    public let sourceId: String

    private let pollInterval: Duration
    private let maxContentLength: Int
    private let pasteboardReader: ClipboardReader
    private var monitorTask: Task<Void, Never>?

    public init(
        pollInterval: Duration = .seconds(2),
        sourceId: String = "clipboard"
    ) async {
        let pasteboardReader = await MainActor.run {
            ClipboardReader(pasteboard: NSPasteboard.general)
        }
        self.init(
            pasteboardReader: pasteboardReader,
            pollInterval: pollInterval,
            sourceId: sourceId
        )
    }

    @MainActor
    init(
        pasteboard: any ClipboardPasteboard,
        pollInterval: Duration = .seconds(2),
        sourceId: String = "clipboard",
        maxContentLength: Int = 500
    ) {
        self.pasteboardReader = ClipboardReader(pasteboard: pasteboard)
        self.pollInterval = pollInterval
        self.sourceId = sourceId
        self.maxContentLength = maxContentLength
    }

    private init(
        pasteboardReader: ClipboardReader,
        pollInterval: Duration = .seconds(2),
        sourceId: String = "clipboard",
        maxContentLength: Int = 500
    ) {
        self.pasteboardReader = pasteboardReader
        self.pollInterval = pollInterval
        self.sourceId = sourceId
        self.maxContentLength = maxContentLength
    }

    public func start(publishingTo eventBus: EventBus) async {
        guard monitorTask == nil else {
            return
        }

        let pollInterval = self.pollInterval
        var lastChangeCount = await currentChangeCount()

        monitorTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: pollInterval)
                } catch {
                    break
                }

                guard !Task.isCancelled else {
                    break
                }

                let currentChangeCount = await self.currentChangeCount()
                guard currentChangeCount != lastChangeCount else {
                    continue
                }

                lastChangeCount = currentChangeCount

                guard let content = await self.currentStringContent() else {
                    continue
                }

                await eventBus.publish(.clipboardChanged(content: truncated(content)))
            }
        }
    }

    public func stop() async {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func currentChangeCount() async -> Int {
        await MainActor.run {
            pasteboardReader.changeCount()
        }
    }

    private func currentStringContent() async -> String? {
        await MainActor.run {
            pasteboardReader.stringContent()
        }
    }

    private func truncated(_ content: String) -> String {
        String(content.prefix(maxContentLength))
    }
}
