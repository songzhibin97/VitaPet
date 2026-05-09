import AppKit
import XCTest
@testable import ChatUI

@MainActor
final class MCPJSONEditorConfigurationTests: XCTestCase {
    func testConfigure_disablesLineWrappingAndEnablesHorizontalScrolling() {
        let scrollView = NSScrollView()
        let textView = NSTextView()

        MCPJSONEditorConfiguration.configure(scrollView: scrollView, textView: textView)

        XCTAssertTrue(scrollView.hasHorizontalScroller)
        XCTAssertTrue(scrollView.hasVerticalScroller)
        XCTAssertTrue(textView.isHorizontallyResizable)
        XCTAssertTrue(textView.isVerticallyResizable)
        XCTAssertEqual(textView.textContainer?.widthTracksTextView, false)
        XCTAssertEqual(textView.textContainer?.containerSize.width, .greatestFiniteMagnitude)
        XCTAssertFalse(textView.isAutomaticQuoteSubstitutionEnabled)
    }
}