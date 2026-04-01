import FocusMonitor
import XCTest

final class ExemptionListTests: XCTestCase {
    func testInit_emptyByDefault() {
        let list = ExemptionList()

        XCTAssertTrue(list.exemptedBundleIds.isEmpty)
    }

    func testAdd_insertsBundle() {
        var list = ExemptionList()

        list.add(bundleId: "com.example.app")

        XCTAssertTrue(list.exemptedBundleIds.contains("com.example.app"))
    }

    func testAdd_duplicate_noCrash() {
        var list = ExemptionList()

        list.add(bundleId: "com.example.app")
        list.add(bundleId: "com.example.app")

        XCTAssertEqual(list.exemptedBundleIds.count, 1)
    }

    func testRemove_existingBundle() {
        var list = ExemptionList(exemptedBundleIds: ["com.example.app"])

        list.remove(bundleId: "com.example.app")

        XCTAssertFalse(list.exemptedBundleIds.contains("com.example.app"))
    }

    func testRemove_nonexistent_noCrash() {
        var list = ExemptionList()

        list.remove(bundleId: "com.example.missing")

        XCTAssertTrue(list.exemptedBundleIds.isEmpty)
    }

    func testIsExempted_true_forAdded() {
        let list = ExemptionList(exemptedBundleIds: ["com.example.app"])

        XCTAssertTrue(list.isExempted(bundleId: "com.example.app"))
    }

    func testIsExempted_false_forNotAdded() {
        let list = ExemptionList()

        XCTAssertFalse(list.isExempted(bundleId: "com.example.app"))
    }

    func testAddThenRemove_notExempted() {
        var list = ExemptionList()

        list.add(bundleId: "com.example.app")
        list.remove(bundleId: "com.example.app")

        XCTAssertFalse(list.isExempted(bundleId: "com.example.app"))
    }

    func testInitWithPredefinedSet() {
        let list = ExemptionList(exemptedBundleIds: ["com.example.one", "com.example.two"])

        XCTAssertEqual(list.exemptedBundleIds, ["com.example.one", "com.example.two"])
    }
}
