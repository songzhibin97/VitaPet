import AppKit
import Foundation

@MainActor
public final class KeyboardMonitor: EventSource, Sendable {
    public let sourceId: String = "keyboard"

    private let addGlobalMonitor: (@escaping (NSEvent) -> Void) -> Any?
    private let addLocalMonitor: (@escaping (NSEvent) -> NSEvent?) -> Any?
    private let removeMonitor: (Any) -> Void

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isStarted = false

    public init(
        addGlobalMonitor: @escaping (@escaping (NSEvent) -> Void) -> Any? = { handler in
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        },
        addLocalMonitor: @escaping (@escaping (NSEvent) -> NSEvent?) -> Any? = { handler in
            NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler)
        },
        removeMonitor: @escaping (Any) -> Void = { monitor in
            NSEvent.removeMonitor(monitor)
        }
    ) {
        self.addGlobalMonitor = addGlobalMonitor
        self.addLocalMonitor = addLocalMonitor
        self.removeMonitor = removeMonitor
    }

    public func start(publishingTo eventBus: EventBus) async {
        guard !isStarted else {
            return
        }

        isStarted = true

        globalMonitor = addGlobalMonitor { event in
            Task {
                await eventBus.publish(.hotkeyPressed(
                    keyCode: event.keyCode,
                    modifiers: UInt32(event.modifierFlags.rawValue)
                ))
            }
        }

        localMonitor = addLocalMonitor { event in
            Task {
                await eventBus.publish(.hotkeyPressed(
                    keyCode: event.keyCode,
                    modifiers: UInt32(event.modifierFlags.rawValue)
                ))
            }

            return Self.isChatHotkey(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags
            ) ? nil : event
        }
    }

    public func stop() async {
        if let globalMonitor {
            removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }

        if let localMonitor {
            removeMonitor(localMonitor)
            self.localMonitor = nil
        }

        isStarted = false
    }

    public static func isChatHotkey(keyCode: UInt16, modifiers: UInt32) -> Bool {
        isChatHotkey(
            keyCode: keyCode,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        )
    }

    public static func isChatHotkey(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        keyCode == 9 &&
            modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .isSuperset(of: [.command, .shift])
    }
}
