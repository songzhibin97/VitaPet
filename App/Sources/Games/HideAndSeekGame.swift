import AppKit

@MainActor
final class HideAndSeekGame: MiniGame {
    let name = "躲猫猫"
    let minPets = 2
    let maxPets = 5

    private var pets: [PetWindowController] = []
    private var onComplete: (() -> Void)?
    private var seeker: PetWindowController?
    private var hiders: [PetWindowController] = []
    private var foundIDs: Set<ObjectIdentifier> = []
    private var targetPositions: [ObjectIdentifier: NSPoint] = [:]
    private var movementTimer: Timer?
    private var timeoutTimer: Timer?
    private var pendingItems: [DispatchWorkItem] = []
    private var seekingStarted = false

    func start(pets: [PetWindowController], onComplete: @escaping () -> Void) {
        self.pets = pets
        self.onComplete = onComplete

        seeker = pets.randomElement()
        hiders = pets.filter { pet in
            guard let seeker else { return false }
            return pet !== seeker
        }

        seeker?.transitionToState("react")
        seeker?.showBubble("闭眼数数...", duration: 2.5)

        scatterHiders()

        pendingItems.append(MiniGameSupport.schedule(after: 3.0) { [weak self] in
            self?.beginSeeking()
        })

        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.finishGame(foundAll: false)
            }
        }
    }

    func stop() {
        movementTimer?.invalidate()
        movementTimer = nil
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        pendingItems.forEach { $0.cancel() }
        pendingItems.removeAll()
        targetPositions.removeAll()
        foundIDs.removeAll()
        pets.removeAll()
        hiders.removeAll()
        seeker = nil
        onComplete = nil
        seekingStarted = false
    }

    private func scatterHiders() {
        let frame = MiniGameSupport.mainScreenFrame()
        for pet in hiders {
            let randomPoint = NSPoint(
                x: CGFloat.random(in: (frame.minX + 80)...(frame.maxX - 160)),
                y: CGFloat.random(in: (frame.minY + 40)...(frame.maxY - 140))
            )
            targetPositions[ObjectIdentifier(pet)] = MiniGameSupport.clamp(origin: randomPoint, for: pet, in: frame)
            pet.transitionToState("walk")
            pet.showBubble("快藏好！", duration: 1.2)
        }

        movementTimer?.invalidate()
        movementTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickMovement()
            }
        }
    }

    private func beginSeeking() {
        seekingStarted = true
        seeker?.transitionToState("follow")
        seeker?.showBubble("我来找啦！", duration: 1.5)
    }

    private func tickMovement() {
        let frame = MiniGameSupport.mainScreenFrame()
        let speed: CGFloat = 3.5

        for pet in hiders {
            let key = ObjectIdentifier(pet)
            guard let target = targetPositions[key], let window = pet.window else { continue }
            let current = window.frame.origin
            let dx = target.x - current.x
            let dy = target.y - current.y
            let distance = hypot(dx, dy)
            guard distance > 2 else { continue }

            let step = min(speed, distance)
            let next = NSPoint(
                x: current.x + (dx / distance) * step,
                y: current.y + (dy / distance) * step
            )
            window.setFrameOrigin(MiniGameSupport.clamp(origin: next, for: pet, in: frame))
        }

        guard seekingStarted, let seeker, let seekerWindow = seeker.window else { return }

        let unfound = hiders.filter { !foundIDs.contains(ObjectIdentifier($0)) }
        if unfound.isEmpty {
            finishGame(foundAll: true)
            return
        }

        let seekerCenter = seeker.windowCenter
        let target = unfound.min { lhs, rhs in
            MiniGameSupport.distance(lhs.windowCenter, seekerCenter) < MiniGameSupport.distance(rhs.windowCenter, seekerCenter)
        }

        if let target, let targetWindow = target.window {
            let current = seekerWindow.frame.origin
            let destination = targetWindow.frame.origin
            let dx = destination.x - current.x
            let dy = destination.y - current.y
            let distance = hypot(dx, dy)
            if distance > 1 {
                let step = min(4.2, distance)
                let next = NSPoint(
                    x: current.x + (dx / distance) * step,
                    y: current.y + (dy / distance) * step
                )
                seekerWindow.setFrameOrigin(MiniGameSupport.clamp(origin: next, for: seeker, in: frame))
            }

            if MiniGameSupport.distance(target.windowCenter, seeker.windowCenter) <= 80 {
                let targetID = ObjectIdentifier(target)
                if !foundIDs.contains(targetID) {
                    foundIDs.insert(targetID)
                    target.transitionToState("react")
                    target.showBubble("被发现了！", duration: 1.2)
                    targetPositions[targetID] = seekerWindow.frame.origin
                }
            }
        }

        let foundPets = hiders.filter { foundIDs.contains(ObjectIdentifier($0)) }
        for (index, pet) in foundPets.enumerated() {
            guard let window = pet.window else { continue }
            pet.transitionToState("follow")
            let offsetTarget = NSPoint(
                x: seekerWindow.frame.origin.x - CGFloat(50 + (index * 20)),
                y: seekerWindow.frame.origin.y + CGFloat((index % 2 == 0 ? 1 : -1) * 26)
            )
            let current = window.frame.origin
            let dx = offsetTarget.x - current.x
            let dy = offsetTarget.y - current.y
            let distance = hypot(dx, dy)
            guard distance > 2 else { continue }
            let step = min(3.6, distance)
            let next = NSPoint(
                x: current.x + (dx / distance) * step,
                y: current.y + (dy / distance) * step
            )
            window.setFrameOrigin(MiniGameSupport.clamp(origin: next, for: pet, in: frame))
        }
    }

    private func finishGame(foundAll: Bool) {
        movementTimer?.invalidate()
        movementTimer = nil
        timeoutTimer?.invalidate()
        timeoutTimer = nil

        if foundAll, let seeker {
            seeker.transitionToState("celebrate")
            seeker.showBubble("全都找到啦！", duration: 2.0)
            Task { await seeker.adjustMood(by: 8) }
        } else {
            seeker?.transitionToState("react")
            seeker?.showBubble("时间到，下次继续！", duration: 2.0)
            for pet in hiders where !foundIDs.contains(ObjectIdentifier(pet)) {
                pet.transitionToState("celebrate")
                pet.showBubble("我藏得真好~", duration: 2.0)
            }
        }

        pendingItems.append(MiniGameSupport.schedule(after: 2.0) { [weak self] in
            self?.onComplete?()
        })
    }
}
