import AppKit
import XCTest
@testable import EventBus

private actor WorkspaceEventRecorder {
    private var events: [AppEvent] = []

    func record(_ event: AppEvent) {
        events.append(event)
    }

    func all() -> [AppEvent] {
        events
    }
}

@MainActor
final class WorkspaceMonitorTests: XCTestCase {
    private func makeApplicationUserInfo() throws -> (app: NSRunningApplication, bundleId: String, appName: String) {
        for application in NSWorkspace.shared.runningApplications {
            if let bundleId = application.bundleIdentifier, let appName = application.localizedName {
                return (application, bundleId, appName)
            }
        }

        throw XCTSkip("No running application with bundle identifier and localized name was available")
    }

    func testSourceId() {
        let monitor = WorkspaceMonitor(notificationCenter: NotificationCenter())

        XCTAssertEqual(monitor.sourceId, "workspace")
    }

    func testStart_isIdempotent() async throws {
        let notificationCenter = NotificationCenter()
        let eventBus = EventBus()
        let monitor = WorkspaceMonitor(notificationCenter: notificationCenter)
        let recorder = WorkspaceEventRecorder()
        let received = expectation(description: "single app activated event published")
        received.assertForOverFulfill = true
        let application = try makeApplicationUserInfo()

        _ = await eventBus.subscribe { event in
            guard case .appActivated = event else {
                return
            }

            await recorder.record(event)
            received.fulfill()
        }

        await monitor.start(publishingTo: eventBus)
        await monitor.start(publishingTo: eventBus)

        notificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: application.app]
        )

        await fulfillment(of: [received], timeout: 1.0)
        try? await Task.sleep(for: .milliseconds(200))
        await monitor.stop()

        let events = await recorder.all()
        XCTAssertEqual(events.count, 1)
    }

    func testStop_removesObservers() async {
        let notificationCenter = NotificationCenter()
        let eventBus = EventBus()
        let monitor = WorkspaceMonitor(notificationCenter: notificationCenter)
        let recorder = WorkspaceEventRecorder()
        let notReceivedAfterStop = expectation(description: "no workspace event after stop")
        notReceivedAfterStop.isInverted = true

        _ = await eventBus.subscribe { event in
            switch event {
            case .appActivated, .appDeactivated:
                await recorder.record(event)
                notReceivedAfterStop.fulfill()
            default:
                return
            }
        }

        await monitor.start(publishingTo: eventBus)
        await monitor.stop()

        if let application = try? makeApplicationUserInfo() {
            notificationCenter.post(
                name: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                userInfo: [NSWorkspace.applicationUserInfoKey: application.app]
            )
            notificationCenter.post(
                name: NSWorkspace.didDeactivateApplicationNotification,
                object: nil,
                userInfo: [NSWorkspace.applicationUserInfoKey: application.app]
            )
        }

        await fulfillment(of: [notReceivedAfterStop], timeout: 0.3)

        let events = await recorder.all()
        XCTAssertTrue(events.isEmpty)
    }

    func testStart_publishesAppActivated() async throws {
        let notificationCenter = NotificationCenter()
        let eventBus = EventBus()
        let monitor = WorkspaceMonitor(notificationCenter: notificationCenter)
        let received = expectation(description: "app activated event published")
        let application = try makeApplicationUserInfo()

        _ = await eventBus.subscribe { event in
            guard case let .appActivated(bundleId, publishedAppName) = event else {
                return
            }

            XCTAssertEqual(bundleId, application.bundleId)
            XCTAssertEqual(publishedAppName, application.appName)
            received.fulfill()
        }

        await monitor.start(publishingTo: eventBus)

        notificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: application.app]
        )

        await fulfillment(of: [received], timeout: 1.0)
        await monitor.stop()
    }

    func testStart_publishesAppDeactivated() async throws {
        let notificationCenter = NotificationCenter()
        let eventBus = EventBus()
        let monitor = WorkspaceMonitor(notificationCenter: notificationCenter)
        let received = expectation(description: "app deactivated event published")
        let application = try makeApplicationUserInfo()

        _ = await eventBus.subscribe { event in
            guard case let .appDeactivated(publishedBundleId, publishedAppName) = event else {
                return
            }

            XCTAssertEqual(publishedBundleId, application.bundleId)
            XCTAssertEqual(publishedAppName, application.appName)
            received.fulfill()
        }

        await monitor.start(publishingTo: eventBus)

        notificationCenter.post(
            name: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: application.app]
        )

        await fulfillment(of: [received], timeout: 1.0)
        await monitor.stop()
    }
}
