import AppKit
import XCTest
@testable import RenderEngine

private final class Box<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

@MainActor
final class BehaviorEngineTests: XCTestCase {
    func testExecuteMoveBehavior_calculatesTargetInBounds() {
        let manifest = BehaviorManifest(
            version: "1.0.0",
            behaviors: [
                "walk": BehaviorDefinition(
                    type: .move,
                    speed: 100,
                    targetMode: "random",
                    maxDistance: 100,
                    minDistance: 100,
                    animation: nil,
                    flipToDirection: true,
                    target: nil,
                    flipToTarget: nil,
                    reactDistance: nil,
                    reactAnimation: nil,
                    activeStates: nil,
                    action: nil
                )
            ],
            idleBehaviors: [
                "normal": ["walk": 100]
            ]
        )
        let engine = BehaviorEngine(
            manifest: manifest,
            screenBounds: { NSRect(x: 0, y: 0, width: 120, height: 80) }
        )

        let capturedTarget = Box<NSPoint?>(nil)
        let moveCompleted = expectation(description: "move completed")

        engine.executeBehavior(
            "walk",
            currentPosition: NSPoint(x: 60, y: 40),
            petSize: 20,
            onMove: { point, _ in
                capturedTarget.value = point
                moveCompleted.fulfill()
            },
            onFlip: { _ in },
            onComplete: {}
        )

        wait(for: [moveCompleted], timeout: 1.5)

        guard let target = capturedTarget.value else {
            return XCTFail("Expected onMove callback")
        }

        XCTAssertGreaterThanOrEqual(target.x, 0)
        XCTAssertLessThanOrEqual(target.x, 100)
        XCTAssertGreaterThanOrEqual(target.y, 0)
        XCTAssertLessThanOrEqual(target.y, 60)
    }

    func testExecuteMoveBehavior_flipsToDirection() {
        let manifest = BehaviorManifest(
            version: "1.0.0",
            behaviors: [
                "walk": BehaviorDefinition(
                    type: .move,
                    speed: 100,
                    targetMode: "horizontal",
                    maxDistance: 20,
                    minDistance: 20,
                    animation: nil,
                    flipToDirection: true,
                    target: nil,
                    flipToTarget: nil,
                    reactDistance: nil,
                    reactAnimation: nil,
                    activeStates: nil,
                    action: nil
                )
            ],
            idleBehaviors: [
                "normal": ["walk": 100]
            ]
        )
        let engine = BehaviorEngine(
            manifest: manifest,
            screenBounds: { NSRect(x: 0, y: 0, width: 400, height: 200) }
        )

        let flippedLeft = Box(false)

        for _ in 0..<120 {
            engine.executeBehavior(
                "walk",
                currentPosition: NSPoint(x: 200, y: 100),
                petSize: 20,
                onMove: { _, _ in },
                onFlip: { isLeft in
                    if isLeft {
                        flippedLeft.value = true
                    }
                },
                onComplete: {}
            )
            if flippedLeft.value {
                break
            }
        }

        XCTAssertTrue(flippedLeft.value)
    }

    func testExecuteMoveBehavior_horizontalMode() {
        let manifest = BehaviorManifest(
            version: "1.0.0",
            behaviors: [
                "patrol": BehaviorDefinition(
                    type: .move,
                    speed: 100,
                    targetMode: "horizontal",
                    maxDistance: 15,
                    minDistance: 15,
                    animation: nil,
                    flipToDirection: nil,
                    target: nil,
                    flipToTarget: nil,
                    reactDistance: nil,
                    reactAnimation: nil,
                    activeStates: nil,
                    action: nil
                )
            ],
            idleBehaviors: [
                "normal": ["patrol": 100]
            ]
        )
        let engine = BehaviorEngine(
            manifest: manifest,
            screenBounds: { NSRect(x: 0, y: 0, width: 300, height: 200) }
        )

        let movement = expectation(description: "move callback")
        let currentY = CGFloat(88)

        engine.executeBehavior(
            "patrol",
            currentPosition: NSPoint(x: 150, y: currentY),
            petSize: 20,
            onMove: { point, _ in
                XCTAssertEqual(point.y, currentY)
                movement.fulfill()
            },
            onFlip: { _ in },
            onComplete: {}
        )

        wait(for: [movement], timeout: 1.0)
    }

    func testExecuteStaticBehavior_completesImmediately() {
        let manifest = BehaviorManifest(
            version: "1.0.0",
            behaviors: [
                "stretch": BehaviorDefinition(
                    type: .`static`,
                    speed: nil,
                    targetMode: nil,
                    maxDistance: nil,
                    minDistance: nil,
                    animation: nil,
                    flipToDirection: nil,
                    target: nil,
                    flipToTarget: nil,
                    reactDistance: nil,
                    reactAnimation: nil,
                    activeStates: nil,
                    action: nil
                )
            ],
            idleBehaviors: [:]
        )
        let engine = BehaviorEngine(
            manifest: manifest,
            screenBounds: { NSRect(x: 0, y: 0, width: 300, height: 200) }
        )

        let completed = Box(false)
        engine.executeBehavior(
            "stretch",
            currentPosition: NSPoint(x: 100, y: 100),
            petSize: 20,
            onMove: { _, _ in },
            onFlip: { _ in },
            onComplete: {
                completed.value = true
            }
        )

        XCTAssertTrue(completed.value)
    }

    func testExecuteJumpBehavior_movesWithinBounds() {
                let manifest = BehaviorManifest(
                version: "1.0.0",
                behaviors: [
                    "jump": BehaviorDefinition(
                        type: .jump,
                        speed: 120,
                        jumpHeight: 50,
                        targetMode: "horizontal",
                        maxDistance: 80,
                        minDistance: 80,
                        animation: nil,
                        flipToDirection: true,
                    target: nil,
                    flipToTarget: nil,
                        reactDistance: nil,
                        reactAnimation: nil,
                        activeStates: nil,
                        action: nil
                    )
                ],
                idleBehaviors: ["normal": ["jump": 100]]
            )
        let engine = BehaviorEngine(
            manifest: manifest,
            screenBounds: { NSRect(x: 0, y: 0, width: 300, height: 200) }
        )

        let capturedTarget = Box<NSPoint?>(nil)
        let complete = expectation(description: "jump completed")

        engine.executeBehavior(
            "jump",
            currentPosition: NSPoint(x: 150, y: 100),
            petSize: 20,
            onMove: { point, _ in
                capturedTarget.value = point
            },
            onFlip: { _ in },
            onComplete: {
                complete.fulfill()
            }
        )

        wait(for: [complete], timeout: 1.5)

        guard let target = capturedTarget.value else {
            return XCTFail("Expected onMove callback")
        }
        XCTAssertGreaterThanOrEqual(target.x, 0)
        XCTAssertLessThanOrEqual(target.x, 300 - 20)
        XCTAssertGreaterThanOrEqual(target.y, 0)
        XCTAssertLessThanOrEqual(target.y, 180)
    }

    func testExecuteChaseBehavior_updatesPositionAndCompletes() {
        let manifest = BehaviorManifest(
            version: "1.0.0",
            behaviors: [
                "chase": BehaviorDefinition(
                    type: .chase,
                    speed: 300,
                    duration: 0.5,
                    stopDistance: 20,
                    animation: nil,
                    flipToDirection: true,
                    target: nil,
                    flipToTarget: nil,
                    reactDistance: nil,
                    reactAnimation: nil,
                    activeStates: nil,
                    action: nil
                )
            ],
            idleBehaviors: ["normal": ["chase": 100]]
        )
        let engine = BehaviorEngine(
            manifest: manifest,
            screenBounds: { NSRect(x: 0, y: 0, width: 3000, height: 2000) }
        )

        let moveFired = expectation(description: "chase movement")
        moveFired.expectedFulfillmentCount = 3
        moveFired.assertForOverFulfill = false
        let completed = expectation(description: "chase completed")

        engine.executeBehavior(
            "chase",
            currentPosition: NSPoint(x: 1400, y: 1000),
            petSize: 20,
            onMove: { _, _ in
                moveFired.fulfill()
            },
            onFlip: { _ in },
            onComplete: {
                completed.fulfill()
            }
        )

        wait(for: [moveFired, completed], timeout: 2.0)
    }

    func testExecuteChaseBehavior_usesCustomTrackingTargetWhenProvided() {
        let manifest = BehaviorManifest(
            version: "1.0.0",
            behaviors: [
                "chase": BehaviorDefinition(
                    type: .chase,
                    speed: 600,
                    duration: 0.25,
                    stopDistance: 0,
                    animation: nil,
                    flipToDirection: true,
                    target: nil,
                    flipToTarget: nil,
                    reactDistance: nil,
                    reactAnimation: nil,
                    activeStates: nil,
                    action: nil
                )
            ],
            idleBehaviors: ["normal": ["chase": 100]]
        )
        let engine = BehaviorEngine(
            manifest: manifest,
            screenBounds: { NSRect(x: 0, y: 0, width: 3000, height: 2000) }
        )

        let customTarget = NSPoint(x: 1800, y: 1000)
        let moveFired = expectation(description: "chase movement to custom target")
        moveFired.assertForOverFulfill = false
        let completed = expectation(description: "chase completed with custom target")
        let observedPoints = Box<[NSPoint]>([])

        engine.executeBehavior(
            "chase",
            currentPosition: NSPoint(x: 1400, y: 1000),
            petSize: 20,
            trackingTarget: { customTarget },
            onMove: { point, _ in
                observedPoints.value.append(point)
                moveFired.fulfill()
            },
            onFlip: { _ in },
            onComplete: {
                completed.fulfill()
            }
        )

        wait(for: [moveFired, completed], timeout: 1.0)

        guard let firstPoint = observedPoints.value.first else {
            return XCTFail("Expected chase movement toward custom target")
        }

        XCTAssertGreaterThan(firstPoint.x, 1400)
        XCTAssertEqual(firstPoint.y, 1000, accuracy: 0.5)
    }

    func testExecuteHideBehavior_returnsToStart() {
        let manifest = BehaviorManifest(
            version: "1.0.0",
            behaviors: [
                "hide": BehaviorDefinition(
                    type: .hide,
                    speed: 200,
                    hideTime: 0.25,
                    peekBackSpeed: 300,
                    animation: nil,
                    flipToDirection: true,
                    activeStates: nil,
                    action: nil
                )
            ],
            idleBehaviors: ["normal": ["hide": 100]]
        )
        let engine = BehaviorEngine(
            manifest: manifest,
            screenBounds: { NSRect(x: 0, y: 0, width: 240, height: 160) }
        )

        let completed = expectation(description: "hide completed")
        let lastPoint = Box<NSPoint?>(nil)
        let minXObserved = Box<CGFloat>(.greatestFiniteMagnitude)
        let maxXObserved = Box<CGFloat>(-.greatestFiniteMagnitude)

        engine.executeBehavior(
            "hide",
            currentPosition: NSPoint(x: 120, y: 90),
            petSize: 20,
            onMove: { point, _ in
                lastPoint.value = point
                minXObserved.value = min(minXObserved.value, point.x)
                maxXObserved.value = max(maxXObserved.value, point.x)
            },
            onFlip: { _ in },
            onComplete: {
                completed.fulfill()
            }
        )

        wait(for: [completed], timeout: 2.5)

        XCTAssertNotNil(lastPoint.value)
        XCTAssertLessThanOrEqual(maxXObserved.value, 120)
        XCTAssertGreaterThanOrEqual(minXObserved.value, 0)
        XCTAssertEqual(Double(lastPoint.value!.x), 120, accuracy: 0.75)
        XCTAssertEqual(Double(lastPoint.value!.y), 90, accuracy: 0.75)
    }

    func testPickIdleBehavior_respectsWeights() {
        let manifest = BehaviorManifest(
            version: "1.0.0",
            behaviors: [:],
            idleBehaviors: [
                "normal": [
                    "idle": 20,
                    "patrol": 80
                ]
            ]
        )
        let engine = BehaviorEngine(
            manifest: manifest,
            screenBounds: { NSRect(x: 0, y: 0, width: 100, height: 100) }
        )

        var counts: [String: Int] = [:]
        let iterations = 1_000

        for _ in 0..<iterations {
            let picked = engine.pickIdleBehavior(for: "normal")
            counts[picked, default: 0] += 1
        }

        let idleRatio = Double(counts["idle", default: 0]) / Double(iterations)
        let patrolRatio = Double(counts["patrol", default: 0]) / Double(iterations)

        XCTAssertGreaterThan(idleRatio, 0.12)
        XCTAssertLessThan(idleRatio, 0.28)
        XCTAssertGreaterThan(patrolRatio, 0.72)
        XCTAssertLessThan(patrolRatio, 0.88)
    }

    func testIdleBehaviorWeights_fallbackToNormal() {
        let manifest = BehaviorManifest(
            version: "1.0.0",
            behaviors: [:],
            idleBehaviors: [
                "normal": [
                    "walk": 100
                ],
                "happy": [
                    "jump": 80,
                    "wait": 20
                ]
            ]
        )
        let engine = BehaviorEngine(
            manifest: manifest,
            screenBounds: { NSRect(x: 0, y: 0, width: 100, height: 100) }
        )

        XCTAssertEqual(
            engine.idleBehaviorWeights(for: "unknownMood"),
            manifest.idleBehaviors["normal"]
        )
    }

    func testCancelBehavior() {
        let manifest = BehaviorManifest(
            version: "1.0.0",
            behaviors: [
                "walk": BehaviorDefinition(
                    type: .move,
                    speed: 1,
                    targetMode: "horizontal",
                    maxDistance: 10,
                    minDistance: 10,
                    animation: nil,
                    flipToDirection: true,
                    target: nil,
                    flipToTarget: nil,
                    reactDistance: nil,
                    reactAnimation: nil,
                    activeStates: nil,
                    action: nil
                )
            ],
            idleBehaviors: [
                "normal": ["walk": 100]
            ]
        )
        let engine = BehaviorEngine(
            manifest: manifest,
            screenBounds: { NSRect(x: 0, y: 0, width: 400, height: 200) }
        )

        let notCompleted = expectation(description: "completion should not be called")
        notCompleted.isInverted = true

        engine.executeBehavior(
            "walk",
            currentPosition: NSPoint(x: 200, y: 100),
            petSize: 20,
            onMove: { _, _ in },
            onFlip: { _ in },
            onComplete: {
                notCompleted.fulfill()
            }
        )
        engine.cancelCurrentBehavior()

        wait(for: [notCompleted], timeout: 0.2)
    }

    func testPickIdleBehavior_includesNewBehaviors() {
        let manifest = BehaviorManifest(
            version: "1.0.0",
            behaviors: [
                "walk": BehaviorDefinition(type: .move, animation: nil),
                "jump": BehaviorDefinition(type: .jump, animation: nil),
                "chase": BehaviorDefinition(type: .chase, animation: nil),
                "hide": BehaviorDefinition(type: .hide, animation: nil)
            ],
            idleBehaviors: [
                "happy": [
                    "walk": 1,
                    "jump": 1,
                    "chase": 1
                ],
                "sad": [
                    "hide": 1
                ],
                "normal": [
                    "walk": 10
                ]
            ]
        )
        let engine = BehaviorEngine(
            manifest: manifest,
            screenBounds: { NSRect(x: 0, y: 0, width: 100, height: 100) }
        )

        var values = Set<String>()
        for _ in 0..<80 {
            values.insert(engine.pickIdleBehavior(for: "happy"))
        }

        XCTAssertTrue(values.contains("jump"))
        XCTAssertTrue(values.contains("chase"))
    }

    func testPickIdleBehavior_appliesWeightMultipliers() {
        let manifest = BehaviorManifest(
            version: "1.0.0",
            behaviors: [:],
            idleBehaviors: [
                "normal": [
                    "sleep": 100,
                    "play": 100
                ]
            ]
        )
        let engine = BehaviorEngine(
            manifest: manifest,
            screenBounds: { NSRect(x: 0, y: 0, width: 100, height: 100) }
        )

        var values = Set<String>()
        for _ in 0..<50 {
            values.insert(engine.pickIdleBehavior(for: "normal", weightMultipliers: ["play": 0]))
        }

        XCTAssertEqual(values, ["sleep"])
    }
}
