import EventBus
import XCTest

final class AppReactionRulesTests: XCTestCase {
    private func assertRule(
        _ rule: AppBehaviorRule?,
        category expectedCategory: String,
        animation expectedAnimation: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let rule else {
            XCTFail("Expected matching rule", file: file, line: line)
            return
        }

        XCTAssertEqual(rule.category, expectedCategory, file: file, line: line)
        XCTAssertEqual(rule.animation, expectedAnimation, file: file, line: line)
    }

    func testMatchRule_terminal() {
        let rule = AppBehaviorRules.matchRule(for: "com.apple.Terminal")

        assertRule(rule, category: "coding", animation: "type")
    }

    func testMatchRule_xcode() {
        let rule = AppBehaviorRules.matchRule(for: "com.apple.dt.Xcode")

        assertRule(rule, category: "coding", animation: "type")
    }

    func testMatchRule_browser() {
        let rule = AppBehaviorRules.matchRule(for: "com.google.Chrome")

        assertRule(rule, category: "browsing", animation: "read")
    }

    func testMatchRule_unknown() {
        let rule = AppBehaviorRules.matchRule(for: "com.apple.finder")

        XCTAssertNil(rule)
    }

    func testMatchRule_jetbrainsPrefix() {
        let rule = AppBehaviorRules.matchRule(for: "com.jetbrains.intellij")

        assertRule(rule, category: "coding", animation: "type")
    }

    func testMatchAnimationTrigger_terminal() {
        let trigger = AppBehaviorRules.matchAnimationTrigger(for: "com.apple.Terminal")

        guard case let .custom(animation)? = trigger else {
            XCTFail("Expected custom animation trigger")
            return
        }

        XCTAssertEqual(animation, "type")
    }
}
