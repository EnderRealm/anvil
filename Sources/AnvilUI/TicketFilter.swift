import AnvilEngine

/// Pure filtering/sorting for the ticket list — the load-bearing list logic, kept out of the
/// views so it can be tested directly.
public enum TicketFilter {
    public static func visible(
        tickets: [TicketSummary],
        selection: SidebarSelection,
        search: String,
        ready: Set<String>,
        blocked: Set<String>,
        runsByTicket: [String: RunModel]
    ) -> [TicketSummary] {
        var list = tickets

        switch selection {
        case .all:
            break
        case .ready:
            list = list.filter { ready.contains($0.id) }
        case .running:
            list = list.filter { runsByTicket[$0.id]?.state.isActive ?? false }
        case .inbox:
            list = list.filter { isInbox($0, run: runsByTicket[$0.id], ready: ready) }
        case .project(let name):
            list = list.filter { $0.project == name }
        }

        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            list = list.filter { ticket in
                ticket.title.lowercased().contains(query)
                    || ticket.id.lowercased().contains(query)
                    || ticket.tags.contains { $0.lowercased().contains(query) }
            }
        }

        return list.sorted(by: order)
    }

    /// Inbox first cut (F6 builds the full triage surface): things that need you — a blocked-on-
    /// human run or the `anvil-state` signal — plus what's ready to pick up.
    public static func isInbox(_ ticket: TicketSummary, run: RunModel?, ready: Set<String>) -> Bool {
        if let run {
            if case .needsInput = run.state { return true }
            if case .failed = run.state { return true }
        }
        if ticket.anvilState == "needs-input" || ticket.anvilState == "failed" { return true }
        return ready.contains(ticket.id)
    }

    // Lower priority number = more important; then title for stable order.
    private static func order(_ a: TicketSummary, _ b: TicketSummary) -> Bool {
        if a.priority != b.priority { return a.priority < b.priority }
        return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
    }
}
