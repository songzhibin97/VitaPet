import Foundation

public actor PetAnimationStateMachine {
    public private(set) var currentState: AnimationState

    public init(initialState: AnimationState = .idle) {
        self.currentState = initialState
    }

    public func handleTrigger(
        _ trigger: AnimationTrigger,
        mood: PetMood.MoodLevel = .normal
    ) -> AnimationState? {
        let nextState: AnimationState?

        switch trigger {
        case .focusEnter:
            nextState = .sleep
        case .focusExit:
            nextState = currentState == .sleep ? .celebrate : nil
        case .custom(let value):
            nextState = Self.handleCustomTrigger(value, currentState: currentState)
        case .timer:
            nextState = Self.handleTimerTrigger(for: currentState, mood: mood)
        case .appSwitch:
            nextState = currentState == .idle ? .react : nil
        case .userInteract:
            nextState = Self.handleUserInteraction(for: currentState)
        }

        guard let nextState, nextState != currentState else {
            return nil
        }

        currentState = nextState
        return nextState
    }

    public func setState(_ state: AnimationState) {
        currentState = state
    }

    public func forceState(_ state: AnimationState) {
        currentState = state
    }

    private static func handleTimerTrigger(
        for state: AnimationState,
        mood: PetMood.MoodLevel
    ) -> AnimationState? {
        switch state {
        case .idle:
            return idleTimerState(for: Int.random(in: 0..<100), mood: mood)
        case .sleep:
            return nil
        default:
            return .idle
        }
    }

    static func idleTimerState(
        for roll: Int,
        mood: PetMood.MoodLevel = .normal
    ) -> AnimationState {
        precondition((0..<100).contains(roll), "roll must be between 0 and 99")

        switch mood {
        case .happy:
            switch roll {
            case 0..<30:
                return .walk
            case 30..<55:
                return .bounce
            case 55..<70:
                return .celebrate
            case 70..<80:
                return .stretch
            case 80..<90:
                return .lookAround
            case 90..<95:
                return .yawn
            default:
                return .sleep
            }
        case .normal:
            switch roll {
            case 0..<40:
                return .walk
            case 40..<55:
                return .stretch
            case 55..<70:
                return .yawn
            case 70..<85:
                return .lookAround
            case 85..<95:
                return .bounce
            default:
                return .sleep
            }
        case .sad:
            switch roll {
            case 0..<25:
                return .sleep
            case 25..<50:
                return .yawn
            case 50..<70:
                return .lookAround
            case 70..<85:
                return .walk
            case 85..<95:
                return .stretch
            default:
                return .bounce
            }
        }
    }

    private static func handleUserInteraction(for state: AnimationState) -> AnimationState? {
        switch state {
        case .sleep:
            return .idle
        case .drag:
            return .idle
        default:
            return .react
        }
    }

    private static func handleCustomTrigger(
        _ value: String,
        currentState: AnimationState
    ) -> AnimationState? {
        let normalizedValue = value.lowercased()

        switch normalizedValue {
        case "drag", "dragstart", "drag_start":
            return .drag
        case "dragend", "drag_end":
            return currentState == .drag ? .idle : nil
        case "celebrate":
            return .celebrate
        default:
            return AnimationState.allCases.first { $0.rawValue.lowercased() == normalizedValue }
        }
    }
}
