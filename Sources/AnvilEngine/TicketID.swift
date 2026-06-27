import Foundation

// Splitting a namespaced ticket id (`project/slug`) into its parts. The engine speaks the
// namespaced form; the tk CLI and the worktree layout use the bare slug / project.
enum TicketID {
    static func slug(_ ticketID: String) -> String {
        ticketID.split(separator: "/").last.map(String.init) ?? ticketID
    }

    static func project(_ ticketID: String) -> String {
        let parts = ticketID.split(separator: "/")
        return parts.count >= 2 ? String(parts[0]) : "local"
    }
}
