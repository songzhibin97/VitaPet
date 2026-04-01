import AppKit
import RenderEngine

@MainActor
final class RaceGame: MiniGame {
    let name = "赛跑"
    let minPets = 2
    let maxPets = 5

    private var pets: [PetWindowController] = []
    private var onComplete: (() -> Void)?
    private var raceTimer: Timer?
    private var eventTimer: Timer?
    private var pendingItems: [DispatchWorkItem] = []
    private var speeds: [ObjectIdentifier: CGFloat] = [:]
    private var slowUntil: [ObjectIdentifier: Date] = [:]
    private var pauseUntil: [ObjectIdentifier: Date] = [:]
    private var finished: [PetWindowController] = []
    private var finishLine: CGFloat = 0

    func start(pets: [PetWindowController], onComplete: @escaping () -> Void) {
        self.pets = pets
        self.onComplete = onComplete

        let screen = MiniGameSupport.mainScreenFrame()
        let spacing: CGFloat = 90
        let totalHeight = CGFloat(max(0, pets.count - 1)) * spacing
        let startY = screen.midY + (totalHeight / 2)

        for (index, pet) in pets.enumerated() {
            let target = NSPoint(
                x: screen.minX + 40,
                y: startY - (CGFloat(index) * spacing)
            )
            let clamped = MiniGameSupport.clamp(origin: target, for: pet, in: screen)
            pet.window?.setFrameOrigin(clamped)
            pet.transitionToState("idle")
            speeds[ObjectIdentifier(pet)] = CGFloat.random(in: 4.5...6.5)
        }

        finishLine = screen.maxX - 80
        startCountdown()
    }

    func stop() {
        raceTimer?.invalidate()
        raceTimer = nil
        eventTimer?.invalidate()
        eventTimer = nil
        pendingItems.forEach { $0.cancel() }
        pendingItems.removeAll()
        speeds.removeAll()
        slowUntil.removeAll()
        pauseUntil.removeAll()
        finished.removeAll()
        onComplete = nil
        pets.removeAll()
    }

    private func startCountdown() {
        let countdown = ["3", "2", "1", "跑！"]
        for (offset, text) in countdown.enumerated() {
            pendingItems.append(MiniGameSupport.schedule(after: Double(offset)) { [weak self] in
                guard let self else { return }
                for pet in self.pets {
                    pet.showBubble(text, duration: 0.8)
                    if text == "跑！" {
                        pet.setFacing(.right)
                        pet.transitionToState("run")
                    } else {
                        pet.transitionToState("react")
                    }
                }
            })
        }

        pendingItems.append(MiniGameSupport.schedule(after: 3.1) { [weak self] in
            self?.beginRaceLoop()
        })
    }

    private func beginRaceLoop() {
        raceTimer?.invalidate()
        raceTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickRace()
            }
        }

        scheduleRandomEventTimer()
    }

    private func scheduleRandomEventTimer() {
        eventTimer?.invalidate()
        eventTimer = Timer.scheduledTimer(withTimeInterval: Double.random(in: 2.0...3.0), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.triggerRandomEvent()
                self?.scheduleRandomEventTimer()
            }
        }
    }

    private func tickRace() {
        guard !pets.isEmpty else { return }
        let now = Date()

        for pet in pets where !finished.contains(where: { $0 === pet }) {
            guard let window = pet.window else { continue }
            let key = ObjectIdentifier(pet)
            if let pause = pauseUntil[key], pause > now {
                continue
            }

            var speed = speeds[key] ?? 5
            if let slow = slowUntil[key], slow > now {
                speed *= 0.55
            }

            let jitter = CGFloat.random(in: -0.8...0.8)
            let newOrigin = NSPoint(x: window.frame.origin.x + max(1.5, speed + jitter), y: window.frame.origin.y)
            window.setFrameOrigin(newOrigin)

            if window.frame.maxX >= finishLine {
                finished.append(pet)
                pet.transitionToState("celebrate")
                pet.showBubble("第\(finished.count)名！")
            }
        }

        if finished.count == pets.count {
            completeRace()
        }
    }

    private func triggerRandomEvent() {
        let remaining = pets.filter { pet in
            !finished.contains(where: { $0 === pet })
        }
        guard let pet = remaining.randomElement() else { return }
        let key = ObjectIdentifier(pet)

        switch Int.random(in: 0...2) {
        case 0:
            pauseUntil[key] = Date().addingTimeInterval(0.5)
            pet.transitionToState("react")
            pet.showBubble("哎呀，绊了一下！")
            pendingItems.append(MiniGameSupport.schedule(after: 0.55) { [weak pet] in
                pet?.setFacing(.right)
                pet?.transitionToState("run")
            })
        case 1:
            speeds[key] = (speeds[key] ?? 5) + CGFloat.random(in: 1.5...2.5)
            pet.transitionToState("bounce")
            pet.showBubble("冲刺！")
            pendingItems.append(MiniGameSupport.schedule(after: 0.4) { [weak pet] in
                pet?.setFacing(.right)
                pet?.transitionToState("run")
            })
        default:
            slowUntil[key] = Date().addingTimeInterval(1.2)
            pet.transitionToState("yawn")
            pet.showBubble("哈欠...慢一点")
            pendingItems.append(MiniGameSupport.schedule(after: 0.7) { [weak pet] in
                pet?.setFacing(.right)
                pet?.transitionToState("run")
            })
        }
    }

    private func completeRace() {
        raceTimer?.invalidate()
        raceTimer = nil
        eventTimer?.invalidate()
        eventTimer = nil

        guard let winner = finished.first else {
            onComplete?()
            return
        }

        winner.transitionToState("celebrate")
        winner.showBubble("我赢了！🏆", duration: 2.0)
        Task { await winner.adjustMood(by: 10) }

        for (index, pet) in finished.enumerated().dropFirst() {
            let delta: Int
            switch index {
            case 1: delta = 5
            case 2: delta = 2
            default: delta = 0
            }
            pet.transitionToState("react")
            pet.showBubble("第\(index + 1)名")
            if delta != 0 {
                Task { await pet.adjustMood(by: delta) }
            }
        }

        pendingItems.append(MiniGameSupport.schedule(after: 2.0) { [weak self] in
            self?.onComplete?()
        })
    }
}
