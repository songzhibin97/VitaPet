import SecurityLayer
import XCTest

final class KeychainManagerTests: XCTestCase {
    private let testService = "app.vitapet.secrets.test"
    private var manager: KeychainManager!

    override func setUp() async throws {
        manager = KeychainManager(service: testService)
        try await cleanupAll()
    }

    override func tearDown() async throws {
        try await cleanupAll()
    }

    private func cleanupAll() async throws {
        let keys = ["testKey", "stringKey", "duplicateKey", "deleteKey", "missingKey"]
        for key in keys {
            try await manager.delete(forKey: key)
        }
    }

    func testSet_thenGet_returnsStoredValue() async throws {
        let value = Data("hello".utf8)

        try await manager.set(value, forKey: "testKey")
        let result = try await manager.get(forKey: "testKey")

        XCTAssertEqual(result, value)
    }

    func testGet_missingKey_returnsNil() async throws {
        let result = try await manager.get(forKey: "missingKey")

        XCTAssertNil(result)
    }

    func testSet_duplicateKey_updatesValue() async throws {
        let first = Data("first".utf8)
        let second = Data("second".utf8)

        try await manager.set(first, forKey: "duplicateKey")
        try await manager.set(second, forKey: "duplicateKey")
        let result = try await manager.get(forKey: "duplicateKey")

        XCTAssertEqual(result, second)
    }

    func testDelete_afterSet_getReturnsNil() async throws {
        try await manager.set(Data("value".utf8), forKey: "deleteKey")

        try await manager.delete(forKey: "deleteKey")
        let result = try await manager.get(forKey: "deleteKey")

        XCTAssertNil(result)
    }

    func testDelete_missingKey_doesNotThrow() async throws {
        try await manager.delete(forKey: "missingKey")
    }

    func testSetString_getString_roundTrip() async throws {
        try await manager.setString("swift6", forKey: "stringKey")
        let result = try await manager.getString(forKey: "stringKey")

        XCTAssertEqual(result, "swift6")
    }

    func testGetString_missingKey_returnsNil() async throws {
        let result = try await manager.getString(forKey: "missingKey")

        XCTAssertNil(result)
    }
}
