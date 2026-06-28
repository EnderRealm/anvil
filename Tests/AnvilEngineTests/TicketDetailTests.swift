import XCTest
@testable import AnvilEngine

final class TicketDetailTests: XCTestCase {

    private let show = """
    ---
    id: child-feature-ea4b
    status: open
    deps: [proj/dep-1, proj/dep-2]
    links: []
    created: 2026-06-27T23:37:23
    updated: 2026-06-27T23:37:25
    type: feature
    priority: 1
    parent: proj/epic-1
    tags: [a, b]
    ---
    # Child feature

    The why of this ticket.
    Second line.

    ## Acceptance Criteria

    It works end to end.

    ## Notes

    **2026-06-27T19:33:28Z**

    First note.

    **2026-06-28T10:00:00Z**

    Second note.
    """

    func testParseDetailFrontmatterAndBody() {
        let detail = TkDataLayer.parseDetail(show, id: "proj/child-feature-ea4b")
        XCTAssertEqual(detail.id, "proj/child-feature-ea4b")
        XCTAssertEqual(detail.project, "proj")
        XCTAssertEqual(detail.title, "Child feature")
        XCTAssertEqual(detail.status, "open")
        XCTAssertEqual(detail.type, "feature")
        XCTAssertEqual(detail.priority, 1)
        XCTAssertEqual(detail.parent, "proj/epic-1")
        XCTAssertEqual(detail.deps, ["proj/dep-1", "proj/dep-2"])
        XCTAssertEqual(detail.tags, ["a", "b"])
        XCTAssertEqual(detail.description, "The why of this ticket.\nSecond line.")
        XCTAssertEqual(detail.acceptanceCriteria, "It works end to end.")
        XCTAssertNil(detail.design)
        XCTAssertEqual(detail.notes, ["First note.", "Second note."])
    }

    func testParseDetailMinimalTicket() {
        let minimal = """
        ---
        id: bare-1
        status: backlog
        deps: []
        links: []
        type: bug
        priority: 2
        ---
        # Bare ticket

        Just a description.
        """
        let detail = TkDataLayer.parseDetail(minimal, id: "proj/bare-1")
        XCTAssertEqual(detail.title, "Bare ticket")
        XCTAssertEqual(detail.description, "Just a description.")
        XCTAssertNil(detail.acceptanceCriteria)
        XCTAssertEqual(detail.deps, [])
        XCTAssertEqual(detail.tags, [])
        XCTAssertNil(detail.parent)
        XCTAssertEqual(detail.notes, [])
    }

    func testParseBodySplitsSections() {
        let body = """
        # Title

        Description here.

        ## Design

        Use an actor.

        ## Notes

        **ts**

        a note
        """
        let parsed = TkDataLayer.parseBody(body)
        XCTAssertEqual(parsed.title, "Title")
        XCTAssertEqual(parsed.description, "Description here.")
        XCTAssertEqual(parsed.sections.map(\.heading), ["Design", "Notes"])
        XCTAssertEqual(parsed.sections.first?.body, "Use an actor.")
    }

    func testParseNotesWithoutMarkersIsSingleNote() {
        XCTAssertEqual(TkDataLayer.parseNotes("plain note body"), ["plain note body"])
        XCTAssertEqual(TkDataLayer.parseNotes("   "), [])
    }

    // Regression: priority decodes from tk-query JSONL across the full 0-4 scale (0 = critical
    // is a real value, never collapsed; a missing key falls back to 2, NOT 0).
    func testPriorityRoundTripsIncludingCritical() {
        let jsonl = [
            #"{"id":"crit","status":"open","type":"feature","priority":0,"title":"Critical"}"#,
            #"{"id":"low","status":"open","type":"feature","priority":4,"title":"Low"}"#,
            #"{"id":"missing","status":"open","type":"feature","title":"No priority key"}"#,
        ].joined(separator: "\n")
        let tickets = TkDataLayer.parse(jsonl, project: "p")
        XCTAssertEqual(tickets.first { $0.id == "p/crit" }?.priority, 0)
        XCTAssertEqual(tickets.first { $0.id == "p/low" }?.priority, 4)
        XCTAssertEqual(tickets.first { $0.id == "p/missing" }?.priority, 2)  // default, NOT 0
    }
}
