import AppKit

@MainActor
final class RockPaperScissorsGame: NSObject, MiniGame {
    let name = "猜拳"
    let minPets = 1
    let maxPets = 2

    private enum Choice: CaseIterable {
        case rock
        case scissors
        case paper

        var emoji: String {
            switch self {
            case .rock: return "✊"
            case .scissors: return "✌️"
            case .paper: return "✋"
            }
        }

        func against(_ other: Choice) -> Int {
            if self == other { return 0 }
            switch (self, other) {
            case (.rock, .scissors), (.scissors, .paper), (.paper, .rock):
                return 1
            default:
                return -1
            }
        }
    }

    private var pets: [PetWindowController] = []
    private var onComplete: (() -> Void)?
    private var choiceWindow: NSWindow?
    private var pendingItems: [DispatchWorkItem] = []

    func start(pets: [PetWindowController], onComplete: @escaping () -> Void) {
        self.pets = pets
        self.onComplete = onComplete

        if pets.count == 1 {
            presentChoiceWindow(for: pets[0])
            pets[0].showBubble("来猜拳！")
            pets[0].transitionToState("react")
            return
        }

        let first = pets[0]
        let second = pets[1]
        first.showBubble("预备，出拳！")
        second.showBubble("看我的！")
        first.transitionToState("react")
        second.transitionToState("react")

        pendingItems.append(MiniGameSupport.schedule(after: 1.0) { [weak self] in
            self?.resolveTwoPetRound()
        })
    }

    func stop() {
        pendingItems.forEach { $0.cancel() }
        pendingItems.removeAll()
        choiceWindow?.close()
        choiceWindow = nil
        onComplete = nil
        pets.removeAll()
    }

    @objc
    private func chooseRock() {
        resolveSinglePetRound(playerChoice: .rock)
    }

    @objc
    private func chooseScissors() {
        resolveSinglePetRound(playerChoice: .scissors)
    }

    @objc
    private func choosePaper() {
        resolveSinglePetRound(playerChoice: .paper)
    }

    private func presentChoiceWindow(for pet: PetWindowController) {
        let contentRect = NSRect(x: 0, y: 0, width: 180, height: 60)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .floating
        window.isReleasedWhenClosed = false

        let view = NSView(frame: contentRect)
        let background = NSVisualEffectView(frame: contentRect)
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        view.addSubview(background)

        let buttons: [(String, Selector)] = [
            ("✊", #selector(chooseRock)),
            ("✌️", #selector(chooseScissors)),
            ("✋", #selector(choosePaper))
        ]

        for (index, buttonConfig) in buttons.enumerated() {
            let button = NSButton(title: buttonConfig.0, target: self, action: buttonConfig.1)
            button.frame = NSRect(x: 12 + (56 * index), y: 12, width: 44, height: 36)
            button.isBordered = false
            button.font = .systemFont(ofSize: 24)
            view.addSubview(button)
        }

        window.contentView = view

        if let petWindow = pet.window {
            let origin = NSPoint(
                x: petWindow.frame.midX - (contentRect.width / 2),
                y: petWindow.frame.maxY + 48
            )
            window.setFrameOrigin(origin)
        }

        window.orderFrontRegardless()
        choiceWindow = window
    }

    private func resolveSinglePetRound(playerChoice: Choice) {
        guard let pet = pets.first else { return }
        choiceWindow?.close()
        choiceWindow = nil

        let petChoice = Choice.allCases.randomElement() ?? .rock
        pet.showBubble("\(petChoice.emoji) 我出这个！")
        let outcome = playerChoice.against(petChoice)

        switch outcome {
        case 1:
            pet.transitionToState("sad")
            pet.showBubble("你赢了！\(playerChoice.emoji) > \(petChoice.emoji)")
            Task { await pet.adjustMood(by: -2) }
        case -1:
            pet.transitionToState("celebrate")
            pet.showBubble("我赢啦！\(petChoice.emoji) > \(playerChoice.emoji)")
            Task { await pet.adjustMood(by: 5) }
        default:
            pet.transitionToState("react")
            pet.showBubble("平手，再来一次？")
        }

        pendingItems.append(MiniGameSupport.schedule(after: 2.0) { [weak self] in
            self?.onComplete?()
        })
    }

    private func resolveTwoPetRound() {
        guard pets.count >= 2 else { return }
        let first = pets[0]
        let second = pets[1]
        let firstChoice = Choice.allCases.randomElement() ?? .rock
        let secondChoice = Choice.allCases.randomElement() ?? .rock

        first.showBubble(firstChoice.emoji)
        second.showBubble(secondChoice.emoji)

        let outcome = firstChoice.against(secondChoice)
        switch outcome {
        case 1:
            first.transitionToState("celebrate")
            second.transitionToState("react")
            first.showBubble("我赢了！🏅")
            second.showBubble("下次一定...")
            Task {
                await first.adjustMood(by: 5)
                await second.adjustMood(by: -2)
            }
        case -1:
            second.transitionToState("celebrate")
            first.transitionToState("react")
            second.showBubble("我赢了！🏅")
            first.showBubble("下次一定...")
            Task {
                await second.adjustMood(by: 5)
                await first.adjustMood(by: -2)
            }
        default:
            first.transitionToState("react")
            second.transitionToState("react")
            first.showBubble("平手！")
            second.showBubble("再来！")
        }

        pendingItems.append(MiniGameSupport.schedule(after: 2.0) { [weak self] in
            self?.onComplete?()
        })
    }
}
