import Foundation

public struct BehaviorManifest: Codable, Sendable {
    public let version: String
    public let behaviors: [String: BehaviorDefinition]
    public let idleBehaviors: [String: [String: Int]]

    public static func defaultManifest() -> BehaviorManifest {
        let staticBehavior: (String) -> BehaviorDefinition = { animation in
            BehaviorDefinition(type: .`static`, animation: animation)
        }
        let moveBehavior: (Double, String, Double, Double, String) -> BehaviorDefinition = {
            speed,
            targetMode,
            maxDistance,
            minDistance,
            animation in
            BehaviorDefinition(
                type: .move,
                speed: speed,
                targetMode: targetMode,
                maxDistance: maxDistance,
                minDistance: minDistance,
                animation: animation,
                flipToDirection: true
            )
        }

        return BehaviorManifest(
            version: "1.0.0",
            behaviors: [
                "walk": moveBehavior(60, "random", 200, 50, "walk"),
                "patrol": moveBehavior(40, "horizontal", 300, 80, "walk"),
                "lookAtCursor": BehaviorDefinition(
                    type: .track,
                    target: "cursor",
                    flipToTarget: true,
                    reactDistance: 15,
                    reactAnimation: "react",
                    activeStates: ["idle"]
                ),
                "edgeBounce": BehaviorDefinition(
                    type: .edgeReaction,
                    animation: "react",
                    action: "flipAndContinue"
                ),
                "jump": BehaviorDefinition(
                    type: .jump,
                    speed: 80,
                    jumpHeight: 60,
                    targetMode: "random",
                    maxDistance: 150,
                    minDistance: 40,
                    animation: "bounce",
                    flipToDirection: true
                ),
                "chase": BehaviorDefinition(
                    type: .chase,
                    speed: 100,
                    duration: 3.0,
                    stopDistance: 30,
                    animation: "walk",
                    flipToDirection: true,
                    reactAnimation: "react"
                ),
                "hide": BehaviorDefinition(
                    type: .hide,
                    speed: 120,
                    hideTime: 2.0,
                    peekBackSpeed: 30,
                    animation: "react",
                    flipToDirection: true
                ),
                "stretch": staticBehavior("stretch"),
                "yawn": staticBehavior("yawn"),
                "lookAround": staticBehavior("lookAround"),
                "bounce": staticBehavior("bounce"),
                "sleep": staticBehavior("sleep"),
                "celebrate": staticBehavior("celebrate"),
                "run": moveBehavior(140, "random", 300, 80, "run"),
                "play": staticBehavior("play"),
                "roll": staticBehavior("roll"),
                "spin": staticBehavior("spin"),
                "trip": staticBehavior("trip"),
                "dance": staticBehavior("dance"),
                "climb": BehaviorDefinition(
                    type: .windowClimb,
                    speed: 40,
                    animation: "climb",
                    sitDuration: 3.0
                ),
                "sitOnWindow": BehaviorDefinition(
                    type: .windowSit,
                    speed: 60,
                    animation: "walk"
                ),
                "eat": staticBehavior("eat"),
                "drink": staticBehavior("drink"),
                "groom": staticBehavior("groom"),
                "sit": staticBehavior("sit"),
                "wave": staticBehavior("wave"),
                "nod": staticBehavior("nod"),
                "headShake": staticBehavior("headShake"),
                "sneeze": staticBehavior("sneeze"),
                "scratch": staticBehavior("scratch"),
                "sad": staticBehavior("sad"),
                "love": staticBehavior("love"),
                "angry": staticBehavior("angry"),
                "shy": staticBehavior("shy"),
                "confused": staticBehavior("confused"),
                "scared": staticBehavior("scared"),
                "peek": staticBehavior("peek"),
                "gift": staticBehavior("gift"),
                "write": staticBehavior("write"),
                "phone": staticBehavior("phone"),
                "read": staticBehavior("read"),
                "chat": staticBehavior("chat"),
                "listen": staticBehavior("listen"),
                "alert": staticBehavior("alert"),
                "think": staticBehavior("think"),
                "cheer": staticBehavior("cheer"),
                "follow": moveBehavior(120, "random", 200, 60, "follow"),
                "hidePeek": staticBehavior("hidePeek"),
                "pickup": staticBehavior("pickup"),
                "land": staticBehavior("land"),
                "type": staticBehavior("type")
            ],
            idleBehaviors: [
                "happy": [
                    "walk": 12,
                    "run": 5,
                    "play": 8,
                    "dance": 5,
                    "bounce": 6,
                    "eat": 4,
                    "groom": 3,
                    "wave": 3,
                    "love": 4,
                    "sit": 3,
                    "stretch": 3,
                    "lookAround": 4,
                    "spin": 3,
                    "gift": 2,
                    "jump": 6,
                    "chase": 5,
                    "celebrate": 2,
                    "cheer": 3,
                    "peek": 2,
                    "read": 2,
                    "phone": 2,
                    "write": 2,
                    "drink": 2,
                    "nod": 2,
                    "scratch": 2,
                    "roll": 2,
                    "climb": 3,
                    "sitOnWindow": 3
                ],
                "normal": [
                    "walk": 12,
                    "patrol": 6,
                    "sit": 8,
                    "groom": 6,
                    "eat": 4,
                    "stretch": 6,
                    "yawn": 6,
                    "lookAround": 8,
                    "drink": 3,
                    "scratch": 3,
                    "read": 4,
                    "nod": 2,
                    "wave": 2,
                    "bounce": 3,
                    "sleep": 4,
                    "jump": 3,
                    "write": 4,
                    "peek": 3,
                    "phone": 3,
                    "play": 3,
                    "roll": 2,
                    "sneeze": 1,
                    "confused": 1,
                    "shy": 1,
                    "climb": 2,
                    "sitOnWindow": 2
                ],
                "sad": [
                    "sad": 12,
                    "sleep": 12,
                    "sit": 10,
                    "yawn": 8,
                    "lookAround": 6,
                    "walk": 4,
                    "angry": 4,
                    "scared": 3,
                    "hide": 6,
                    "stretch": 4,
                    "confused": 3,
                    "drink": 3,
                    "sneeze": 2,
                    "trip": 3,
                    "scratch": 3,
                    "headShake": 3,
                    "groom": 2,
                    "eat": 2,
                    "peek": 2,
                    "climb": 1,
                    "sitOnWindow": 1
                ]
            ]
        )
    }
}

public struct BehaviorDefinition: Codable, Sendable {
    public let type: BehaviorType
    public let speed: Double?
    public let jumpHeight: Double?
    public let duration: Double?
    public let stopDistance: Double?
    public let arrivalAnimation: String?
    public let hideTime: Double?
    public let peekBackSpeed: Double?
    public let targetMode: String?
    public let maxDistance: Double?
    public let minDistance: Double?
    public let animation: String?
    public let flipToDirection: Bool?
    public let target: String?
    public let flipToTarget: Bool?
    public let reactDistance: Double?
    public let reactAnimation: String?
    public let activeStates: [String]?
    public let action: String?
    public let sitDuration: Double?

    public init(
        type: BehaviorType,
        speed: Double? = nil,
        jumpHeight: Double? = nil,
        duration: Double? = nil,
        stopDistance: Double? = nil,
        arrivalAnimation: String? = nil,
        hideTime: Double? = nil,
        peekBackSpeed: Double? = nil,
        targetMode: String? = nil,
        maxDistance: Double? = nil,
        minDistance: Double? = nil,
        animation: String? = nil,
        flipToDirection: Bool? = nil,
        target: String? = nil,
        flipToTarget: Bool? = nil,
        reactDistance: Double? = nil,
        reactAnimation: String? = nil,
        activeStates: [String]? = nil,
        action: String? = nil,
        sitDuration: Double? = nil
    ) {
        self.type = type
        self.speed = speed
        self.jumpHeight = jumpHeight
        self.duration = duration
        self.stopDistance = stopDistance
        self.arrivalAnimation = arrivalAnimation
        self.hideTime = hideTime
        self.peekBackSpeed = peekBackSpeed
        self.targetMode = targetMode
        self.maxDistance = maxDistance
        self.minDistance = minDistance
        self.animation = animation
        self.flipToDirection = flipToDirection
        self.target = target
        self.flipToTarget = flipToTarget
        self.reactDistance = reactDistance
        self.reactAnimation = reactAnimation
        self.activeStates = activeStates
        self.action = action
        self.sitDuration = sitDuration
    }
}

public enum BehaviorType: String, Codable, Sendable {
    case move
    case track
    case edgeReaction
    case `static`
    case jump
    case chase
    case hide
    case windowSit
    case windowClimb
}
