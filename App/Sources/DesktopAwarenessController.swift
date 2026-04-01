import Foundation
import EventBus

@MainActor
final class DesktopAwarenessController {
    private static let isEnabledDefaultsKey = "desktopAwareness.isEnabled"
    private static let relatedAnimations: [String: [String]] = [
        "type": ["type", "think", "write", "sit"],
        "read": ["read", "sit", "think", "idle"],
        "chat": ["chat", "listen", "nod", "wave"],
        "dance": ["dance", "bounce", "celebrate", "play"],
        "play": ["play", "celebrate", "bounce", "dance"],
        "write": ["write", "think", "type", "sit"],
    ]

    private(set) var isEnabled: Bool
    private var rules: [AppBehaviorRule]
    private var currentRule: AppBehaviorRule?
    private var currentBundleId: String?
    private var bubbleTimer: Timer?
    private var pendingApplyWorkItem: DispatchWorkItem?

    var getPetControllers: (() -> [PetWindowController])?

    init(userDefaults: UserDefaults = .standard) {
        isEnabled = userDefaults.object(forKey: Self.isEnabledDefaultsKey) as? Bool ?? true
        rules = AppBehaviorRules.loadRules()
    }

    func handleAppActivated(bundleId: String, appName: String) {
        guard isEnabled else { return }

        guard bundleId != Bundle.main.bundleIdentifier else {
            clearDesktopBehavior()
            currentBundleId = nil
            return
        }

        guard bundleId != currentBundleId else { return }
        currentBundleId = bundleId

        if let rule = matchRule(for: bundleId) {
            applyRule(rule)
        } else {
            clearDesktopBehavior()
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.isEnabledDefaultsKey)
        if !enabled {
            currentBundleId = nil
            clearDesktopBehavior()
        }
    }

    func reloadRules() {
        rules = AppBehaviorRules.loadRules()

        guard let currentBundleId else { return }
        if let rule = matchRule(for: currentBundleId) {
            applyRule(rule)
        } else {
            clearDesktopBehavior()
        }
    }

    private func matchRule(for bundleId: String) -> AppBehaviorRule? {
        for rule in rules {
            for pattern in rule.bundleIdPatterns where bundleId == pattern || bundleId.hasPrefix(pattern + ".") {
                return rule
            }
        }
        return nil
    }

    private func applyRule(_ rule: AppBehaviorRule) {
        bubbleTimer?.invalidate()
        bubbleTimer = nil
        pendingApplyWorkItem?.cancel()
        pendingApplyWorkItem = nil
        currentRule = rule

        guard let controllers = getPetControllers?(), !controllers.isEmpty else { return }

        for controller in controllers {
            controller.debugPlayAnimation("react")
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let rule = self.currentRule else { return }
            guard let controllers = self.getPetControllers?(), !controllers.isEmpty else { return }
            let relatedAnimations = Self.relatedAnimations[rule.animation] ?? [rule.animation]

            for (index, controller) in controllers.enumerated() {
                let animation = index == 0
                    ? rule.animation
                    : (relatedAnimations.randomElement() ?? rule.animation)
                controller.setDesktopBehavior(animation: animation)
                // 每只宠物显示不同的气泡，错开时间
                if let text = rule.bubbleTexts.randomElement() {
                    let delay = Double(index) * 0.5
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        controller.showBubble(text)
                    }
                }
            }
        }
        pendingApplyWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: workItem)

        bubbleTimer = Timer.scheduledTimer(withTimeInterval: rule.bubbleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let rule = self.currentRule else { return }
                guard let controllers = self.getPetControllers?(), !controllers.isEmpty else { return }

                // 随机选 1-2 只显示气泡
                let count = min(controllers.count, Int.random(in: 1...2))
                for pet in controllers.shuffled().prefix(count) {
                    if let text = rule.bubbleTexts.randomElement() {
                        pet.showBubble(text)
                    }
                }
            }
        }
    }

    func clearDesktopBehavior() {
        bubbleTimer?.invalidate()
        bubbleTimer = nil
        pendingApplyWorkItem?.cancel()
        pendingApplyWorkItem = nil
        currentRule = nil

        guard let controllers = getPetControllers?() else { return }
        for controller in controllers {
            controller.clearDesktopBehavior()
        }
    }
}
