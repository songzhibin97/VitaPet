import XCTest
@testable import RenderEngine

final class PetAnimationStateMachineTests: XCTestCase {
    private let newAutonomousStates: [AnimationState] = [.stretch, .yawn, .lookAround, .bounce]

    func testFocusEnterTransitionsIdleToSleep() async {
        let machine = PetAnimationStateMachine(initialState: .idle)

        let nextState = await machine.handleTrigger(.focusEnter)

        XCTAssertEqual(nextState, .sleep)
        let currentState = await machine.currentState
        XCTAssertEqual(currentState, .sleep)
    }

    func testFocusEnterTransitionsWalkToSleep() async {
        let machine = PetAnimationStateMachine(initialState: .walk)

        let nextState = await machine.handleTrigger(.focusEnter)

        XCTAssertEqual(nextState, .sleep)
        let currentState = await machine.currentState
        XCTAssertEqual(currentState, .sleep)
    }

    func testFocusEnterReturnsNilWhenAlreadySleep() async {
        let machine = PetAnimationStateMachine(initialState: .sleep)

        let nextState = await machine.handleTrigger(.focusEnter)

        XCTAssertNil(nextState)
        let currentState = await machine.currentState
        XCTAssertEqual(currentState, .sleep)
    }

    func testFocusExitTransitionsSleepToCelebrate() async {
        let machine = PetAnimationStateMachine(initialState: .sleep)

        let nextState = await machine.handleTrigger(.focusExit)

        XCTAssertEqual(nextState, .celebrate)
        let currentState = await machine.currentState
        XCTAssertEqual(currentState, .celebrate)
    }

    func testFocusExitReturnsNilFromIdle() async {
        let machine = PetAnimationStateMachine(initialState: .idle)

        let nextState = await machine.handleTrigger(.focusExit)

        XCTAssertNil(nextState)
        let currentState = await machine.currentState
        XCTAssertEqual(currentState, .idle)
    }

    func testCustomDragStartTransitionsIdleToDrag() async {
        let machine = PetAnimationStateMachine(initialState: .idle)

        let nextState = await machine.handleTrigger(.custom("drag_start"))

        XCTAssertEqual(nextState, .drag)
        let currentState = await machine.currentState
        XCTAssertEqual(currentState, .drag)
    }

    func testCustomDragstartTransitionsIdleToDrag() async {
        let machine = PetAnimationStateMachine(initialState: .idle)

        let nextState = await machine.handleTrigger(.custom("dragstart"))

        XCTAssertEqual(nextState, .drag)
        let currentState = await machine.currentState
        XCTAssertEqual(currentState, .drag)
    }

    func testCustomDragTransitionsIdleToDrag() async {
        let machine = PetAnimationStateMachine(initialState: .idle)

        let nextState = await machine.handleTrigger(.custom("drag"))

        XCTAssertEqual(nextState, .drag)
        let currentState = await machine.currentState
        XCTAssertEqual(currentState, .drag)
    }

    func testCustomDragEndTransitionsDragToIdle() async {
        let machine = PetAnimationStateMachine(initialState: .drag)

        let nextState = await machine.handleTrigger(.custom("drag_end"))

        XCTAssertEqual(nextState, .idle)
        let currentState = await machine.currentState
        XCTAssertEqual(currentState, .idle)
    }

    func testCustomDragendTransitionsDragToIdle() async {
        let machine = PetAnimationStateMachine(initialState: .drag)

        let nextState = await machine.handleTrigger(.custom("dragend"))

        XCTAssertEqual(nextState, .idle)
        let currentState = await machine.currentState
        XCTAssertEqual(currentState, .idle)
    }

    func testCustomDragEndReturnsNilFromIdle() async {
        let machine = PetAnimationStateMachine(initialState: .idle)

        let nextState = await machine.handleTrigger(.custom("drag_end"))

        XCTAssertNil(nextState)
        let currentState = await machine.currentState
        XCTAssertEqual(currentState, .idle)
    }

    func testCustomCelebrateTransitionsToCelebrate() async {
        let machine = PetAnimationStateMachine(initialState: .idle)

        let nextState = await machine.handleTrigger(.custom("celebrate"))

        XCTAssertEqual(nextState, .celebrate)
        let currentState = await machine.currentState
        XCTAssertEqual(currentState, .celebrate)
    }

    func testCustomUnknownReturnsNil() async {
        let machine = PetAnimationStateMachine(initialState: .idle)

        let nextState = await machine.handleTrigger(.custom("unknown"))

        XCTAssertNil(nextState)
        let currentState = await machine.currentState
        XCTAssertEqual(currentState, .idle)
    }

    func testTimerTransitionsWalkToIdle() async {
        let machine = PetAnimationStateMachine(initialState: .walk)

        let nextState = await machine.handleTrigger(.timer)

        XCTAssertEqual(nextState, .idle)
        let currentState = await machine.currentState
        XCTAssertEqual(currentState, .idle)
    }

    func testTimerTransitionsReactToIdle() async {
        let machine = PetAnimationStateMachine(initialState: .react)

        let nextState = await machine.handleTrigger(.timer)

        XCTAssertEqual(nextState, .idle)
        let currentState = await machine.currentState
        XCTAssertEqual(currentState, .idle)
    }

    func testTimerTransitionsCelebrateToIdle() async {
        let machine = PetAnimationStateMachine(initialState: .celebrate)

        let nextState = await machine.handleTrigger(.timer)

        XCTAssertEqual(nextState, .idle)
        let currentState = await machine.currentState
        XCTAssertEqual(currentState, .idle)
    }

    func testTimerTransitionsDragToIdle() async {
        let machine = PetAnimationStateMachine(initialState: .drag)

        let nextState = await machine.handleTrigger(.timer)

        XCTAssertEqual(nextState, .idle)
        let currentState = await machine.currentState
        XCTAssertEqual(currentState, .idle)
    }

    func testTimerReturnsNilFromSleep() async {
        let machine = PetAnimationStateMachine(initialState: .sleep)

        let nextState = await machine.handleTrigger(.timer)

        XCTAssertNil(nextState)
        let currentState = await machine.currentState
        XCTAssertEqual(currentState, .sleep)
    }

    func testTimerFromIdleTransitionsToAutonomousStates() async {
        var observedStates = Set<AnimationState>()

        for _ in 0..<1_000 {
            let machine = PetAnimationStateMachine(initialState: .idle)
            let nextState = await machine.handleTrigger(.timer)

            XCTAssertNotNil(nextState)
            if let nextState {
                XCTAssertTrue(
                    [
                        AnimationState.walk,
                        .sleep,
                        .stretch,
                        .yawn,
                        .lookAround,
                        .bounce
                    ].contains(nextState)
                )
                observedStates.insert(nextState)
            }
        }

        XCTAssertFalse(observedStates.isEmpty)
        XCTAssertTrue(observedStates.isSubset(of: [.walk, .sleep, .stretch, .yawn, .lookAround, .bounce]))
        XCTAssertTrue(observedStates.contains(.walk))
        XCTAssertTrue(observedStates.contains(.sleep))
    }

    func testAppSwitchTransitionsIdleToReact() async {
        let machine = PetAnimationStateMachine(initialState: .idle)

        let nextState = await machine.handleTrigger(.appSwitch)

        XCTAssertEqual(nextState, .react)
        let currentState = await machine.currentState
        XCTAssertEqual(currentState, .react)
    }

    func testAppSwitchReturnsNilFromWalk() async {
        let machine = PetAnimationStateMachine(initialState: .walk)

        let nextState = await machine.handleTrigger(.appSwitch)

        XCTAssertNil(nextState)
        let currentState = await machine.currentState
        XCTAssertEqual(currentState, .walk)
    }

    func testUserInteractTransitionsSleepToIdle() async {
        let machine = PetAnimationStateMachine(initialState: .sleep)

        let nextState = await machine.handleTrigger(.userInteract)

        XCTAssertEqual(nextState, .idle)
        let currentState = await machine.currentState
        XCTAssertEqual(currentState, .idle)
    }

    func testUserInteractTransitionsDragToIdle() async {
        let machine = PetAnimationStateMachine(initialState: .drag)

        let nextState = await machine.handleTrigger(.userInteract)

        XCTAssertEqual(nextState, .idle)
        let currentState = await machine.currentState
        XCTAssertEqual(currentState, .idle)
    }

    func testUserInteractTransitionsIdleToReact() async {
        let machine = PetAnimationStateMachine(initialState: .idle)

        let nextState = await machine.handleTrigger(.userInteract)

        XCTAssertEqual(nextState, .react)
        let currentState = await machine.currentState
        XCTAssertEqual(currentState, .react)
    }

    func testUserInteractTransitionsWalkToReact() async {
        let machine = PetAnimationStateMachine(initialState: .walk)

        let nextState = await machine.handleTrigger(.userInteract)

        XCTAssertEqual(nextState, .react)
        let currentState = await machine.currentState
        XCTAssertEqual(currentState, .react)
    }

    func testNewStates_returnToIdleOnTimer() async {
        for state in newAutonomousStates {
            let machine = PetAnimationStateMachine(initialState: state)

            let nextState = await machine.handleTrigger(.timer)

            XCTAssertEqual(nextState, .idle)
            let currentState = await machine.currentState
            XCTAssertEqual(currentState, .idle)
        }
    }

    func testNewStates_reactOnUserInteract() async {
        for state in newAutonomousStates {
            let machine = PetAnimationStateMachine(initialState: state)

            let nextState = await machine.handleTrigger(.userInteract)

            XCTAssertEqual(nextState, .react)
            let currentState = await machine.currentState
            XCTAssertEqual(currentState, .react)
        }
    }

    func testIdleTimerDistribution() {
        var counts: [AnimationState: Int] = [:]

        for roll in 0..<100 {
            let state = PetAnimationStateMachine.idleTimerState(for: roll)
            counts[state, default: 0] += 1
        }

        XCTAssertEqual(counts[.walk], 40)
        XCTAssertEqual(counts[.sleep], 5)
        XCTAssertEqual(counts[.stretch], 15)
        XCTAssertEqual(counts[.yawn], 15)
        XCTAssertEqual(counts[.lookAround], 15)
        XCTAssertEqual(counts[.bounce], 10)
        XCTAssertEqual(Set(counts.keys), [.walk, .sleep, .stretch, .yawn, .lookAround, .bounce])
    }

    func testIdleTimerDistribution_happyMood() {
        var counts: [AnimationState: Int] = [:]

        for roll in 0..<100 {
            let state = PetAnimationStateMachine.idleTimerState(for: roll, mood: .happy)
            counts[state, default: 0] += 1
        }

        XCTAssertEqual(counts[.walk], 30)
        XCTAssertEqual(counts[.bounce], 25)
        XCTAssertEqual(counts[.celebrate], 15)
        XCTAssertEqual(counts[.stretch], 10)
        XCTAssertEqual(counts[.lookAround], 10)
        XCTAssertEqual(counts[.yawn], 5)
        XCTAssertEqual(counts[.sleep], 5)
        XCTAssertEqual(Set(counts.keys), [.walk, .bounce, .celebrate, .stretch, .lookAround, .yawn, .sleep])
    }

    func testIdleTimerDistribution_sadMood() {
        var counts: [AnimationState: Int] = [:]

        for roll in 0..<100 {
            let state = PetAnimationStateMachine.idleTimerState(for: roll, mood: .sad)
            counts[state, default: 0] += 1
        }

        XCTAssertEqual(counts[.sleep], 25)
        XCTAssertEqual(counts[.yawn], 25)
        XCTAssertEqual(counts[.lookAround], 20)
        XCTAssertEqual(counts[.walk], 15)
        XCTAssertEqual(counts[.stretch], 10)
        XCTAssertEqual(counts[.bounce], 5)
        XCTAssertEqual(Set(counts.keys), [.sleep, .yawn, .lookAround, .walk, .stretch, .bounce])
    }

    func testSetStateUpdatesCurrentState() async {
        let machine = PetAnimationStateMachine(initialState: .idle)

        await machine.setState(.celebrate)

        let currentState = await machine.currentState
        XCTAssertEqual(currentState, .celebrate)
    }
}
