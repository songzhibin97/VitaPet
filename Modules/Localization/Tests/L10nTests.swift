import Localization
import XCTest

final class L10nTests: XCTestCase {
    private var originalLocale: String = L10n.locale

    override func setUp() {
        super.setUp()
        originalLocale = L10n.locale
    }

    override func tearDown() {
        L10n.locale = originalLocale
        super.tearDown()
    }

    func testStringLookupUsesCurrentLocale() {
        L10n.locale = "zh-Hans"
        XCTAssertEqual(L10n.menuChat, "聊天")

        L10n.locale = "en"
        XCTAssertEqual(L10n.menuChat, "Chat")
    }

    func testMissingKeyFallsBackToKey() {
        L10n.locale = "en"
        XCTAssertEqual(L10n.tr("missing.key"), "missing.key")
    }

    func testArrayLookupReturnsLocalizedStrings() {
        L10n.locale = "zh-Hans"
        XCTAssertEqual(L10n.bubbleTexts.first, "嗨！")

        L10n.locale = "en"
        XCTAssertEqual(L10n.bubbleTexts.first, "Hi!")
    }

    func testMissingArrayFallsBackToKeyArray() {
        L10n.locale = "en"
        XCTAssertEqual(L10n.trs("missing.array"), ["missing.array"])
    }

    func testUnsupportedLocaleFallsBackToDefaultBundle() {
        L10n.locale = "fr"
        XCTAssertEqual(L10n.menuSettings, "设置")
    }
}
