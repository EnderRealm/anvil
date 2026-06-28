import XCTest
@testable import AnvilEngine
@testable import AnvilUI

final class TicketFilterTests: XCTestCase {

    private func ticket(_ id: String, status: String = "open", priority: Int = 2,
                        title: String? = nil, tags: [String] = [], anvilState: String? = nil) -> TicketSummary {
        TicketSummary(
            id: id, project: String(id.split(separator: "/").first ?? "p"),
            status: status, type: "feature", priority: priority, title: title ?? id,
            parent: nil, deps: [], tags: tags, anvilState: anvilState
        )
    }

    private func run(_ ticketID: String, _ state: RunState) -> RunModel {
        RunModel(id: RunID(), ticketID: ticketID, sessionID: "s", state: state,
                 cwd: URL(fileURLWithPath: "/tmp"), worktree: nil, discrepancy: nil, lastTkError: nil)
    }

    func testReadySelectionFiltersToReadyIDs() {
        let tickets = [ticket("p/a"), ticket("p/b"), ticket("p/c")]
        let visible = TicketFilter.visible(
            tickets: tickets, selection: .ready, search: "",
            ready: ["p/a", "p/c"], blocked: [], runsByTicket: [:])
        XCTAssertEqual(visible.map(\.id), ["p/a", "p/c"])
    }

    func testRunningSelectionUsesLiveRunState() {
        let tickets = [ticket("p/a"), ticket("p/b")]
        let runs = ["p/a": run("p/a", .running), "p/b": run("p/b", .done(summary: nil))]
        let visible = TicketFilter.visible(
            tickets: tickets, selection: .running, search: "",
            ready: [], blocked: [], runsByTicket: runs)
        XCTAssertEqual(visible.map(\.id), ["p/a"])
    }

    func testProjectSelectionAndSearch() {
        let tickets = [
            ticket("alpha/one", title: "Login flow"),
            ticket("alpha/two", title: "Logout"),
            ticket("beta/three", title: "Login beta"),
        ]
        let project = TicketFilter.visible(
            tickets: tickets, selection: .project("alpha"), search: "",
            ready: [], blocked: [], runsByTicket: [:])
        XCTAssertEqual(Set(project.map(\.id)), ["alpha/one", "alpha/two"])

        let searched = TicketFilter.visible(
            tickets: tickets, selection: .all, search: "login",
            ready: [], blocked: [], runsByTicket: [:])
        XCTAssertEqual(Set(searched.map(\.id)), ["alpha/one", "beta/three"])
    }

    func testInboxIncludesNeedsYouAndReady() {
        let tickets = [
            ticket("p/blocked-run"),
            ticket("p/signal", anvilState: "needs-input"),
            ticket("p/ready"),
            ticket("p/idle"),
        ]
        let runs = ["p/blocked-run": run("p/blocked-run", .needsInput(question: "?", options: []))]
        let visible = TicketFilter.visible(
            tickets: tickets, selection: .inbox, search: "",
            ready: ["p/ready"], blocked: [], runsByTicket: runs)
        XCTAssertEqual(Set(visible.map(\.id)), ["p/blocked-run", "p/signal", "p/ready"])
    }

    func testSortByPriorityThenTitle() {
        let tickets = [
            ticket("p/c", priority: 2, title: "C"),
            ticket("p/a", priority: 0, title: "A"),
            ticket("p/b", priority: 0, title: "B"),
        ]
        let visible = TicketFilter.visible(
            tickets: tickets, selection: .all, search: "",
            ready: [], blocked: [], runsByTicket: [:])
        XCTAssertEqual(visible.map(\.id), ["p/a", "p/b", "p/c"])
    }

    func testStatusKindPrecedence() {
        let base = ticket("p/x")
        // Live needs-input run wins over everything.
        XCTAssertEqual(
            StatusKind.of(ticket: base, run: run("p/x", .needsInput(question: "?", options: [])), ready: ["p/x"], blocked: []),
            .needsInput)
        // anvil-state signal when no active run.
        XCTAssertEqual(
            StatusKind.of(ticket: ticket("p/x", anvilState: "failed"), run: nil, ready: [], blocked: []),
            .failed)
        // ready/blocked derive from the sets.
        XCTAssertEqual(StatusKind.of(ticket: base, run: nil, ready: ["p/x"], blocked: []), .ready)
        XCTAssertEqual(StatusKind.of(ticket: base, run: nil, ready: [], blocked: ["p/x"]), .blocked)
        // terminal run.
        XCTAssertEqual(StatusKind.of(ticket: base, run: run("p/x", .done(summary: nil)), ready: [], blocked: []), .done)
    }
}
