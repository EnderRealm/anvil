import XCTest
@testable import AnvilEngine

private actor SignalCounter {
    private(set) var count = 0
    func increment() { count += 1 }
    func value() -> Int { count }
}

final class StoreWatcherTests: XCTestCase {

    func testWatcherFiresOnChange() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let watcher = StoreWatcher(path: dir, debounce: 0.1)
        let counter = SignalCounter()
        let stream = watcher.changes()
        let consumer = Task { for await _ in stream { await counter.increment() } }
        defer { consumer.cancel(); watcher.stop() }

        watcher.start()
        try await Task.sleep(nanoseconds: 300_000_000)  // let FSEvents come up

        try "x".write(to: dir.appendingPathComponent("change.txt"), atomically: true, encoding: .utf8)

        try await waitUntil(timeout: 8) { await counter.value() >= 1 }
        let count = await counter.value()
        XCTAssertGreaterThanOrEqual(count, 1)
    }

    func testWatcherCoalescesBurst() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let watcher = StoreWatcher(path: dir, debounce: 0.5)
        let counter = SignalCounter()
        let stream = watcher.changes()
        let consumer = Task { for await _ in stream { await counter.increment() } }
        defer { consumer.cancel(); watcher.stop() }

        watcher.start()
        try await Task.sleep(nanoseconds: 300_000_000)

        // A tight burst (git-sync style) of many writes must collapse to a handful of signals,
        // not one per file. Non-atomic writes to avoid temp-file/rename event churn.
        let burst = 20
        for i in 0..<burst {
            try "x".write(to: dir.appendingPathComponent("burst-\(i).txt"), atomically: false, encoding: .utf8)
        }

        // Wait past the debounce window plus slack, then assert heavy coalescing.
        try await waitUntil(timeout: 8) { await counter.value() >= 1 }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let count = await counter.value()
        XCTAssertGreaterThanOrEqual(count, 1)
        XCTAssertLessThanOrEqual(count, 3, "a \(burst)-file burst should coalesce to a few signals, got \(count)")
    }
}
