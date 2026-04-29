import CoreServices
import Foundation

public actor FSEventsMonitor: EventSource {
    public let sourceId: String

    // CallbackContext holds only immutable let fields (EventBus actor is Sendable),
    // so plain Sendable conformance is correct — no @unchecked needed.
    private final class CallbackContext: Sendable {
        let eventBus: EventBus

        init(eventBus: EventBus) {
            self.eventBus = eventBus
        }
    }

    private let paths: [String]
    private let latency: CFTimeInterval
    private let queue: DispatchQueue
    private var streamRef: FSEventStreamRef?
    private var callbackContext: UnsafeMutableRawPointer?

    /// Whether the FSEvents stream is currently active.
    public var isMonitoring: Bool { streamRef != nil }

    private static let callback: FSEventStreamCallback = { _, clientCallBackInfo, numEvents, eventPaths, eventFlags, _ in
        guard let clientCallBackInfo else {
            return
        }

        let context = Unmanaged<CallbackContext>
            .fromOpaque(clientCallBackInfo)
            .takeUnretainedValue()
        let paths = unsafeBitCast(eventPaths, to: CFArray.self) as NSArray
        let eventBus = context.eventBus

        for index in 0..<numEvents {
            guard let changedPath = paths[index] as? String else {
                continue
            }

            let flags = eventFlags[Int(index)]
            Task {
                await eventBus.publish(.fileChanged(path: changedPath, flags: flags))
            }
        }
    }

    public init(
        paths: [String],
        latency: CFTimeInterval = 0.5,
        sourceId: String = "fsEvents",
        queue: DispatchQueue? = nil
    ) {
        self.paths = paths.map {
            URL(fileURLWithPath: $0)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
        }
        self.latency = latency
        self.sourceId = sourceId
        self.queue = queue ?? DispatchQueue(label: "vitapet.fs-events-monitor")
    }

    public func start(publishingTo eventBus: EventBus) async {
        guard streamRef == nil, !paths.isEmpty else {
            return
        }

        let context = CallbackContext(eventBus: eventBus)
        let contextPointer = Unmanaged.passRetained(context).toOpaque()
        callbackContext = contextPointer

        var streamContext = FSEventStreamContext(
            version: 0,
            info: contextPointer,
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let streamFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.callback,
            &streamContext,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            streamFlags
        ) else {
            releaseContextIfNeeded()
            return
        }

        streamRef = stream
        FSEventStreamSetDispatchQueue(stream, queue)

        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            streamRef = nil
            releaseContextIfNeeded()
            return
        }
    }

    public func stop() async {
        guard let streamRef else {
            releaseContextIfNeeded()
            return
        }

        FSEventStreamStop(streamRef)
        FSEventStreamInvalidate(streamRef)
        FSEventStreamRelease(streamRef)
        self.streamRef = nil
        releaseContextIfNeeded()
    }

    private func releaseContextIfNeeded() {
        guard let callbackContext else {
            return
        }

        Unmanaged<CallbackContext>.fromOpaque(callbackContext).release()
        self.callbackContext = nil
    }
}
