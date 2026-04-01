import AppKit
import RenderEngine

@MainActor
final class CatchGame: MiniGame {
    let name = "接东西"
    let minPets = 1
    let maxPets = 5

    private final class FallingItem {
        let id = UUID()
        let window: NSWindow
        let emoji: String
        var velocity: CGFloat

        init(window: NSWindow, emoji: String, velocity: CGFloat) {
            self.window = window
            self.emoji = emoji
            self.velocity = velocity
        }
    }

    private let itemEmojis = ["🍎", "🌟", "🍕", "🍰", "🐟"]
    private var pets: [PetWindowController] = []
    private var onComplete: (() -> Void)?
    private var gameTimer: Timer?
    private var spawnTimer: Timer?
    private var remainingTime: Int = 20
    private var items: [FallingItem] = []
    private var scores: [ObjectIdentifier: Int] = [:]
    private var baseY: [ObjectIdentifier: CGFloat] = [:]
    private var pendingItems: [DispatchWorkItem] = []

    func start(pets: [PetWindowController], onComplete: @escaping () -> Void) {
        self.pets = pets
        self.onComplete = onComplete
        self.remainingTime = 20

        let frame = MiniGameSupport.mainScreenFrame()
        let spacing = frame.width / CGFloat(max(1, pets.count + 1))

        for (index, pet) in pets.enumerated() {
            let x = frame.minX + spacing * CGFloat(index + 1)
            let y = frame.minY + 20
            let origin = MiniGameSupport.clamp(origin: NSPoint(x: x, y: y), for: pet, in: frame)
            pet.window?.setFrameOrigin(origin)
            pet.transitionToState("react")
            pet.showBubble("接住它们！", duration: 1.0)
            let key = ObjectIdentifier(pet)
            scores[key] = 0
            baseY[key] = origin.y
        }

        gameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickGame()
            }
        }
        spawnTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.spawnItem()
            }
        }

        for second in 1...20 {
            pendingItems.append(MiniGameSupport.schedule(after: Double(second)) { [weak self] in
                guard let self else { return }
                self.remainingTime = max(0, 20 - second)
                if self.remainingTime > 0, second % 5 == 0 {
                    self.pets.first?.showBubble("剩余 \(self.remainingTime) 秒")
                }
                if self.remainingTime == 0 {
                    self.finishGame()
                }
            })
        }
    }

    func stop() {
        gameTimer?.invalidate()
        gameTimer = nil
        spawnTimer?.invalidate()
        spawnTimer = nil
        pendingItems.forEach { $0.cancel() }
        pendingItems.removeAll()
        for item in items {
            item.window.close()
        }
        items.removeAll()
        scores.removeAll()
        baseY.removeAll()
        pets.removeAll()
        onComplete = nil
        remainingTime = 20
    }

    private func spawnItem() {
        let frame = MiniGameSupport.mainScreenFrame()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 30, height: 30),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true

        let textField = NSTextField(labelWithString: itemEmojis.randomElement() ?? "🍎")
        textField.alignment = .center
        textField.font = .systemFont(ofSize: 24)
        textField.frame = NSRect(x: 0, y: 0, width: 30, height: 30)
        let container = NSView(frame: textField.frame)
        container.addSubview(textField)
        window.contentView = container
        window.setFrameOrigin(NSPoint(x: CGFloat.random(in: frame.minX...(frame.maxX - 30)), y: frame.maxY - 30))
        window.orderFrontRegardless()

        let item = FallingItem(
            window: window,
            emoji: textField.stringValue,
            velocity: CGFloat.random(in: 6...10)
        )
        items.append(item)
    }

    private func tickGame() {
        let frame = MiniGameSupport.mainScreenFrame()

        // 每只宠物自动追最近的掉落物
        movePetsTowardItems(in: frame)

        // 掉落物下落 + 碰撞检测
        var survivors: [FallingItem] = []
        for item in items {
            let origin = item.window.frame.origin
            let nextOrigin = NSPoint(x: origin.x, y: origin.y - item.velocity)
            item.window.setFrameOrigin(nextOrigin)

            if let catcher = pets.first(where: { pet in
                let petCenter = pet.windowCenter
                let itemCenter = NSPoint(x: item.window.frame.midX, y: item.window.frame.midY)
                return abs(itemCenter.x - petCenter.x) <= 50 && abs(itemCenter.y - petCenter.y) <= 50
            }) {
                let key = ObjectIdentifier(catcher)
                scores[key, default: 0] += 1
                catcher.transitionToState("celebrate")
                catcher.showBubble("+1 \(item.emoji)", duration: 0.6)
                item.window.close()
                pendingItems.append(MiniGameSupport.schedule(after: 0.35) { [weak catcher] in
                    catcher?.transitionToState("idle")
                })
                continue
            }

            if item.window.frame.maxY < frame.minY {
                item.window.close()
                continue
            }

            survivors.append(item)
        }

        items = survivors
    }

    private func movePetsTowardItems(in frame: NSRect) {
        // 为每只宠物分配最近的未被其他宠物抢占的掉落物
        var claimedItems = Set<UUID>()

        for pet in pets {
            guard let window = pet.window else { continue }
            let petCenter = pet.windowCenter

            // 找最近的未被抢占的掉落物
            var bestItem: FallingItem?
            var bestDist: CGFloat = .infinity
            for item in items where !claimedItems.contains(item.id) {
                let itemCenter = NSPoint(x: item.window.frame.midX, y: item.window.frame.midY)
                let dist = abs(itemCenter.x - petCenter.x)
                if dist < bestDist {
                    bestDist = dist
                    bestItem = item
                }
            }

            guard let target = bestItem else { continue }
            claimedItems.insert(target.id)

            // 朝目标 X 方向移动
            let targetX = target.window.frame.midX - window.frame.width / 2
            let dx = targetX - window.frame.origin.x
            let moveSpeed: CGFloat = 6.0
            let step = min(abs(dx), moveSpeed) * (dx > 0 ? 1 : -1)
            let newX = min(max(window.frame.origin.x + step, frame.minX), frame.maxX - window.frame.width)
            let baseYPos = baseY[ObjectIdentifier(pet)] ?? window.frame.origin.y
            window.setFrameOrigin(NSPoint(x: newX, y: baseYPos))

            // 朝向
            if abs(dx) > 2 {
                pet.setFacing(dx > 0 ? .right : .left)
            }
        }
    }

    private func finishGame() {
        gameTimer?.invalidate()
        gameTimer = nil
        spawnTimer?.invalidate()
        spawnTimer = nil

        for item in items {
            item.window.close()
        }
        items.removeAll()

        let ranked = pets.sorted { lhs, rhs in
            scores[ObjectIdentifier(lhs), default: 0] > scores[ObjectIdentifier(rhs), default: 0]
        }

        if let winner = ranked.first {
            let winnerScore = scores[ObjectIdentifier(winner), default: 0]
            winner.transitionToState("celebrate")
            winner.showBubble("我接了 \(winnerScore) 个！")
            Task { await winner.adjustMood(by: 10) }
        }

        for pet in ranked.dropFirst() {
            let score = scores[ObjectIdentifier(pet), default: 0]
            pet.transitionToState("react")
            pet.showBubble("我拿到 \(score) 分")
        }

        pendingItems.append(MiniGameSupport.schedule(after: 2.0) { [weak self] in
            self?.onComplete?()
        })
    }
}
