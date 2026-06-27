import Foundation

/// Opaque identifier for a supervised run.
public struct RunID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

/// Handle returned by `launch`. Carries the run's id, its event stream, and async accessors
/// for state the engine fills in as the run progresses.
public struct RunHandle: Sendable {
    public let id: RunID
    public let events: AsyncStream<AnvilEvent>
    let engine: AnvilEngine

    /// The claude `session_id`, available once the `system/init` event arrives.
    public var sessionID: String? {
        get async { await engine.sessionID(for: id) }
    }

    public var state: RunState? {
        get async { await engine.state(for: id) }
    }
}
