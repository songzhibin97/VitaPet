import SecurityLayer
import XCTest

private actor MockCapabilityProvider: CapabilityProvider {
    nonisolated let capability: Capability
    nonisolated let requiredPermissions: [SystemPermission]
    nonisolated(unsafe) var isEnabled: Bool
    nonisolated var isAvailable: Bool { _isAvailable }
    nonisolated(unsafe) private var _isAvailable: Bool
    private var activateCallCount = 0
    private var deactivateCallCount = 0

    init(
        capability: Capability,
        permissions: [SystemPermission] = [],
        enabled: Bool = true,
        available: Bool = true
    ) {
        self.capability = capability
        self.requiredPermissions = permissions
        self.isEnabled = enabled
        self._isAvailable = available
    }

    func activate() async throws {
        activateCallCount += 1
    }

    func deactivate() async {
        deactivateCallCount += 1
    }

    func setAvailable(_ value: Bool) {
        _isAvailable = value
    }

    func setEnabled(_ value: Bool) {
        isEnabled = value
    }

    func activationCount() -> Int {
        activateCallCount
    }

    func deactivationCount() -> Int {
        deactivateCallCount
    }
}

final class CapabilityManagerTests: XCTestCase {
    func testRegister_storesProvider() async {
        let manager = CapabilityManager(permissionChecker: { _ in true })
        let provider = MockCapabilityProvider(capability: .systemAwareness)

        await manager.register(provider)

        let status = await manager.status(of: .systemAwareness)
        assertStatus(status, matches: .inactive)
    }

    func testActivate_succeeds_whenAllConditionsMet() async throws {
        let manager = CapabilityManager(permissionChecker: { _ in true })
        let provider = MockCapabilityProvider(
            capability: .systemAwareness,
            permissions: [.accessibility]
        )
        await manager.register(provider)

        try await manager.activate(.systemAwareness)

        let activationCount = await provider.activationCount()
        let status = await manager.status(of: .systemAwareness)
        XCTAssertEqual(activationCount, 1)
        assertStatus(status, matches: .active)
    }

    func testActivate_throws_whenNotRegistered() async {
        let manager = CapabilityManager(permissionChecker: { _ in true })

        do {
            try await manager.activate(.aiChat)
            XCTFail("Expected error")
        } catch let error as CapabilityManagerError {
            guard case .unavailable(.aiChat) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testActivate_throws_whenDisabled() async {
        let manager = CapabilityManager(permissionChecker: { _ in true })
        let provider = MockCapabilityProvider(capability: .aiChat, enabled: false)
        await manager.register(provider)

        do {
            try await manager.activate(.aiChat)
            XCTFail("Expected error")
        } catch let error as CapabilityManagerError {
            guard case .disabled(.aiChat) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testActivate_throws_whenPermissionMissing() async {
        let manager = CapabilityManager(permissionChecker: { _ in false })
        let provider = MockCapabilityProvider(
            capability: .fileAwareness,
            permissions: [.fullDiskAccess]
        )
        await manager.register(provider)

        do {
            try await manager.activate(.fileAwareness)
            XCTFail("Expected error")
        } catch let error as CapabilityManagerError {
            guard case let .permissionDenied(capability, missing) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(capability, .fileAwareness)
            XCTAssertEqual(missing, [.fullDiskAccess])
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testActivate_throws_whenNotAvailable() async {
        let manager = CapabilityManager(permissionChecker: { _ in true })
        let provider = MockCapabilityProvider(
            capability: .systemAwareness,
            permissions: [.accessibility],
            available: false
        )
        await manager.register(provider)

        do {
            try await manager.activate(.systemAwareness)
            XCTFail("Expected error")
        } catch let error as CapabilityManagerError {
            guard case let .permissionDenied(capability, missing) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(capability, .systemAwareness)
            XCTAssertEqual(missing, [.accessibility])
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDeactivate_callsProviderDeactivate() async {
        let manager = CapabilityManager(permissionChecker: { _ in true })
        let provider = MockCapabilityProvider(capability: .basePet)
        await manager.register(provider)
        try? await manager.activate(.basePet)

        await manager.deactivate(.basePet)

        let deactivationCount = await provider.deactivationCount()
        let status = await manager.status(of: .basePet)
        XCTAssertEqual(deactivationCount, 1)
        assertStatus(status, matches: .inactive)
    }

    func testDeactivate_nonexistentCapability_doesNotCrash() async {
        let manager = CapabilityManager(permissionChecker: { _ in true })

        await manager.deactivate(.butlerMode)
    }

    func testStatus_unregistered_returnsUnavailable() async {
        let manager = CapabilityManager(permissionChecker: { _ in true })

        let status = await manager.status(of: .butlerMode)
        assertStatus(status, matches: .unavailable)
    }

    func testStatus_active_returnsActive() async throws {
        let manager = CapabilityManager(permissionChecker: { _ in true })
        let provider = MockCapabilityProvider(capability: .basePet)
        await manager.register(provider)

        try await manager.activate(.basePet)

        let status = await manager.status(of: .basePet)
        assertStatus(status, matches: .active)
    }

    func testStatus_disabled_returnsInactive() async {
        let manager = CapabilityManager(permissionChecker: { _ in true })
        let provider = MockCapabilityProvider(capability: .aiChat, enabled: false)
        await manager.register(provider)

        let status = await manager.status(of: .aiChat)
        assertStatus(status, matches: .inactive)
    }

    func testStatus_permissionMissing_returnsPermissionNeeded() async {
        let manager = CapabilityManager(permissionChecker: { _ in false })
        let provider = MockCapabilityProvider(
            capability: .fileAwareness,
            permissions: [.fullDiskAccess]
        )
        await manager.register(provider)

        let status = await manager.status(of: .fileAwareness)
        assertStatus(status, matches: .permissionNeeded([.fullDiskAccess]))
    }

    func testAllStatuses_returnsAllRegistered() async {
        let manager = CapabilityManager(permissionChecker: { permission in
            permission != .screenRecording
        })
        let basePet = MockCapabilityProvider(capability: .basePet)
        let aiChat = MockCapabilityProvider(capability: .aiChat, enabled: false)
        let butler = MockCapabilityProvider(
            capability: .butlerMode,
            permissions: [.screenRecording]
        )
        await manager.register(basePet)
        await manager.register(aiChat)
        await manager.register(butler)

        let statuses = await manager.allStatuses()

        XCTAssertEqual(statuses.count, 3)
        assertOptionalStatus(statuses[.basePet], matches: .inactive)
        assertOptionalStatus(statuses[.aiChat], matches: .inactive)
        assertOptionalStatus(statuses[.butlerMode], matches: .permissionNeeded([.screenRecording]))
    }
}

private func assertStatus(
    _ actual: CapabilityStatus,
    matches expected: CapabilityStatus,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    switch (actual, expected) {
    case (.active, .active), (.inactive, .inactive), (.unavailable, .unavailable):
        XCTAssertTrue(true, file: file, line: line)
    case let (.permissionNeeded(actualPermissions), .permissionNeeded(expectedPermissions)):
        XCTAssertEqual(actualPermissions, expectedPermissions, file: file, line: line)
    default:
        XCTFail("Unexpected status \(actual) expected \(expected)", file: file, line: line)
    }
}

private func assertOptionalStatus(
    _ actual: CapabilityStatus?,
    matches expected: CapabilityStatus,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard let actual else {
        return XCTFail("Missing capability status", file: file, line: line)
    }
    assertStatus(actual, matches: expected, file: file, line: line)
}
