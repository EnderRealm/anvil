import Foundation

/// What a parsed `result` line tells us to do once the process exits. Resolution is deferred
/// to process exit so the exit code can veto a clean result (nonzero exit => failure).
enum PendingOutcome {
    case needsInput(question: String, options: [String])
    case done(summary: String?)
    case failure(EngineError)
}

/// Mutable per-run state. Only ever touched on the `AnvilEngine` actor.
final class RunContext {
    let id: RunID
    let stream: AsyncStream<AnvilEvent>
    let continuation: AsyncStream<AnvilEvent>.Continuation
    /// cwd for both launch and resume — resume is scoped to the encoded cwd.
    let cwd: URL

    var sessionID: String?
    var state: RunState = .queued
    var process: Process?
    var pending: PendingOutcome?
    var canceled = false

    init(
        id: RunID,
        stream: AsyncStream<AnvilEvent>,
        continuation: AsyncStream<AnvilEvent>.Continuation,
        cwd: URL
    ) {
        self.id = id
        self.stream = stream
        self.continuation = continuation
        self.cwd = cwd
    }
}
