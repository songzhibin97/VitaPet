import Foundation
import AIEngine
import Persistence
import RenderEngine

@MainActor
final class AIProactiveTrigger {
    private var timer: Timer?
    private var isRunning = false

    private let ollamaService: OllamaService
    private let configManager: ConfigManager
    private let onMessage: @MainActor (String) -> Void
    private let onAction: @MainActor (String) -> Void
    private let moodProvider: @MainActor () -> PetMood.MoodLevel

    init(
        ollamaService: OllamaService,
        configManager: ConfigManager,
        moodProvider: @escaping @MainActor () -> PetMood.MoodLevel,
        onMessage: @escaping @MainActor (String) -> Void,
        onAction: @escaping @MainActor (String) -> Void
    ) {
        self.ollamaService = ollamaService
        self.configManager = configManager
        self.moodProvider = moodProvider
        self.onMessage = onMessage
        self.onAction = onAction
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        scheduleNextTrigger()
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    private func scheduleNextTrigger() {
        timer?.invalidate()

        guard isRunning, configManager.config.aiProactiveEnabled else { return }

        let intervalMinutes = max(5, configManager.config.aiProactiveInterval)
        let baseInterval = TimeInterval(intervalMinutes * 60)
        let jitter = baseInterval * Double.random(in: -0.3...0.3)
        let interval = baseInterval + jitter

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.trigger()
                self.scheduleNextTrigger()
            }
        }
    }

    private func trigger() async {
        guard configManager.config.aiProactiveEnabled else { return }

        let status = await ollamaService.status
        guard case .ready = status else { return }

        let mood = moodProvider()
        let hour = Calendar.current.component(.hour, from: Date())

        let context: String
        switch mood {
        case .sad:
            context = "宠物现在心情不太好（sad），请安慰一下主人或者说点开心的。"
        case .happy:
            context = "宠物现在很开心（happy），可以分享快乐的心情。"
        case .normal:
            if hour >= 22 || hour < 6 {
                context = "现在是深夜/凌晨，主人可能还在工作。提醒休息。"
            } else if hour >= 12 && hour <= 13 {
                context = "现在是午饭时间，可以问问主人吃了没。"
            } else if hour >= 17 && hour <= 18 {
                context = "快下班了，可以问问主人今天工作怎么样。"
            } else {
                context = "日常问候，随便聊聊。"
            }
        }

        do {
            let response = try await ollamaService.generateProactive(context: context)
            guard !response.isEmpty else { return }

            let (cleanText, actions) = AppDelegate.parseActionTags(from: response)
            for action in actions {
                onAction(action)
            }

            let trimmedText = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedText.isEmpty {
                onMessage(trimmedText)
            }
        } catch {
            // Ignore proactive failures by design.
        }
    }
}
