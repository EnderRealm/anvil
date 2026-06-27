import Foundation

/// Errors surfaced by the engine, both thrown from commands and carried on `.failed` events.
public enum EngineError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    /// The ticket's project has no local repo in `~/.ticket/config.yaml` — browse-only here.
    case projectNotLaunchableOnThisHost(String)
    /// The ticket id is not in `project/slug` form.
    case invalidTicketID(String)
    /// No executable `claude` could be resolved at the configured path.
    case claudeExecutableNotFound(String)
    /// The tk config could not be read.
    case ticketConfigUnreadable(String)
    case runNotFound(RunID)
    /// `resume` was called before a `session_id` arrived.
    case noSessionID(RunID)
    /// `resume` was called on a run that is not waiting for input.
    case runNotResumable(RunID)
    /// The `claude` process could not be spawned.
    case processSpawnFailed(String)
    /// The process exited nonzero.
    case processFailed(reason: String, exitCode: Int32)
    /// The result reported `is_error` or a non-`completed` terminal reason.
    case agentFailed(String)
    /// A sentinel marker was present but its JSON payload could not be parsed.
    case malformedSentinel

    public var description: String {
        switch self {
        case .projectNotLaunchableOnThisHost(let p):
            return "project '\(p)' is not launchable on this host (no local repo in ~/.ticket/config.yaml)"
        case .invalidTicketID(let id):
            return "invalid ticket id '\(id)' — expected 'project/slug'"
        case .claudeExecutableNotFound(let path):
            return "no executable claude found at '\(path)'"
        case .ticketConfigUnreadable(let path):
            return "could not read tk config at '\(path)'"
        case .runNotFound(let id):
            return "no run with id \(id)"
        case .noSessionID(let id):
            return "run \(id) has no session id yet — cannot resume"
        case .runNotResumable(let id):
            return "run \(id) is not waiting for input — cannot resume"
        case .processSpawnFailed(let reason):
            return "failed to spawn claude: \(reason)"
        case .processFailed(let reason, let code):
            return "claude exited with code \(code): \(reason)"
        case .agentFailed(let reason):
            return "agent reported failure: \(reason)"
        case .malformedSentinel:
            return "agent emitted a sentinel marker with unparseable JSON"
        }
    }

    public var errorDescription: String? { description }
}
