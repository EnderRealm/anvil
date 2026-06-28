import AnvilEngine

/// Semantic status of a ticket row, combining its live run (if any) with tk state. The View
/// layer maps these to SF Symbols + the semantic palette; the categorization is logic.
public enum StatusKind: String, Sendable, Equatable {
    case ready
    case running
    case needsInput
    case done
    case failed
    case blocked
    case backlog
    case open
    case closed

    /// Live run state wins; then the F3 `anvil-state` signal; then tk status + ready/blocked.
    public static func of(
        ticket: TicketSummary,
        run: RunModel?,
        ready: Set<String>,
        blocked: Set<String>
    ) -> StatusKind {
        if let run, run.state.isActive {
            switch run.state {
            case .needsInput: return .needsInput
            default: return .running
            }
        }
        if let run {
            switch run.state {
            case .done: return .done
            case .failed: return .failed
            default: break
            }
        }
        switch ticket.anvilState {
        case "needs-input": return .needsInput
        case "failed": return .failed
        default: break
        }
        switch ticket.status {
        case "done": return .done
        case "closed": return .closed
        case "backlog": return .backlog
        default: break
        }
        if blocked.contains(ticket.id) { return .blocked }
        if ready.contains(ticket.id) { return .ready }
        return .open
    }
}
