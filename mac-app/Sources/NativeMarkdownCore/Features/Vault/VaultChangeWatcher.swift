import CoreServices
import Foundation

public protocol VaultChangeWatch: AnyObject {
    func cancel()
}

public protocol VaultChangeWatching {
    func startWatching(
        vaultURL: URL,
        onChange: @escaping () -> Void
    ) throws -> any VaultChangeWatch
}

public enum VaultChangeWatcherError: Error, Equatable {
    case streamCreationFailed
    case streamStartFailed
}

public final class FSEventsVaultChangeWatcher: VaultChangeWatching {
    private let latency: CFTimeInterval

    public init(latency: CFTimeInterval = 0.75) {
        self.latency = latency
    }

    public func startWatching(
        vaultURL: URL,
        onChange: @escaping () -> Void
    ) throws -> any VaultChangeWatch {
        let context = WatchContext(onChange: onChange)
        let contextPointer = Unmanaged.passRetained(context).toOpaque()
        var streamContext = FSEventStreamContext(
            version: 0,
            info: contextPointer,
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let paths = [vaultURL.standardizedFileURL.path] as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, eventCount, _, _, _ in
                guard eventCount > 0, let info else {
                    return
                }
                let context = Unmanaged<WatchContext>.fromOpaque(info).takeUnretainedValue()
                context.onChange()
            },
            &streamContext,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            Unmanaged<WatchContext>.fromOpaque(contextPointer).release()
            throw VaultChangeWatcherError.streamCreationFailed
        }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)

        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            Unmanaged<WatchContext>.fromOpaque(contextPointer).release()
            throw VaultChangeWatcherError.streamStartFailed
        }

        return FSEventsVaultChangeWatch(stream: stream, contextPointer: contextPointer)
    }
}

private final class WatchContext {
    let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }
}

private final class FSEventsVaultChangeWatch: VaultChangeWatch {
    private var stream: FSEventStreamRef?
    private var contextPointer: UnsafeMutableRawPointer?

    init(stream: FSEventStreamRef, contextPointer: UnsafeMutableRawPointer) {
        self.stream = stream
        self.contextPointer = contextPointer
    }

    func cancel() {
        guard let stream, let contextPointer else {
            return
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamSetDispatchQueue(stream, nil)
        FSEventStreamRelease(stream)
        Unmanaged<WatchContext>.fromOpaque(contextPointer).release()
        self.stream = nil
        self.contextPointer = nil
    }

    deinit {
        cancel()
    }
}

public protocol VaultIndexRefreshScheduling: AnyObject {
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void)
    func cancel()
}

public final class DispatchVaultIndexRefreshScheduler: VaultIndexRefreshScheduling {
    private let queue: DispatchQueue
    private var workItem: DispatchWorkItem?

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    public func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) {
        cancel()
        let workItem = DispatchWorkItem(block: action)
        self.workItem = workItem
        queue.asyncAfter(deadline: .now() + max(0, delay), execute: workItem)
    }

    public func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}
