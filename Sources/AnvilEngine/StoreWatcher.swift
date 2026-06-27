import Foundation
import CoreServices

/// Watches a directory tree (the central tk store) via FSEvents and emits a debounced change
/// signal. CoreServices is a system framework, not a UI dependency. anvil re-reads on change;
/// it never runs `tk serve`.
///
/// Lifetime: while running, the FSEvents stream holds a strong reference to the watcher (a
/// retained context), so callbacks never touch a deallocated instance even if the caller drops
/// its reference without calling `stop()`. Call `stop()` to release the stream (and the
/// watcher). Multiple observers each get an independent `changes()` stream.
public final class StoreWatcher: @unchecked Sendable {
    private let path: URL
    private let debounce: TimeInterval
    private let queue = DispatchQueue(label: "com.anvil.storewatcher")

    // All of the following are touched only on `queue`.
    private var stream: FSEventStreamRef?
    private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var pendingNotify: DispatchWorkItem?

    public init(path: URL, debounce: TimeInterval = 0.2) {
        self.path = path
        self.debounce = debounce
    }

    /// A fresh change stream for one observer. Yields `()` after each debounced burst.
    public func changes() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream { continuation in
            queue.async { self.subscribers[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.queue.async { self?.subscribers[id] = nil }
            }
        }
    }

    public func start() {
        queue.async { self.startOnQueue() }
    }

    public func stop() {
        queue.async { self.stopOnQueue() }
    }

    private func startOnQueue() {
        guard stream == nil else { return }
        // Retain self into the context; the matching `release` balances it when the stream is
        // released, so the callback can never run against a deallocated watcher.
        let info = Unmanaged.passRetained(self).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: info,
            retain: nil,
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<StoreWatcher>.fromOpaque(pointer).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<StoreWatcher>.fromOpaque(info).takeUnretainedValue().scheduleNotify()
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [path.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            CFTimeInterval(0.05),
            flags
        ) else {
            // Create failed: balance the retain ourselves (no stream to release it).
            Unmanaged<StoreWatcher>.fromOpaque(info).release()
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func stopOnQueue() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    // Called on `queue` from the FSEvents callback. Coalesce a burst (git sync writes many
    // files at once) into a single signal.
    private func scheduleNotify() {
        pendingNotify?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.notifySubscribers() }
        pendingNotify = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private func notifySubscribers() {
        for continuation in subscribers.values {
            continuation.yield(())
        }
    }
}
