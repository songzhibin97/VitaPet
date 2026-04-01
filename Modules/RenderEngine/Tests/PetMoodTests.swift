import XCTest
@testable import RenderEngine

final class PetMoodTests: XCTestCase {
    func testInitialHappiness() async {
        let mood = PetMood()

        let happiness = await mood.happiness

        XCTAssertEqual(happiness, 50)
    }

    func testAdjust_increase() async {
        let mood = PetMood()

        await mood.adjust(by: 5)
        let happiness = await mood.happiness

        XCTAssertEqual(happiness, 55)
    }

    func testAdjust_decrease() async {
        let mood = PetMood()

        await mood.adjust(by: -10)
        let happiness = await mood.happiness

        XCTAssertEqual(happiness, 40)
    }

    func testAdjust_upperBound() async {
        let mood = PetMood(happiness: 95)

        await mood.adjust(by: 10)
        let happiness = await mood.happiness

        XCTAssertEqual(happiness, 100)
    }

    func testAdjust_lowerBound() async {
        let mood = PetMood(happiness: 5)

        await mood.adjust(by: -10)
        let happiness = await mood.happiness

        XCTAssertEqual(happiness, 0)
    }

    func testMoodLevel_happy() async {
        let mood = PetMood(happiness: 71)

        let level = await mood.level

        XCTAssertEqual(level, .happy)
    }

    func testMoodLevel_normal() async {
        let mood = PetMood(happiness: 50)

        let level = await mood.level

        XCTAssertEqual(level, .normal)
    }

    func testMoodLevel_sad() async {
        let mood = PetMood(happiness: 29)

        let level = await mood.level

        XCTAssertEqual(level, .sad)
    }
}
