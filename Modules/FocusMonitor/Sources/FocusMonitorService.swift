import EventBus
import Foundation

@MainActor
public final class FocusMonitorService: Sendable {
    private let detector: any FullscreenDetecting
    private let eventBus: EventBus
    private var isInFocusMode: Bool = false
    private var pollingTask: Task<Void, Never>?

    public init(eventBus: EventBus, detector: any FullscreenDetecting = FullscreenDetector()) {
        self.detector = detector
        self.eventBus = eventBus
    }

    /// 开始监控（2 秒轮询间隔）
    public func start() {
        guard pollingTask == nil else {
            return
        }

        isInFocusMode = detector.isAnyAppFullscreen()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }

                await self.pollOnce()

                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
            }
        }
    }

    /// 停止监控
    public func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// 手动切换 Focus 模式
    public func toggleFocusMode() {
        isInFocusMode.toggle()
        publishFocusEvent(isFocused: isInFocusMode)
    }

    private func pollOnce() async {
        let isFullscreen = detector.isAnyAppFullscreen()
        guard isFullscreen != isInFocusMode else {
            return
        }

        isInFocusMode = isFullscreen
        publishFocusEvent(isFocused: isInFocusMode)
    }

    private func publishFocusEvent(isFocused: Bool) {
        let event: AppEvent = isFocused ? .focusEntered : .focusExited

        Task {
            await eventBus.publish(event)
        }
    }
}
