import AppKit

@MainActor
public final class BehaviorEngine {
    private let manifest: BehaviorManifest
    private let screenBounds: () -> NSRect
    private var cursorTrackingTimer: Timer?
    private var currentMovement: MovementState?
    private var cursorTrackingPetCenter: (() -> NSPoint)?
    private var cursorTrackingOnFlip: ((Bool) -> Void)?
    private var cursorTrackingOnReact: (() -> Void)?
    private var cursorTrackingContext: CursorTrackingContext?
    private var cursorTrackingReactThreshold: CGFloat = 0
    private let cursorTrackingReactInterval: TimeInterval = 60

    private enum HideDirection {
        case left
        case right
        case top
        case bottom
    }

    private final class CursorTrackingContext: @unchecked Sendable {
        var lastReactTime: Date
        var cursorWasOutsideReactZone: Bool

        init(lastReactTime: Date, cursorWasOutsideReactZone: Bool) {
            self.lastReactTime = lastReactTime
            self.cursorWasOutsideReactZone = cursorWasOutsideReactZone
        }
    }

    private final class MovementState: @unchecked Sendable {
        let id: UUID
        var timer: Timer?
        var completionWorkItem: DispatchWorkItem?
        var completion: (() -> Void)?

        init(
            id: UUID,
            completionWorkItem: DispatchWorkItem? = nil,
            completion: (() -> Void)? = nil
        ) {
            self.id = id
            self.completionWorkItem = completionWorkItem
            self.completion = completion
        }

        func cancel() {
            timer?.invalidate()
            timer = nil
            completionWorkItem?.cancel()
            completionWorkItem = nil
        }

        func finish() {
            let completion = self.completion
            self.completion = nil
            completion?()
        }
    }

    nonisolated private static let frameRate: TimeInterval = 60
    nonisolated private static let frameInterval: TimeInterval = 1.0 / frameRate
    nonisolated private static let epsilonDistance: CGFloat = 0.1

    public var onDetectWindows: (() -> [CGRect])?
    public var onRotate: ((CGFloat) -> Void)?
    public var onAnimationChange: ((String) -> Void)?

    public init(manifest: BehaviorManifest, screenBounds: @escaping () -> NSRect) {
        self.manifest = manifest
        self.screenBounds = screenBounds
    }

    public func executeBehavior(
        _ name: String,
        currentPosition: NSPoint,
        petSize: CGFloat,
        trackingTarget: (@MainActor () -> NSPoint?)? = nil,
        otherPetPositions: (() -> [NSPoint])? = nil,
        onMove: @escaping @Sendable (NSPoint, TimeInterval) -> Void,
        onFlip: @escaping @Sendable (Bool) -> Void,
        onComplete: @escaping @Sendable () -> Void,
        onLand: (@Sendable () -> Void)? = nil
    ) {
        cancelCurrentBehavior()

        guard let definition = behaviorDefinition(for: name) else {
            onComplete()
            return
        }

        switch definition.type {
        case .move:
            executeMove(
                definition: definition,
                currentPosition: currentPosition,
                petSize: petSize,
                otherPetPositions: otherPetPositions,
                onMove: onMove,
                onFlip: onFlip,
                onComplete: onComplete
            )
        case .jump:
            executeJump(
                definition: definition,
                currentPosition: currentPosition,
                petSize: petSize,
                otherPetPositions: otherPetPositions,
                onMove: onMove,
                onFlip: onFlip,
                onLand: onLand,
                onComplete: onComplete
            )
        case .chase:
            executeChase(
                definition: definition,
                currentPosition: currentPosition,
                petSize: petSize,
                trackingTarget: trackingTarget,
                onMove: onMove,
                onFlip: onFlip,
                onComplete: onComplete
            )
        case .hide:
            executeHide(
                definition: definition,
                currentPosition: currentPosition,
                petSize: petSize,
                onMove: onMove,
                onFlip: onFlip,
                onComplete: onComplete
            )
        case .windowSit:
            executeWindowSit(
                definition: definition,
                currentPosition: currentPosition,
                petSize: petSize,
                onMove: onMove,
                onFlip: onFlip,
                onComplete: onComplete
            )
        case .windowClimb:
            executeWindowClimb(
                definition: definition,
                currentPosition: currentPosition,
                petSize: petSize,
                onMove: onMove,
                onFlip: onFlip,
                onComplete: onComplete
            )
        default:
            onComplete()
        }
    }

    public func cancelCurrentBehavior() {
        guard let movement = currentMovement else {
            return
        }
        movement.cancel()
        currentMovement = nil
        onRotate?(0)
    }

    public func stopCurrentBehavior() {
        cancelCurrentBehavior()
    }

    private func executeMove(
        definition: BehaviorDefinition,
        currentPosition: NSPoint,
        petSize: CGFloat,
        otherPetPositions: (() -> [NSPoint])?,
        onMove: @escaping @Sendable (NSPoint, TimeInterval) -> Void,
        onFlip: @escaping @Sendable (Bool) -> Void,
        onComplete: @escaping @Sendable () -> Void
    ) {
        guard let targetPoint = calculatedTargetPoint(
            definition: definition,
            currentPosition: currentPosition,
            petSize: petSize
        ) else {
            onComplete()
            return
        }
        let adjustedTarget = adjustedTargetPoint(
            from: targetPoint,
            petSize: petSize,
            otherPetPositions: otherPetPositions
        )

        if let shouldFlip = definition.flipToDirection, shouldFlip {
            if adjustedTarget.x < currentPosition.x {
                onFlip(true)
            } else if adjustedTarget.x > currentPosition.x {
                onFlip(false)
            }
        }

        let distance = movementDistance(from: currentPosition, to: adjustedTarget)
        guard distance > 0 else {
            onMove(currentPosition, 0)
            onComplete()
            return
        }

        let speed = max(definition.speed ?? 1.0, 1.0)
        let duration = distance / speed

        onMove(adjustedTarget, TimeInterval(duration))

        let movementID = UUID()
        let workItem = DispatchWorkItem { [weak self] in
            if let self,
               let movement = self.currentMovement,
               movement.id == movementID {
                movement.timer = nil
                self.currentMovement = nil
                movement.finish()
            } else {
                onComplete()
            }
        }

        currentMovement = MovementState(
            id: movementID,
            completionWorkItem: workItem,
            completion: onComplete
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }

    private func executeJump(
        definition: BehaviorDefinition,
        currentPosition: NSPoint,
        petSize: CGFloat,
        otherPetPositions: (() -> [NSPoint])?,
        onMove: @escaping @Sendable (NSPoint, TimeInterval) -> Void,
        onFlip: @escaping @Sendable (Bool) -> Void,
        onLand: (@Sendable () -> Void)? = nil,
        onComplete: @escaping @Sendable () -> Void
    ) {
        guard let targetPoint = calculatedTargetPoint(
            definition: definition,
            currentPosition: currentPosition,
            petSize: petSize
        ) else {
            onComplete()
            return
        }
        let adjustedTarget = adjustedTargetPoint(
            from: targetPoint,
            petSize: petSize,
            otherPetPositions: otherPetPositions
        )

        if let shouldFlip = definition.flipToDirection, shouldFlip {
            if adjustedTarget.x < currentPosition.x {
                onFlip(true)
            } else if adjustedTarget.x > currentPosition.x {
                onFlip(false)
            }
        }

        let distance = movementDistance(from: currentPosition, to: adjustedTarget)
        let speed = max(definition.speed ?? 1.0, 1.0)
        let jumpHeight = definition.jumpHeight ?? 0

        guard distance > 0 else {
            onMove(adjustedTarget, 0)
            onLand?()
            onComplete()
            return
        }

        let duration = distance / speed
        let movementID = UUID()
        currentMovement = MovementState(id: movementID, completion: onComplete)

        let startTime = Date()
        currentMovement?.timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.frameInterval, repeats: true) { [weak self] timer in
            guard let self,
                  let movement = MainActor.assumeIsolated({ self.currentMovement }),
                  movement.id == movementID else {
                timer.invalidate()
                return
            }

            let elapsed = Date().timeIntervalSince(startTime)
            let progress = min(elapsed / duration, 1)

            let x = currentPosition.x + (adjustedTarget.x - currentPosition.x) * progress
            let arcY = Double(currentPosition.y) + Double(adjustedTarget.y - currentPosition.y) * progress +
                (jumpHeight * sin(progress * .pi))
            let point = NSPoint(x: x, y: CGFloat(arcY))
            onMove(point, 0)

            if progress >= 1 {
                timer.invalidate()
                MainActor.assumeIsolated {
                    movement.timer = nil
                    self.currentMovement = nil
                }
                onLand?()
                movement.finish()
                return
            }
        }
        currentMovement?.timer = timer
    }

    private func executeChase(
        definition: BehaviorDefinition,
        currentPosition: NSPoint,
        petSize: CGFloat,
        trackingTarget: (@MainActor () -> NSPoint?)?,
        onMove: @escaping @Sendable (NSPoint, TimeInterval) -> Void,
        onFlip: @escaping @Sendable (Bool) -> Void,
        onComplete: @escaping @Sendable () -> Void
    ) {
        let speed = max(definition.speed ?? 1.0, 1.0)
        let stopDistance = definition.stopDistance ?? 0
        let maxDuration = max(definition.duration ?? 0.0, 0.01)

        let movementID = UUID()
        currentMovement = MovementState(id: movementID, completion: onComplete)

        final class TrackingState: @unchecked Sendable { var position: NSPoint; init(_ p: NSPoint) { position = p } }
        let tracking = TrackingState(currentPosition)
        let startTime = Date()

        currentMovement?.timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.frameInterval, repeats: true) { [weak self] timer in
            guard let self,
                  let movement = MainActor.assumeIsolated({ self.currentMovement }),
                  movement.id == movementID else {
                timer.invalidate()
                return
            }

            if Date().timeIntervalSince(startTime) >= maxDuration {
                timer.invalidate()
                MainActor.assumeIsolated {
                    movement.timer = nil
                    self.currentMovement = nil
                }
                movement.finish()
                return
            }

            let targetPosition: NSPoint
            if let trackingTarget,
               let customTarget = MainActor.assumeIsolated({ trackingTarget() }) {
                targetPosition = customTarget
            } else {
                targetPosition = NSEvent.mouseLocation
            }

            let deltaX = targetPosition.x - tracking.position.x
            let deltaY = targetPosition.y - tracking.position.y
            let distanceToCursor = sqrt((deltaX * deltaX) + (deltaY * deltaY))

            if stopDistance > 0 && distanceToCursor <= stopDistance {
                timer.invalidate()
                MainActor.assumeIsolated {
                    movement.timer = nil
                    self.currentMovement = nil
                }
                movement.finish()
                return
            }

            if let shouldFlip = definition.flipToDirection, shouldFlip {
                if deltaX < 0 {
                    onFlip(true)
                } else if deltaX > 0 {
                    onFlip(false)
                }
            }

            guard distanceToCursor > 0 else {
                return
            }

            let stepDistance = CGFloat(speed * Self.frameInterval)
            if stepDistance <= 0 {
                timer.invalidate()
                MainActor.assumeIsolated {
                    movement.timer = nil
                    self.currentMovement = nil
                }
                movement.finish()
                return
            }

            let ratio = min(stepDistance / distanceToCursor, 1)
            let rawX = tracking.position.x + (deltaX * ratio)
            let rawY = tracking.position.y + (deltaY * ratio)
            let nextPoint = MainActor.assumeIsolated {
                self.clampPoint(NSPoint(x: rawX, y: rawY), for: petSize)
            }

            guard abs(nextPoint.x - tracking.position.x) > Self.epsilonDistance ||
                  abs(nextPoint.y - tracking.position.y) > Self.epsilonDistance else {
                return
            }

            tracking.position = nextPoint
            onMove(nextPoint, 0)
        }

        currentMovement?.timer = timer
    }

    private func executeHide(
        definition: BehaviorDefinition,
        currentPosition: NSPoint,
        petSize: CGFloat,
        onMove: @escaping @Sendable (NSPoint, TimeInterval) -> Void,
        onFlip: @escaping @Sendable (Bool) -> Void,
        onComplete: @escaping @Sendable () -> Void
    ) {
        let moveOutSpeed = max(definition.speed ?? 1.0, 1.0)
        let peekBackSpeed = max(definition.peekBackSpeed ?? 1.0, 1.0)
        let hideTime = max(definition.hideTime ?? 0.0, 0.0)

        guard let hiddenPoint = hiddenPoint(from: currentPosition, for: petSize, in: screenBounds()) else {
            onComplete()
            return
        }

        if let shouldFlip = definition.flipToDirection, shouldFlip {
            if hiddenPoint.x < currentPosition.x {
                onFlip(true)
            } else if hiddenPoint.x > currentPosition.x {
                onFlip(false)
            }
        }

        let movementID = UUID()
        currentMovement = MovementState(id: movementID, completion: onComplete)

        runLinearMovement(
            movementID: movementID,
            from: currentPosition,
            to: hiddenPoint,
            speed: moveOutSpeed,
            autoComplete: false,
            onMove: { point in
                onMove(point, 0)
            },
            onComplete: { [weak self] in
                let beginPeekBack: @Sendable () -> Void = { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else {
                            return
                        }

                        self.runLinearMovement(
                            movementID: movementID,
                            from: hiddenPoint,
                            to: currentPosition,
                            speed: peekBackSpeed,
                            onMove: { point in
                                onMove(point, 0)
                            },
                            onComplete: {
                                MainActor.assumeIsolated {
                                    guard let movement = self.currentMovement,
                                          movement.id == movementID else {
                                        return
                                    }
                                    self.currentMovement = nil
                                    movement.finish()
                                }
                            }
                        )
                    }
                }

                MainActor.assumeIsolated {
                    guard let self,
                          let movement = self.currentMovement,
                          movement.id == movementID else {
                        return
                    }

                    guard hideTime > 0 else {
                        beginPeekBack()
                        return
                    }

                    self.currentMovement?.timer?.invalidate()
                    self.currentMovement?.timer = Timer.scheduledTimer(
                        withTimeInterval: hideTime,
                        repeats: false
                    ) { timer in
                        timer.invalidate()
                        beginPeekBack()
                    }
                }
            }
        )
    }

    private func executeWindowSit(
        definition: BehaviorDefinition,
        currentPosition: NSPoint,
        petSize: CGFloat,
        onMove: @escaping @Sendable (NSPoint, TimeInterval) -> Void,
        onFlip: @escaping @Sendable (Bool) -> Void,
        onComplete: @escaping @Sendable () -> Void
    ) {
        guard let windowFrame = nearestWindow(to: currentPosition, petSize: petSize) else {
            executeFallbackMove(
                currentPosition: currentPosition,
                petSize: petSize,
                onMove: onMove,
                onFlip: onFlip,
                onComplete: onComplete
            )
            return
        }

        let movementID = UUID()
        let speed = max(definition.speed ?? 60, 1.0)
        let sitPoint = clampPoint(
            NSPoint(x: windowFrame.midX - (petSize / 2), y: windowFrame.maxY),
            for: petSize
        )

        if let shouldFlip = definition.flipToDirection, shouldFlip {
            if sitPoint.x < currentPosition.x {
                onFlip(true)
            } else if sitPoint.x > currentPosition.x {
                onFlip(false)
            }
        }

        onAnimationChange?(definition.animation ?? "walk")
        currentMovement = MovementState(id: movementID, completion: onComplete)

        let moveDuration = movementDuration(from: currentPosition, to: sitPoint, speed: speed)
        onMove(sitPoint, moveDuration)

        scheduleMovementStep(movementID: movementID, delay: moveDuration) { [weak self] movement in
            guard let self else {
                return
            }

            self.onAnimationChange?("sit")

            let sitDuration = max(definition.sitDuration ?? Double.random(in: 3...8), 0)
            self.scheduleMovementStep(movementID: movementID, delay: sitDuration) { [weak self] movement in
                guard let self else {
                    return
                }

                let groundPoint = self.clampPoint(
                    NSPoint(x: sitPoint.x, y: self.screenBounds().minY),
                    for: petSize
                )

                self.onAnimationChange?("jump")
                let landDuration = self.movementDuration(from: sitPoint, to: groundPoint, speed: speed)
                onMove(groundPoint, landDuration)

                self.scheduleMovementStep(movementID: movementID, delay: landDuration) { [weak self] movement in
                    guard let self else {
                        return
                    }

                    self.onRotate?(0)
                    self.onAnimationChange?("idle")
                    self.currentMovement = nil
                    movement.finish()
                }
            }
        }
    }

    private func executeWindowClimb(
        definition: BehaviorDefinition,
        currentPosition: NSPoint,
        petSize: CGFloat,
        onMove: @escaping @Sendable (NSPoint, TimeInterval) -> Void,
        onFlip: @escaping @Sendable (Bool) -> Void,
        onComplete: @escaping @Sendable () -> Void
    ) {
        guard let windowFrame = nearestWindow(to: currentPosition, petSize: petSize) else {
            executeFallbackMove(
                currentPosition: currentPosition,
                petSize: petSize,
                onMove: onMove,
                onFlip: onFlip,
                onComplete: onComplete
            )
            return
        }

        let movementID = UUID()
        let speed = max(definition.speed ?? 40, 1.0)
        let useLeftEdge = Bool.random()
        let edgeCenterX = useLeftEdge ? windowFrame.minX : windowFrame.maxX
        let edgeOriginX = edgeCenterX - (petSize / 2)
        let basePoint = clampPoint(NSPoint(x: edgeOriginX, y: windowFrame.minY), for: petSize)
        let climbTopPoint = clampPoint(NSPoint(x: edgeOriginX, y: windowFrame.maxY), for: petSize)

        if let shouldFlip = definition.flipToDirection, shouldFlip {
            if basePoint.x < currentPosition.x {
                onFlip(true)
            } else if basePoint.x > currentPosition.x {
                onFlip(false)
            }
        }

        onAnimationChange?(definition.animation ?? "walk")
        currentMovement = MovementState(id: movementID, completion: onComplete)

        let walkDuration = movementDuration(from: currentPosition, to: basePoint, speed: speed)
        onMove(basePoint, walkDuration)

        scheduleMovementStep(movementID: movementID, delay: walkDuration) { [weak self] _ in
            guard let self,
                  let movement = self.currentMovement,
                  movement.id == movementID else {
                return
            }

            self.onRotate?(useLeftEdge ? (.pi / 2) : (-.pi / 2))
            self.onAnimationChange?("climb")

            self.runLinearMovement(
                movementID: movementID,
                from: basePoint,
                to: climbTopPoint,
                speed: speed,
                autoComplete: false,
                onMove: { point in
                    onMove(point, 0)
                },
                onComplete: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self,
                              let movement = self.currentMovement,
                              movement.id == movementID else {
                            return
                        }

                        self.onRotate?(0)
                        self.onAnimationChange?("sit")

                        let sitDuration = max(definition.sitDuration ?? 3.0, 0)
                        self.scheduleMovementStep(movementID: movementID, delay: sitDuration) { movement in
                            let groundPoint = self.clampPoint(
                                NSPoint(x: climbTopPoint.x, y: self.screenBounds().minY),
                                for: petSize
                            )

                            self.onAnimationChange?("jump")
                            let landDuration = self.movementDuration(from: climbTopPoint, to: groundPoint, speed: speed)
                            onMove(groundPoint, landDuration)

                            self.scheduleMovementStep(movementID: movementID, delay: landDuration) { movement in
                                self.onRotate?(0)
                                self.onAnimationChange?("idle")
                                self.currentMovement = nil
                                movement.finish()
                            }
                        }
                    }
                }
            )
        }
    }

    private func runLinearMovement(
        movementID: UUID,
        from startPoint: NSPoint,
        to targetPoint: NSPoint,
        speed: Double,
        autoComplete: Bool = true,
        onMove: @escaping @Sendable (NSPoint) -> Void,
        onComplete: @escaping @Sendable () -> Void
    ) {
        guard let movement = currentMovement, movement.id == movementID else {
            onComplete()
            return
        }

        let distance = movementDistance(from: startPoint, to: targetPoint)
        guard distance > 0 else {
            onMove(targetPoint)
            if autoComplete {
                movement.timer = nil
                self.currentMovement = nil
                movement.finish()
            } else {
                onComplete()
            }
            return
        }

        let duration = distance / CGFloat(speed)
        if duration <= 0 {
            onMove(targetPoint)
            if autoComplete {
                movement.timer = nil
                self.currentMovement = nil
                movement.finish()
            } else {
                onComplete()
            }
            return
        }

        let startTime = Date()
        movement.timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.frameInterval, repeats: true) { [weak self] timer in
            guard let self,
                  let activeMovement = MainActor.assumeIsolated({ self.currentMovement }),
                  activeMovement.id == movementID else {
                timer.invalidate()
                return
            }

            let elapsed = Date().timeIntervalSince(startTime)
            let progress = min(elapsed / Double(duration), 1)

            let x = startPoint.x + (targetPoint.x - startPoint.x) * CGFloat(progress)
            let y = startPoint.y + (targetPoint.y - startPoint.y) * CGFloat(progress)
            onMove(NSPoint(x: x, y: y))

            if progress >= 1 {
                timer.invalidate()
                if autoComplete {
                    MainActor.assumeIsolated {
                        activeMovement.timer = nil
                        self.currentMovement = nil
                    }
                    activeMovement.finish()
                } else {
                    onComplete()
                }
            }
        }
        movement.timer = timer
    }

    private func calculatedTargetPoint(
        definition: BehaviorDefinition,
        currentPosition: NSPoint,
        petSize: CGFloat
    ) -> NSPoint? {
        guard let minDistance = definition.minDistance,
              let maxDistance = definition.maxDistance else {
            return nil
        }

        let distance = Double.random(in: min(minDistance, maxDistance)...max(minDistance, maxDistance))
        let xDirection = Bool.random() ? 1.0 : -1.0
        let yDirection = Bool.random() ? 1.0 : -1.0

        var targetPoint = currentPosition

        switch definition.targetMode {
        case "horizontal":
            targetPoint.x += xDirection * distance
        case "vertical":
            targetPoint.y += yDirection * distance
        default:
            targetPoint.x += xDirection * distance
            targetPoint.y += yDirection * distance
        }

        return clampPoint(targetPoint, for: petSize)
    }

    private func hiddenPoint(from currentPosition: NSPoint, for petSize: CGFloat, in bounds: NSRect) -> NSPoint? {
        guard let direction = nearestHideDirection(from: currentPosition, in: bounds, for: petSize) else {
            return nil
        }

        let halfHiddenSize = petSize / 2
        let maxX = bounds.maxX
        let minX = bounds.minX
        let maxY = bounds.maxY
        let minY = bounds.minY

        switch direction {
        case .left:
            return NSPoint(x: minX - halfHiddenSize, y: currentPosition.y)
        case .right:
            return NSPoint(x: maxX - halfHiddenSize, y: currentPosition.y)
        case .bottom:
            return NSPoint(x: currentPosition.x, y: minY - halfHiddenSize)
        case .top:
            return NSPoint(x: currentPosition.x, y: maxY - halfHiddenSize)
        }
    }

    private func nearestHideDirection(from position: NSPoint, in bounds: NSRect, for petSize: CGFloat) -> HideDirection? {
        let left = max(0, position.x - bounds.minX)
        let right = max(0, bounds.maxX - petSize - position.x)
        let bottom = max(0, position.y - bounds.minY)
        let top = max(0, bounds.maxY - petSize - position.y)

        let nearest = min(min(left, right), min(bottom, top))

        if nearest == left {
            return .left
        }
        if nearest == right {
            return .right
        }
        if nearest == bottom {
            return .bottom
        }
        if nearest == top {
            return .top
        }

        return .left
    }

    private func movementDistance(from start: NSPoint, to end: NSPoint) -> CGFloat {
        let traveledX = end.x - start.x
        let traveledY = end.y - start.y
        return sqrt((traveledX * traveledX) + (traveledY * traveledY))
    }

    private func movementDuration(from start: NSPoint, to end: NSPoint, speed: Double) -> TimeInterval {
        let distance = movementDistance(from: start, to: end)
        guard distance > 0 else {
            return 0
        }
        return TimeInterval(distance / CGFloat(max(speed, 1.0)))
    }

    private func clampedRange(petSize: CGFloat) -> (minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat) {
        let bounds = screenBounds()
        let minX = bounds.minX
        let maxX = max(bounds.minX, bounds.maxX - petSize)
        let minY = bounds.minY
        let maxY = max(bounds.minY, bounds.maxY - petSize)
        return (minX, maxX, minY, maxY)
    }

    private func clampPoint(_ point: NSPoint, for petSize: CGFloat) -> NSPoint {
        let (minX, maxX, minY, maxY) = clampedRange(petSize: petSize)
        return NSPoint(
            x: min(max(point.x, minX), maxX),
            y: min(max(point.y, minY), maxY)
        )
    }

    private func adjustedTargetPoint(
        from targetPoint: NSPoint,
        petSize: CGFloat,
        otherPetPositions: (() -> [NSPoint])?
    ) -> NSPoint {
        guard let otherPetPositions else {
            return targetPoint
        }
        let adjustedPoint = avoidOverlap(
            target: targetPoint,
            petSize: petSize,
            otherPositions: otherPetPositions()
        )
        return clampPoint(adjustedPoint, for: petSize)
    }

    private func avoidOverlap(
        target: NSPoint,
        petSize: CGFloat,
        otherPositions: [NSPoint]
    ) -> NSPoint {
        var adjusted = target
        for otherPos in otherPositions {
            let dx = adjusted.x - otherPos.x
            let dy = adjusted.y - otherPos.y
            let distance = sqrt(dx * dx + dy * dy)
            let minDistance = petSize * 1.2

            if distance < minDistance && distance > 0 {
                let pushX = dx / distance * minDistance
                let pushY = dy / distance * minDistance
                adjusted = NSPoint(x: otherPos.x + pushX, y: otherPos.y + pushY)
            } else if distance == 0 {
                adjusted = NSPoint(
                    x: adjusted.x + CGFloat.random(in: -petSize...petSize),
                    y: adjusted.y + CGFloat.random(in: -petSize...petSize)
                )
            }
        }
        return adjusted
    }

    private func executeFallbackMove(
        currentPosition: NSPoint,
        petSize: CGFloat,
        onMove: @escaping @Sendable (NSPoint, TimeInterval) -> Void,
        onFlip: @escaping @Sendable (Bool) -> Void,
        onComplete: @escaping @Sendable () -> Void
    ) {
        guard let fallback = behaviorDefinition(for: "walk") else {
            onComplete()
            return
        }

        executeMove(
            definition: fallback,
            currentPosition: currentPosition,
            petSize: petSize,
            otherPetPositions: nil,
            onMove: onMove,
            onFlip: onFlip,
            onComplete: onComplete
        )
    }

    private func nearestWindow(to currentPosition: NSPoint, petSize: CGFloat) -> CGRect? {
        guard let windows = onDetectWindows?(), !windows.isEmpty else {
            return nil
        }

        let petCenter = CGPoint(x: currentPosition.x + (petSize / 2), y: currentPosition.y + (petSize / 2))
        return windows.min { lhs, rhs in
            distance(from: petCenter, to: lhs) < distance(from: petCenter, to: rhs)
        }
    }

    private func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let clampedX = min(max(point.x, rect.minX), rect.maxX)
        let clampedY = min(max(point.y, rect.minY), rect.maxY)
        let dx = point.x - clampedX
        let dy = point.y - clampedY
        return sqrt((dx * dx) + (dy * dy))
    }

    private func scheduleMovementStep(
        movementID: UUID,
        delay: TimeInterval,
        action: @escaping (MovementState) -> Void
    ) {
        guard let movement = currentMovement, movement.id == movementID else {
            return
        }

        movement.completionWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  let activeMovement = self.currentMovement,
                  activeMovement.id == movementID else {
                return
            }

            activeMovement.completionWorkItem = nil
            action(activeMovement)
        }
        movement.completionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0), execute: workItem)
    }

    public func startCursorTracking(
        petCenter: @escaping @Sendable () -> NSPoint,
        onFlip: @escaping @Sendable (Bool) -> Void,
        onReact: @escaping @Sendable () -> Void
    ) {
        stopCursorTracking()

        let reactDistance = behaviorDefinition(for: "lookAtCursor")?.reactDistance ?? 0
        cursorTrackingPetCenter = petCenter
        cursorTrackingOnFlip = onFlip
        cursorTrackingOnReact = onReact
        cursorTrackingReactThreshold = CGFloat(reactDistance)
        cursorTrackingContext = CursorTrackingContext(
            lastReactTime: .distantPast,
            cursorWasOutsideReactZone: true
        )

        cursorTrackingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.performCursorTracking()
            }
        }
        RunLoop.main.add(cursorTrackingTimer!, forMode: .common)
    }

    public func stopCursorTracking() {
        cursorTrackingTimer?.invalidate()
        cursorTrackingTimer = nil
        cursorTrackingPetCenter = nil
        cursorTrackingOnFlip = nil
        cursorTrackingOnReact = nil
        cursorTrackingContext = nil
        cursorTrackingReactThreshold = 0
    }

    private func performCursorTracking() {
        guard let centerProvider = cursorTrackingPetCenter,
              let flipHandler = cursorTrackingOnFlip else {
            return
        }

        let cursor = NSEvent.mouseLocation
        let center = centerProvider()

        if cursor.x < center.x {
            flipHandler(true)
        } else if cursor.x > center.x {
            flipHandler(false)
        }

        guard cursorTrackingReactThreshold > 0,
              let reactHandler = cursorTrackingOnReact,
              let context = cursorTrackingContext else {
            return
        }

        let deltaX = cursor.x - center.x
        let deltaY = cursor.y - center.y
        let distance = sqrt((deltaX * deltaX) + (deltaY * deltaY))

        guard distance < cursorTrackingReactThreshold else {
            context.cursorWasOutsideReactZone = true
            return
        }

        let now = Date()
        guard context.cursorWasOutsideReactZone,
              now.timeIntervalSince(context.lastReactTime) >= cursorTrackingReactInterval else {
            return
        }

        context.cursorWasOutsideReactZone = false
        context.lastReactTime = now
        reactHandler()
    }

    public func idleBehaviorWeights(for mood: String) -> [String: Int] {
        manifest.idleBehaviors[mood] ?? manifest.idleBehaviors["normal"] ?? [:]
    }

    public func pickIdleBehavior(for mood: String) -> String {
        let weights = idleBehaviorWeights(for: mood)
        let totalWeight = weights.values.reduce(0, +)
        guard totalWeight > 0 else {
            return ""
        }
        let pick = Int.random(in: 0..<totalWeight)
        var cumulative = 0

        for (name, weight) in weights {
            cumulative += weight
            if pick < cumulative {
                return name
            }
        }

        return weights.keys.first ?? ""
    }

    public func pickIdleBehavior(for mood: String, weightMultipliers: [String: Double]) -> String {
        var weights = idleBehaviorWeights(for: mood)

        for (behavior, multiplier) in weightMultipliers {
            if let weight = weights[behavior] {
                weights[behavior] = max(0, Int(Double(weight) * multiplier))
            }
        }

        let totalWeight = weights.values.reduce(0, +)
        guard totalWeight > 0 else {
            return ""
        }

        let pick = Int.random(in: 0..<totalWeight)
        var cumulative = 0

        for (name, weight) in weights {
            cumulative += weight
            if pick < cumulative {
                return name
            }
        }

        return weights.keys.first ?? ""
    }

    public func behaviorDefinition(for name: String) -> BehaviorDefinition? {
        manifest.behaviors[name]
    }

    public func allBehaviorNames() -> [String] {
        Array(manifest.behaviors.keys)
    }
}
