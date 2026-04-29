import AppKit
import EventBus
import RenderEngine

/// Monitors macOS screen sleep/wake notifications and throttles background work
/// (ClipboardMonitor, TimerSource, PetScene rendering) while the screen is off.
@MainActor
final class ScreenStateCoordinator {
    private let clipboardMonitor: ClipboardMonitor
    private let timerSource: TimerSource
    private let eventBus: EventBus
    private let petScenesProvider: @MainActor () -> [PetScene]

    private let notificationCenter: NotificationCenter
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var isAsleep: Bool = false

    init(
        clipboardMonitor: ClipboardMonitor,
        timerSource: TimerSource,
        eventBus: EventBus,
        petScenesProvider: @MainActor @escaping () -> [PetScene],
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.clipboardMonitor = clipboardMonitor
        self.timerSource = timerSource
        self.eventBus = eventBus
        self.petScenesProvider = petScenesProvider
        self.notificationCenter = notificationCenter
    }

    func start() {
        guard sleepObserver == nil, wakeObserver == nil else {
            return
        }

        sleepObserver = notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.handleSleep()
            }
        }

        wakeObserver = notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.handleWake()
            }
        }
    }

    func stop() {
        if let sleepObserver {
            notificationCenter.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }
        if let wakeObserver {
            notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        // Ensure everything is resumed on stop so state is clean.
        if isAsleep {
            Task { @MainActor in
                await self.handleWake()
            }
        }
    }

    // MARK: - Internal handlers

    func handleSleep() async {
        guard !isAsleep else { return }
        isAsleep = true

        await clipboardMonitor.stop()
        await timerSource.stop()

        for scene in petScenesProvider() {
            scene.pauseRendering()
        }
    }

    func handleWake() async {
        guard isAsleep else { return }
        isAsleep = false

        await clipboardMonitor.start(publishingTo: eventBus)
        await timerSource.start(publishingTo: eventBus)

        for scene in petScenesProvider() {
            scene.resumeRendering()
        }
    }
}
