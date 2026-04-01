import AppKit
import ChatUI
import Localization
import Persistence
import RenderEngine
import SpriteKit
import QuartzCore

@MainActor
public final class PetWindowController: NSWindowController {
    private final class TimerStepState: @unchecked Sendable {
        var value = 0
    }

    let petScene: PetScene
    let stateMachine: PetAnimationStateMachine
    let petID: UUID

    private let configManager: ConfigManager
    private let chatController: ChatWindowController
    private(set) var petMood: PetMood
    private let moodDidChange: @MainActor () -> Void
    private var petIdentity: PetIdentity
    private var currentMoodLevelValue: PetMood.MoodLevel
    private var dragStartMouseLocation: CGPoint?
    private var dragStartWindowOrigin: CGPoint?
    private var hasDragged = false
    private var recentDragPositions: [(point: NSPoint, time: TimeInterval)] = []
    private var bubbleWindow: NSWindow?
    private var bubbleDismissWorkItem: DispatchWorkItem?
    private var singleClickWorkItem: DispatchWorkItem?
    private var isDoubleClickPending = false
    private var behaviorEngine: BehaviorEngine!
    private(set) var isExecutingBehavior = false
    private var currentTrackingTarget: (@MainActor () -> NSPoint?)?
    private var debugMoveTimer: Timer?
    private var movementTimer: Timer?
    private var otherPetPositionsProvider: (() -> [NSPoint])?
    private var desktopBehaviorActive = false
    private var animationStateSnapshot: AnimationState = .idle
    private var lastRecordedState: String?
    var behaviorWeightMultipliers: [String: Double] = [:]
    var windowDetector: (() -> [CGRect])?
    var soundManager: SoundManager?
    var onMoodChange: ((String, String, Int, Int, String) -> Void)?
    var onBehaviorChange: ((String, String, String) -> Void)?
    var onPetClick: ((String, String, String) -> Void)?
    private var bubbleTexts: [String] {
        loadBubbleTexts(key: "bubbleTexts")
    }
    private var doubleClickBubbleTexts: [String] {
        loadBubbleTexts(key: "doubleClickTexts")
    }

    /// 从 sprite pack 的 manifest.json 里加载语言包，fallback 到内置默认
    private func loadBubbleTexts(key: String) -> [String] {
        if let texts = petIdentity.customLanguage?[key], !texts.isEmpty {
            return texts
        }

        if let texts = petScene.loadLanguageTexts(key: key), !texts.isEmpty {
            return texts
        }

        return Self.defaultBubbleTexts[key] ?? ["嗨！"]
    }

    private static let defaultBubbleTexts: [String: [String]] = [
        "bubbleTexts": ["嗨！", "别戳我啦~", "有什么事吗？", "好无聊...", "陪我玩！", "摸摸头~", "嘿嘿 😊"],
        "doubleClickTexts": ["太开心啦！", "好喜欢你！", "嘻嘻~", "我们是好朋友！", "开心到转圈圈~"],
    ]

    /// 获取指定动作的气泡文字（从语言包读取）
    func actionBubbleText(for state: String) -> String? {
        if let texts = petIdentity.customLanguage?[state], !texts.isEmpty {
            return texts.randomElement()
        }

        if let texts = petScene.loadLanguageTexts(key: state), !texts.isEmpty {
            return texts.randomElement()
        }
        return nil
    }

    /// 播放动画并显示对应动作气泡（非 debug 用途）
    func playAnimationWithBubble(_ name: String) {
        guard let state = AnimationState(rawValue: name) else { return }
        applyAnimation(state)

        // 50% 概率显示动作气泡（避免太频繁）
        if Double.random(in: 0...1) < 0.5,
           let text = actionBubbleText(for: name) {
            showBubble(text)
        }
    }

    func setDesktopBehavior(animation: String) {
        // 取消正在执行的行为，桌面感知优先
        if isExecutingBehavior {
            behaviorEngine.cancelCurrentBehavior()
            movementTimer?.invalidate()
            movementTimer = nil
            isExecutingBehavior = false
        }

        transitionToState(animation, activatesDesktopBehavior: true)
    }

    func clearDesktopBehavior() {
        desktopBehaviorActive = false
        applyAnimation(.idle)
    }

    var isDesktopBehaviorActive: Bool {
        desktopBehaviorActive
    }

    var animationStateSnapshotForInteraction: AnimationState {
        animationStateSnapshot
    }

    /// Returns whether the pet can be interrupted for a new activity.
    var canBeInterrupted: Bool {
        let nonInterruptibleStates: Set<AnimationState> = [.sleep, .run, .follow]
        if isExecutingBehavior {
            return false
        }
        return !nonInterruptibleStates.contains(animationStateSnapshot)
    }

    var isAvailableForInteraction: Bool {
        !isExecutingBehavior && canBeInterrupted
    }

    var transitionPreparationDelay: TimeInterval {
        switch animationStateSnapshot {
        case .sleep:
            return 2.0
        case .run, .follow:
            return 0.5
        default:
            return 0
        }
    }

    /// Current animation state name (for external checks)
    var currentAnimationState: AnimationState {
        get async { await stateMachine.currentState }
    }

    /// 设置精灵朝向（游戏/行为用）
    func setFacing(_ direction: RenderEngine.HorizontalDirection) {
        petScene.setFacing(direction)
    }

    func setRotation(_ angle: CGFloat) {
        petScene.setRotation(angle)
    }

    func transitionToState(
        _ targetAnimation: String,
        afterDelay: TimeInterval = 0,
        activatesDesktopBehavior: Bool = false
    ) {
        guard let targetState = AnimationState(rawValue: targetAnimation) else {
            return
        }

        Task { @MainActor in
            if afterDelay > 0 {
                try? await Task.sleep(for: .seconds(afterDelay))
            }

            let currentState = await stateMachine.currentState

            if currentState == .sleep {
                applyAnimation(.yawn)
                try? await Task.sleep(for: .seconds(1.2))
                applyAnimation(.stretch)
                try? await Task.sleep(for: .seconds(0.8))
            } else if currentState == .run || currentState == .follow {
                applyAnimation(.walk)
                try? await Task.sleep(for: .seconds(0.5))
            }

            desktopBehaviorActive = activatesDesktopBehavior
            applyAnimation(targetState)
        }
    }

    var isPetVisible: Bool {
        window?.isVisible ?? false
    }

    var currentPetSize: CGFloat {
        CGFloat(petIdentity.size)
    }

    public var windowCenter: NSPoint {
        guard let frame = window?.frame else {
            return NSPoint(x: petIdentity.positionX, y: petIdentity.positionY)
        }
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    public var petName: String {
        petIdentity.name
    }

    var currentSpritePackID: String {
        petIdentity.spritePack
    }

    var currentMoodLevel: PetMood.MoodLevel {
        currentMoodLevelValue
    }

    init(
        petIdentity: PetIdentity,
        configManager: ConfigManager,
        chatController: ChatWindowController,
        moodDidChange: @escaping @MainActor () -> Void = {}
    ) {
        let manifest = SpritePackLoader.loadBundledManifest()
        let behaviorManifest = SpritePackLoader.loadBundledBehaviorManifest()
        let petSize = CGSize(width: petIdentity.size, height: petIdentity.size)
        let behaviorEngine = BehaviorEngine(
            manifest: behaviorManifest,
            screenBounds: { NSScreen.main?.visibleFrame ?? .zero }
        )
        let window = PetWindow(
            contentRect: NSRect(origin: .zero, size: petSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let scene = PetScene(size: petSize, manifest: manifest)
        let stateMachine = PetAnimationStateMachine(initialState: .idle)
        let petMood = PetMood(happiness: petIdentity.happiness)
        let interactionView = PetInteractionView(frame: NSRect(origin: .zero, size: petSize))

        self.petScene = scene
        self.stateMachine = stateMachine
        self.petID = petIdentity.id
        self.configManager = configManager
        self.chatController = chatController
        self.petMood = petMood
        self.moodDidChange = moodDidChange
        self.petIdentity = petIdentity
        self.currentMoodLevelValue = PetMood.level(for: petIdentity.happiness)
        self.behaviorEngine = behaviorEngine
        self.lastRecordedState = self.animationStateSnapshot.rawValue

        super.init(window: window)

        shouldCascadeWindows = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.level = .floating
        window.collectionBehavior = Self.collectionBehavior(for: configManager.config.spaceMode)
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = false
        window.isMovableByWindowBackground = false
        window.setFrameOrigin(
            CGPoint(x: petIdentity.positionX, y: petIdentity.positionY)
        )

        interactionView.controller = self
        interactionView.allowsTransparency = true
        interactionView.preferredFramesPerSecond = 12
        interactionView.ignoresSiblingOrder = true
        interactionView.autoresizingMask = [.width, .height]
        interactionView.presentScene(scene)

        window.contentView = interactionView
        window.alphaValue = 0
        behaviorEngine.onDetectWindows = { [weak self] in
            self?.windowDetector?() ?? []
        }
        behaviorEngine.onRotate = { [weak self] angle in
            self?.setRotation(angle)
        }
        behaviorEngine.onAnimationChange = { [weak self] animationName in
            guard let self, let state = AnimationState(rawValue: animationName) else {
                return
            }
            self.applyAnimation(state, forceState: false)
        }
        updatePetScale(for: petSize)
        applyConfiguredSpritePack()
        self.moodDidChange()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func hidePet() {
        guard let window, window.isVisible else {
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            window.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in
                window.orderOut(nil)
            }
        }
    }

    func showPet() {
        guard let window else {
            return
        }

        window.alphaValue = 0
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            window.animator().alphaValue = 1
        }

        startCursorTrackingIfNeeded()
        setupSpaceChangeObserver(spaceMode: configManager.config.spaceMode)
    }

    func availableSpritePacks() -> [SpritePackInfo] {
        SpritePackLoader.discoverPacks()
    }

    func selectSpritePack(id: String) {
        let packs = availableSpritePacks()
        let selectedDirectory = packs.first(where: { $0.id == id })?.directory
        let resolvedID = id

        petScene.loadSpritePack(from: selectedDirectory)
        reloadSounds(for: selectedDirectory)
        applyAnimation(.idle)
        updatePetScale(for: petScene.size)

        guard petIdentity.spritePack != resolvedID else {
            return
        }

        do {
            try updatePetIdentity { $0.spritePack = resolvedID }
        } catch {
            assertionFailure("Failed to save sprite pack selection: \(error.localizedDescription)")
        }
    }

    func resizePet(to size: CGFloat) {
        guard let window else {
            return
        }

        let newSize = CGSize(width: size, height: size)
        let origin = window.frame.origin
        window.setFrame(NSRect(origin: origin, size: newSize), display: true)
        petScene.size = newSize
        petScene.petNode.position = CGPoint(x: size / 2, y: size / 2)
        updatePetScale(for: newSize)
        repositionBubble()

        do {
            try updatePetIdentity { $0.size = size }
        } catch {
            assertionFailure("Failed to save pet size: \(error.localizedDescription)")
        }
    }

    func setTrackingTarget(_ target: (@MainActor () -> NSPoint?)?) {
        currentTrackingTarget = target
    }

    func setOtherPetPositionsProvider(_ provider: @escaping () -> [NSPoint]) {
        otherPetPositionsProvider = provider
    }

    fileprivate func handleMouseDown(with event: NSEvent) {
        guard let window else {
            return
        }

        isDoubleClickPending = false
        behaviorEngine.cancelCurrentBehavior()
        behaviorEngine.stopCursorTracking()
        isExecutingBehavior = false
        dragStartMouseLocation = NSEvent.mouseLocation
        dragStartWindowOrigin = window.frame.origin
        hasDragged = false
        recentDragPositions = []

        Task {
            if let state = await stateMachine.handleTrigger(.custom("drag_start"), mood: await petMood.level) {
                await MainActor.run {
                    self.applyAnimation(state, forceState: false)
                }
            }
        }
    }

    fileprivate func handleMouseDragged(with event: NSEvent) {
        guard
            let window,
            let dragStartMouseLocation,
            let dragStartWindowOrigin
        else {
            return
        }

        let currentMouseLocation = NSEvent.mouseLocation
        let deltaX = currentMouseLocation.x - dragStartMouseLocation.x
        let deltaY = currentMouseLocation.y - dragStartMouseLocation.y

        if abs(deltaX) > 1 || abs(deltaY) > 1 {
            hasDragged = true
        }

        window.setFrameOrigin(
            CGPoint(
                x: dragStartWindowOrigin.x + deltaX,
                y: dragStartWindowOrigin.y + deltaY
            )
        )

        recentDragPositions.append(
            (point: currentMouseLocation, time: ProcessInfo.processInfo.systemUptime)
        )
        if recentDragPositions.count > 5 {
            recentDragPositions.removeFirst()
        }
    }

    fileprivate func handleMouseUp(with event: NSEvent) {
        let didDrag = hasDragged
        let dragVelocity = didDrag ? currentDragVelocity() : nil

        dragStartMouseLocation = nil
        dragStartWindowOrigin = nil
        hasDragged = false
        recentDragPositions = []

        Task {
            _ = await stateMachine.handleTrigger(.custom("drag_end"), mood: await petMood.level)

            await MainActor.run {
                if didDrag {
                    self.singleClickWorkItem?.cancel()
                    self.singleClickWorkItem = nil

                    guard let dragVelocity, abs(dragVelocity.y) > 50 else {
                        self.applyAnimation(.idle)
                        self.startCursorTrackingIfNeeded()
                        self.persistWindowPosition()
                        self.resolveOverlapAfterDrag()
                        return
                    }

                    self.performBounce(with: dragVelocity) {
                        Task {
                            await self.stateMachine.setState(.idle)
                            self.startCursorTrackingIfNeeded()
                        }
                        self.applyAnimation(.idle, forceState: false)
                        self.persistWindowPosition()
                        self.resolveOverlapAfterDrag()
                    }

                    return
                }

                if event.clickCount == 2 {
                    self.isDoubleClickPending = true
                    self.singleClickWorkItem?.cancel()
                    self.singleClickWorkItem = nil
                    self.onPetClick?(
                        self.petID.uuidString,
                        self.petIdentity.name,
                        "double"
                    )
                    Task {
                        await self.adjustMood(by: 10)
                        await MainActor.run {
                            self.triggerCelebrate()
                            self.showBubble(self.bubbleText(for: .doubleClick))
                        }
                    }
                    return
                }

                let workItem = DispatchWorkItem { [weak self] in
                    guard let self else {
                        return
                    }
                    guard !self.isDoubleClickPending else {
                        return
                    }

                    self.singleClickWorkItem = nil
                    self.onPetClick?(
                        self.petID.uuidString,
                        self.petIdentity.name,
                        "single"
                    )
                    Task {
                        await self.adjustMood(by: 5)
                        await MainActor.run {
                            self.triggerReact()
                            self.showBubble(self.bubbleText(for: .singleClick))
                        }
                    }
                }

                self.singleClickWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
            }
        }
    }

    private func triggerReact() {
        Task {
            if let state = await stateMachine.handleTrigger(.userInteract, mood: await petMood.level) {
                await MainActor.run {
                    self.applyAnimation(state, forceState: false)
                    self.updatePetScale(for: self.petScene.size)
                }
            }
        }
    }

    private func triggerCelebrate() {
        Task {
            if let state = await stateMachine.handleTrigger(.custom("celebrate"), mood: await petMood.level) {
                await self.handleMoodAdjustmentForState(state)
                await MainActor.run {
                    self.applyAnimation(state, forceState: false)
                    self.updatePetScale(for: self.petScene.size)
                }
            }
        }
    }

    func handleAnimationTrigger(_ trigger: AnimationTrigger) async {
        // Don't process timer triggers while a behavior is executing
        if case .timer = trigger, isExecutingBehavior {
            return
        }

        if case .timer = trigger, desktopBehaviorActive {
            return
        }

        let moodLevel = await petMood.level
        let isTimerTrigger = {
            switch trigger {
            case .timer:
                return true
            default:
                return false
            }
        }()

        if isTimerTrigger {
            let currentState = await stateMachine.currentState
            if currentState == .idle {
                let behaviorName = behaviorEngine.pickIdleBehavior(
                    for: moodLevel.rawValue,
                    weightMultipliers: behaviorWeightMultipliers
                )
                if let mappedState = animationStateForBehavior(behaviorName) {
                    await stateMachine.setState(mappedState)
                    await handleMoodAdjustmentForState(mappedState)
                    applyAnimation(mappedState, forceState: false)

                    if let definition = behaviorEngine.behaviorDefinition(for: behaviorName),
                       isMovementBehavior(definition.type) {
                        behaviorEngine.stopCursorTracking()
                        executeBehaviorMovement(behaviorName)
                    } else if mappedState == .idle {
                        startCursorTrackingIfNeeded()
                    } else {
                        behaviorEngine.stopCursorTracking()
                    }

                    return
                }
            }
        }

        guard let nextState = await stateMachine.handleTrigger(trigger, mood: moodLevel) else {
            return
        }

        await handleMoodAdjustmentForState(nextState)
        applyAnimation(nextState, forceState: false)

        if let behaviorName = behaviorNameForState(nextState),
           let definition = behaviorEngine.behaviorDefinition(for: behaviorName),
           isMovementBehavior(definition.type) {
            executeBehaviorMovement(behaviorName)
            behaviorEngine.stopCursorTracking()
        } else if nextState == .idle {
            startCursorTrackingIfNeeded()
        } else {
            behaviorEngine.stopCursorTracking()
        }
    }

    private func persistWindowPosition() {
        guard let origin = window?.frame.origin else {
            return
        }

        do {
            try updatePetIdentity {
                $0.positionX = origin.x
                $0.positionY = origin.y
            }
        } catch {
            assertionFailure("Failed to save window position: \(error.localizedDescription)")
        }
    }

    private func resolveOverlapAfterDrag() {
        guard let positions = otherPetPositionsProvider?(),
              let window else {
            return
        }

        let myCenter = NSPoint(x: window.frame.midX, y: window.frame.midY)
        let minDistance = window.frame.width * 0.5
        let safeDistance = window.frame.width * 0.7

        for otherCenter in positions {
            let dx = myCenter.x - otherCenter.x
            let dy = myCenter.y - otherCenter.y
            let distance = sqrt(dx * dx + dy * dy)

            if distance < minDistance {
                let angle = distance > 0 ? atan2(dy, dx) : CGFloat.random(in: 0...(.pi * 2))
                let newX = otherCenter.x + cos(angle) * safeDistance - (window.frame.width / 2)
                let newY = otherCenter.y + sin(angle) * safeDistance - (window.frame.height / 2)
                let resolvedOrigin = clampedWindowOrigin(
                    NSPoint(x: newX, y: newY),
                    for: window
                )
                window.setFrameOrigin(resolvedOrigin)
                persistWindowPosition()
                break
            }
        }
    }

    // MARK: - Debug

    func debugPlayAnimation(_ name: String) {
        guard let state = AnimationState(rawValue: name) else { return }
        behaviorEngine.cancelCurrentBehavior()
        behaviorEngine.stopCursorTracking()
        applyAnimation(state)

        // Also trigger real movement if this state has a move behavior
        if let behaviorName = behaviorNameForState(state),
           let definition = behaviorEngine.behaviorDefinition(for: behaviorName),
           isMovementBehavior(definition.type) {
            executeBehaviorMovement(behaviorName)
        }

        showBubble("🐛 anim: \(name)")
    }

    func debugMoveTest() {
        guard let window else { return }
        debugMoveTimer?.invalidate()
        let start = window.frame.origin
        let target = NSPoint(x: start.x + 150, y: start.y)
        let duration: TimeInterval = 2.0
        let fps: TimeInterval = 60
        let steps = Int(duration * fps)
        let stepState = TimerStepState()

        debugMoveTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / fps, repeats: true) { [weak self] timer in
            stepState.value += 1
            let progress = Double(stepState.value) / Double(steps)
            let x = start.x + (target.x - start.x) * progress
            let y = start.y + (target.y - start.y) * progress
            MainActor.assumeIsolated {
                window.setFrameOrigin(NSPoint(x: x, y: y))
                self?.repositionBubble()
            }
            if stepState.value >= steps {
                timer.invalidate()
                MainActor.assumeIsolated {
                    self?.debugMoveTimer = nil
                    window.setFrameOrigin(target)
                }
            }
        }
        showBubble("🔬 moving →")
    }

    func debugExecuteBehavior(_ name: String) {
        guard let definition = behaviorEngine.behaviorDefinition(for: name) else { return }

        // Cancel any in-progress behavior first
        movementTimer?.invalidate()
        movementTimer = nil
        behaviorEngine.cancelCurrentBehavior()
        behaviorEngine.stopCursorTracking()
        isExecutingBehavior = false

        if let animName = definition.animation,
           let state = AnimationState(rawValue: animName) {
            applyAnimation(state)
        }

        if isMovementBehavior(definition.type) {
            executeBehaviorMovement(name)
        }
    }

    func debugListBehaviors() -> [String] {
        Array(behaviorEngine.allBehaviorNames()).sorted()
    }

    func closePet() {
        behaviorEngine.cancelCurrentBehavior()
        behaviorEngine.stopCursorTracking()
        debugMoveTimer?.invalidate()
        debugMoveTimer = nil
        movementTimer?.invalidate()
        movementTimer = nil
        singleClickWorkItem?.cancel()
        singleClickWorkItem = nil
        bubbleDismissWorkItem?.cancel()
        bubbleDismissWorkItem = nil
        bubbleWindow?.close()
        close()
    }

    func showBubble(_ text: String, duration: TimeInterval = 2.0) {
        bubbleDismissWorkItem?.cancel()

        guard let petWindow = window else {
            return
        }

        // Don't let random bubbles override thinking state
        if isThinking && text != "..." {
            return
        }

        bubbleWindow?.orderOut(nil)

        let bubbleView = PetBubbleView(text: text)
        let fittingSize = bubbleView.fittingSize
        let bubbleFrame = NSRect(origin: .zero, size: fittingSize)
        let window = NSWindow(
            contentRect: bubbleFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .floating
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = Self.collectionBehavior(for: configManager.config.spaceMode)
        bubbleView.frame = bubbleFrame
        bubbleView.autoresizingMask = [.width, .height]
        window.contentView = bubbleView
        bubbleWindow = window

        positionBubble(window, above: petWindow)
        window.alphaValue = 0
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            window.animator().alphaValue = 1
        }

        let dismissWorkItem = DispatchWorkItem { [weak self, weak window] in
            guard let self, let window else {
                return
            }

            Task { @MainActor in
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    window.animator().alphaValue = 0
                } completionHandler: {
                    Task { @MainActor in
                        window.orderOut(nil)
                        if self.bubbleWindow === window {
                            self.bubbleWindow = nil
                        }
                    }
                }
            }
        }

        bubbleDismissWorkItem = dismissWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: dismissWorkItem)
    }

    func showAIBubble(_ text: String) {
        isThinking = false
        applyAnimation(.chat)
        let duration = max(3.0, Double(text.count) / 10.0)
        showBubble(text, duration: duration)
    }

    private var isThinking = false

    func showThinkingBubble() {
        isThinking = true
        applyAnimation(.think)
        showBubble("...", duration: 60)  // 长时间不自动消失
    }

    func dismissThinkingBubble() {
        guard isThinking else { return }
        isThinking = false
        bubbleDismissWorkItem?.cancel()
        bubbleDismissWorkItem = nil
        if let bubbleWindow {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                bubbleWindow.animator().alphaValue = 0
            } completionHandler: { [weak self, weak bubbleWindow] in
                Task { @MainActor in
                    bubbleWindow?.orderOut(nil)
                    if let self, self.bubbleWindow === bubbleWindow {
                        self.bubbleWindow = nil
                    }
                }
            }
        }
    }

    func executeAIAction(_ action: String) {
        behaviorEngine.cancelCurrentBehavior()
        behaviorEngine.stopCursorTracking()

        if let definition = behaviorEngine.behaviorDefinition(for: action),
           isMovementBehavior(definition.type) {
            if let state = animationStateForBehavior(action) {
                applyAnimation(state)
            }
            executeBehaviorMovement(action)
            return
        }

        if let state = AnimationState(rawValue: action) {
            applyAnimation(state)
        }
    }

    private static func collectionBehavior(for spaceMode: String) -> NSWindow.CollectionBehavior {
        switch spaceMode {
        case "singleSpace":
            return [.fullScreenAuxiliary]
        default:
            // "allSpaces" (default): visible on all desktops, same as Dock/menu bar
            return [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
    }

    func setupSpaceChangeObserver(spaceMode: String) {
        // No observer needed — macOS handles both modes natively
    }

    private func repositionBubble() {
        guard let bubbleWindow, let petWindow = window else {
            return
        }

        positionBubble(bubbleWindow, above: petWindow)
    }

    private func positionBubble(_ bubbleWindow: NSWindow, above petWindow: NSWindow) {
        guard let screen = petWindow.screen ?? bubbleWindow.screen ?? NSScreen.main else {
            return
        }

        let bubbleSize = bubbleWindow.frame.size
        let petFrame = petWindow.frame
        let visibleFrame = screen.visibleFrame
        let bubbleWidth = bubbleSize.width
        let bubbleHeight = bubbleSize.height

        // Bubble sits right above the window (window = cat, no transparent margins)
        let spriteTop = petFrame.maxY + 4
        var bubbleX = petFrame.midX - (bubbleWidth / 2)
        bubbleX = max(visibleFrame.minX, min(bubbleX, visibleFrame.maxX - bubbleWidth))

        var bubbleY = spriteTop
        if bubbleY + bubbleHeight > visibleFrame.maxY {
            bubbleY = petFrame.minY - bubbleHeight - 4
        }
        bubbleY = max(visibleFrame.minY, min(bubbleY, visibleFrame.maxY - bubbleHeight))

        let origin = CGPoint(x: bubbleX, y: bubbleY)
        bubbleWindow.setFrameOrigin(origin)
    }

    private func updatePetScale(for size: CGSize) {
        petScene.petNode.position = CGPoint(x: size.width / 2, y: size.height / 2)
        petScene.petNode.size = size
        petScene.setFacing(petScene.petNode.xScale < 0 ? .left : .right)
        petScene.petNode.yScale = 1
    }

    private func behaviorNameForState(_ state: AnimationState) -> String? {
        if behaviorEngine.behaviorDefinition(for: state.rawValue) != nil {
            return state.rawValue
        }

        switch state {
        case .walk:
            return "walk"
        case .bounce:
            return "bounce"
        case .stretch:
            return "stretch"
        case .yawn:
            return "yawn"
        case .lookAround:
            return "lookAround"
        case .sleep:
            return "sleep"
        default:
            return nil
        }
    }

    @MainActor
    private func currentPetCenter() -> NSPoint {
        windowCenter
    }

    private func animationStateForBehavior(_ behaviorName: String) -> AnimationState? {
        if let state = AnimationState(rawValue: behaviorName) {
            return state
        }

        switch behaviorName.lowercased() {
        case "walk", "patrol":
            return .walk
        case "jump":
            return .bounce
        case "sitonwindow", "windowclimb":
            return .walk
        case "chase":
            return .walk
        case "hide":
            return .react
        case "bounce":
            return .bounce
        case "stretch":
            return .stretch
        case "yawn":
            return .yawn
        case "lookaround":
            return .lookAround
        case "sleep":
            return .sleep
        default:
            return nil
        }
    }

    private func isMovementBehavior(_ type: BehaviorType) -> Bool {
        switch type {
        case .move, .jump, .chase, .hide, .windowSit, .windowClimb:
            return true
        default:
            return false
        }
    }

    private func executeBehaviorMovement(_ behaviorName: String) {
        guard let window else {
            return
        }

        isExecutingBehavior = true
        let isJump = behaviorEngine.behaviorDefinition(for: behaviorName)?.type == .jump
        let onMove: @Sendable (NSPoint, TimeInterval) -> Void = { [weak self] target, duration in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                guard duration > 0 else {
                    window.setFrameOrigin(target)
                    self.repositionBubble()
                    return
                }

                let start = window.frame.origin
                let fps: TimeInterval = 60
                let steps = max(Int(duration * fps), 1)
                let stepState = TimerStepState()
                self.movementTimer?.invalidate()
                self.movementTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / fps, repeats: true) { [weak self] timer in
                    stepState.value += 1
                    let progress = Double(stepState.value) / Double(steps)
                    let x = start.x + (target.x - start.x) * progress
                    let y = start.y + (target.y - start.y) * progress
                    MainActor.assumeIsolated {
                        window.setFrameOrigin(NSPoint(x: x, y: y))
                        self?.repositionBubble()
                    }
                    if stepState.value >= steps {
                        timer.invalidate()
                        MainActor.assumeIsolated {
                            self?.movementTimer = nil
                            window.setFrameOrigin(target)
                        }
                    }
                }
            }
        }
        let onFlip: @Sendable (Bool) -> Void = { [weak self] faceLeft in
            Task { @MainActor in
                self?.petScene.setFacing(faceLeft ? .left : .right)
            }
        }
        let onComplete: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                guard let self else {
                    return
                }

                self.movementTimer?.invalidate()
                self.movementTimer = nil
                self.isExecutingBehavior = false
                self.currentTrackingTarget = nil
                if isJump {
                    do {
                        try await Task.sleep(for: .milliseconds(180))
                    } catch {
                        return
                    }
                }

                self.applyAnimation(.idle)
                self.startCursorTrackingIfNeeded()
                self.persistWindowPosition()
            }
        }
        let onLand: (@Sendable () -> Void)?
        if isJump {
            onLand = { [weak self] in
                _ = Task { @MainActor in
                    self?.applyAnimation(.bounce)
                }
            }
        } else {
            onLand = nil
        }

        behaviorEngine.executeBehavior(
            behaviorName,
            currentPosition: window.frame.origin,
            petSize: window.frame.width,
            trackingTarget: currentTrackingTarget,
            otherPetPositions: otherPetPositionsProvider,
            onMove: onMove,
            onFlip: onFlip,
            onComplete: onComplete,
            onLand: onLand
        )
    }

    private func startCursorTrackingIfNeeded() {
        guard !isExecutingBehavior else {
            return
        }

        behaviorEngine.startCursorTracking(
            petCenter: { [weak self] in
                let center = MainActor.assumeIsolated {
                    self?.currentPetCenter() ?? .zero
                }
                return center
            },
            onFlip: { [weak self] faceLeft in
                Task { @MainActor in
                    self?.petScene.setFacing(faceLeft ? .left : .right)
                }
            },
            onReact: { [weak self] in
                guard let self else {
                    return
                }
                Task { @MainActor in
                    self.applyAnimation(.react)
                    self.showBubble(self.bubbleText(for: .singleClick))
                    do {
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        return
                    }
                    self.applyAnimation(.idle)
                    self.startCursorTrackingIfNeeded()
                }
            }
        )
    }

    private func applyAnimation(_ state: AnimationState, forceState: Bool = true) {
        animationStateSnapshot = state
        soundManager?.playSound(for: state.rawValue)
        petScene.playAnimation(for: state)
        recordBehaviorChangeIfNeeded(for: state)
        guard forceState else {
            return
        }
        Task { await stateMachine.forceState(state) }
    }

    private func recordBehaviorChangeIfNeeded(for state: AnimationState) {
        let stateName = state.rawValue
        guard lastRecordedState != stateName else {
            return
        }

        lastRecordedState = stateName
        onBehaviorChange?(petID.uuidString, petIdentity.name, stateName)
    }

    private func applyConfiguredSpritePack() {
        let selectedSpritePack = petIdentity.spritePack
        let selectedDirectory = availableSpritePacks().first(where: { $0.id == selectedSpritePack })?.directory

        if let selectedDirectory {
            petScene.loadSpritePack(from: selectedDirectory)
            reloadSounds(for: selectedDirectory)
            return
        }

        // Fallback: 尝试 PixelCat，再 fallback 到 bundled
        if let fallbackDir = availableSpritePacks().first(where: { $0.id == "PixelCat" })?.directory {
            petScene.loadSpritePack(from: fallbackDir)
            reloadSounds(for: fallbackDir)
        } else {
            petScene.loadSpritePack(from: nil)
            reloadSounds(for: availableSpritePacks().first?.directory)
        }
        do {
            try updatePetIdentity { $0.spritePack = "PixelCat" }
        } catch {
            // ignore
        }
    }

    func reloadCurrentSpritePackSounds() {
        let selectedDirectory = availableSpritePacks().first(where: { $0.id == petIdentity.spritePack })?.directory
        reloadSounds(for: selectedDirectory)
    }

    private func reloadSounds(for packDirectory: URL?) {
        guard let soundManager else {
            return
        }

        let resolvedPackDirectory = packDirectory
            ?? availableSpritePacks().first(where: { $0.id == "PixelCat" })?.directory
            ?? availableSpritePacks().first?.directory
        guard let resolvedPackDirectory else {
            return
        }

        let manifest = (try? SpritePackLoader.loadManifest(from: resolvedPackDirectory))
            ?? SpritePackLoader.loadBundledManifest()
        soundManager.loadSounds(from: resolvedPackDirectory, manifest: manifest)
    }

    private func updatePetIdentity(_ transform: (inout PetIdentity) -> Void) throws {
        // 先从 configManager 读取最新的 petIdentity（避免覆盖其他字段的修改）
        var updatedPet = configManager.config.pets.first(where: { $0.id == petID }) ?? petIdentity
        transform(&updatedPet)

        try configManager.update { config in
            guard let index = config.pets.firstIndex(where: { $0.id == self.petID }) else {
                return
            }

            config.pets[index] = updatedPet
        }

        petIdentity = updatedPet
    }

    func setCustomLanguage(_ language: [String: [String]]?) {
        petIdentity.customLanguage = language
    }

    private func bubbleText(for interaction: BubbleInteraction) -> String {
        switch (interaction, currentMoodLevelValue) {
        case (.doubleClick, _):
            return doubleClickBubbleTexts.randomElement() ?? "!"
        case (.singleClick, .happy):
            return (doubleClickBubbleTexts + bubbleTexts).randomElement() ?? "Hi!"
        case (.singleClick, .normal):
            return bubbleTexts.randomElement() ?? "Hi!"
        case (.singleClick, .sad):
            let quieterTexts = bubbleTexts.filter { !$0.contains("😊") }
            return quieterTexts.randomElement() ?? bubbleTexts.randomElement() ?? "Hi!"
        }
    }

    private func handleMoodAdjustmentForState(_ state: AnimationState) async {
        guard state == .celebrate else {
            return
        }

        await adjustMood(by: 3)
    }

    func adjustMood(by delta: Int) async {
        await petMood.adjust(by: delta)
        let happiness = await petMood.happiness
        let moodLevel = await petMood.level

        await MainActor.run {
            self.currentMoodLevelValue = moodLevel

            do {
                try self.updatePetIdentity { $0.happiness = happiness }
            } catch {
                assertionFailure("Failed to save pet mood: \(error.localizedDescription)")
            }

            self.moodDidChange()
            self.onMoodChange?(
                self.petID.uuidString,
                self.petIdentity.name,
                happiness,
                delta,
                moodLevel.rawValue
            )
        }
    }

    private func currentDragVelocity() -> CGPoint? {
        guard
            let firstSample = recentDragPositions.first,
            let lastSample = recentDragPositions.last
        else {
            return nil
        }

        let timeDelta = lastSample.time - firstSample.time
        guard timeDelta > 0 else {
            return nil
        }

        return CGPoint(
            x: (lastSample.point.x - firstSample.point.x) / timeDelta,
            y: (lastSample.point.y - firstSample.point.y) / timeDelta
        )
    }

    private func performBounce(with velocity: CGPoint, completion: @escaping @MainActor () -> Void) {
        guard let window else {
            completion()
            return
        }

        let baseOrigin = clampedWindowOrigin(window.frame.origin, for: window)
        let travel = CGPoint(x: velocity.x * 0.1, y: velocity.y * 0.1)
        let firstOrigin = clampedWindowOrigin(
            CGPoint(x: baseOrigin.x + travel.x, y: baseOrigin.y + travel.y),
            for: window
        )
        let secondOrigin = clampedWindowOrigin(
            CGPoint(x: baseOrigin.x - (travel.x * 0.5), y: baseOrigin.y - (travel.y * 0.5)),
            for: window
        )
        let thirdOrigin = clampedWindowOrigin(
            CGPoint(x: baseOrigin.x + (travel.x * 0.25), y: baseOrigin.y + (travel.y * 0.25)),
            for: window
        )

        window.setFrameOrigin(baseOrigin)
        repositionBubble()

        playBounceAnimation()
        animateWindow(to: firstOrigin, duration: 0.15) {
            self.animateWindow(to: secondOrigin, duration: 0.12) {
                self.animateWindow(to: thirdOrigin, duration: 0.1) {
                    window.setFrameOrigin(baseOrigin)
                    self.repositionBubble()
                    completion()
                }
            }
        }
    }

    private func playBounceAnimation() {
        applyAnimation(.bounce, forceState: false)
    }

    private func animateWindow(
        to origin: CGPoint,
        duration: TimeInterval,
        completion: @escaping @MainActor () -> Void
    ) {
        guard let window else {
            completion()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            window.animator().setFrameOrigin(origin)
        } completionHandler: {
            Task { @MainActor in
                self.repositionBubble()
                completion()
            }
        }
    }

    private func clampedWindowOrigin(_ origin: CGPoint, for window: NSWindow) -> CGPoint {
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame

        guard let visibleFrame else {
            return origin
        }

        let maxX = visibleFrame.maxX - window.frame.width
        let maxY = visibleFrame.maxY - window.frame.height

        return CGPoint(
            x: min(max(origin.x, visibleFrame.minX), maxX),
            y: min(max(origin.y, visibleFrame.minY), maxY)
        )
    }
}

private enum BubbleInteraction {
    case singleClick
    case doubleClick
}

@MainActor
private final class PetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class PetInteractionView: SKView {
    weak var controller: PetWindowController?

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        controller?.handleMouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        controller?.handleMouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        controller?.handleMouseUp(with: event)
    }
}

@MainActor
private final class PetBubbleView: NSView {
    private let textField: NSTextField
    private let tailHeight: CGFloat = 8
    private let padding = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

    init(text: String) {
        self.textField = NSTextField(labelWithString: text)
        super.init(frame: .zero)

        wantsLayer = true

        textField.font = .systemFont(ofSize: 14, weight: .medium)
        textField.textColor = .white
        textField.alignment = .center
        textField.backgroundColor = .clear
        textField.isBezeled = false
        textField.isEditable = false
        textField.sizeToFit()

        let size = CGSize(
            width: textField.frame.width + padding.left + padding.right,
            height: textField.frame.height + padding.top + padding.bottom + tailHeight
        )
        frame = NSRect(origin: .zero, size: size)

        // Build bubble shape with tail as a CAShapeLayer
        let shapeLayer = CAShapeLayer()
        let path = CGMutablePath()

        // Bubble body
        let bodyRect = CGRect(
            x: 0,
            y: tailHeight,
            width: size.width,
            height: size.height - tailHeight
        )
        path.addRoundedRect(in: bodyRect, cornerWidth: 12, cornerHeight: 12)

        // Tail triangle
        let midX = size.width / 2
        path.move(to: CGPoint(x: midX - 6, y: tailHeight))
        path.addLine(to: CGPoint(x: midX, y: 0))
        path.addLine(to: CGPoint(x: midX + 6, y: tailHeight))
        path.closeSubpath()

        shapeLayer.path = path
        shapeLayer.fillColor = NSColor(calibratedWhite: 0.15, alpha: 0.92).cgColor
        layer?.addSublayer(shapeLayer)

        addSubview(textField)
        layoutTextField()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var fittingSize: NSSize {
        CGSize(
            width: textField.frame.width + padding.left + padding.right,
            height: textField.frame.height + padding.top + padding.bottom + tailHeight
        )
    }

    override func layout() {
        super.layout()
        layoutTextField()
    }

    private func layoutTextField() {
        textField.frame = NSRect(
            x: padding.left,
            y: tailHeight + padding.bottom,
            width: bounds.width - padding.left - padding.right,
            height: bounds.height - tailHeight - padding.top - padding.bottom
        )
    }
}
