import Foundation

@MainActor
final class PomodoroController {
    enum State {
        case idle
        case working
        case breakTime
    }

    private(set) var state: State = .idle
    private var timer: Timer?
    private(set) var remainingSeconds: Int = 0
    private let workDuration = 25 * 60
    private let breakDuration = 5 * 60

    var onStateChanged: ((State, Int) -> Void)?
    var getPetControllers: (() -> [PetWindowController])?

    var isPaused: Bool {
        state != .idle && timer == nil && remainingSeconds > 0
    }

    func start() {
        guard state == .idle else {
            return
        }

        beginWorkSession()
    }

    func pause() {
        guard state != .idle else {
            return
        }

        invalidateTimer()
        notifyStateChanged()
    }

    func resume() {
        guard state != .idle, timer == nil, remainingSeconds > 0 else {
            return
        }

        startTimer()
        notifyStateChanged()
    }

    func reset() {
        invalidateTimer()
        state = .idle
        remainingSeconds = 0
        notifyStateChanged()
    }

    func skip() {
        switch state {
        case .idle:
            beginWorkSession()
        case .working:
            beginBreakSession()
        case .breakTime:
            beginWorkSession()
        }
    }

    private func beginWorkSession() {
        invalidateTimer()
        state = .working
        remainingSeconds = workDuration
        triggerPets(animation: "type", bubble: "专注中...")
        notifyStateChanged()
        startTimer()
    }

    private func beginBreakSession() {
        invalidateTimer()
        state = .breakTime
        remainingSeconds = breakDuration
        triggerPets(animation: "stretch", bubble: "休息一下！")
        notifyStateChanged()
        startTimer()
    }

    private func startTimer() {
        invalidateTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    private func tick() {
        guard remainingSeconds > 0 else {
            completeCurrentState()
            return
        }

        remainingSeconds -= 1
        notifyStateChanged()

        if remainingSeconds == 0 {
            completeCurrentState()
        }
    }

    private func completeCurrentState() {
        invalidateTimer()

        switch state {
        case .working:
            triggerPets(animation: "celebrate", bubble: "专注完成！")
            beginBreakSession()
        case .breakTime:
            triggerPets(animation: "react", bubble: "休息结束，继续加油！")
            beginWorkSession()
        case .idle:
            break
        }
    }

    private func triggerPets(animation: String, bubble: String) {
        for controller in getPetControllers?() ?? [] {
            controller.executeAIAction(animation)
            controller.showBubble(bubble)
        }
    }

    private func invalidateTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func notifyStateChanged() {
        onStateChanged?(state, remainingSeconds)
    }
}
