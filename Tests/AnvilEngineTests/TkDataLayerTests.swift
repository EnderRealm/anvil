import XCTest
@testable import AnvilEngine

final class TkDataLayerTests: XCTestCase {

    // MARK: parse()

    func testParseNamespacesIdsDepsAndParent() {
        let jsonl = [
            jsonLine(["id": "feature-a", "status": "open", "type": "feature", "priority": 1,
                      "title": "A", "deps": ["bug-b"], "tags": ["x", "y"]]),
            jsonLine(["id": "bug-b", "status": "done", "type": "bug", "priority": 2,
                      "title": "B", "parent": "epic-c"]),
        ].joined(separator: "\n")

        let tickets = TkDataLayer.parse(jsonl, project: "proj")
        XCTAssertEqual(tickets.map(\.id), ["proj/feature-a", "proj/bug-b"])
        XCTAssertEqual(tickets[0].project, "proj")
        XCTAssertEqual(tickets[0].deps, ["proj/bug-b"])      // bare dep namespaced to its project
        XCTAssertEqual(tickets[0].tags, ["x", "y"])
        XCTAssertEqual(tickets[1].parent, "proj/epic-c")     // bare parent namespaced
        XCTAssertEqual(tickets[1].status, "done")
    }

    func testParseKeepsCrossProjectNamespacedDeps() {
        let jsonl = jsonLine(["id": "feature-a", "status": "open", "type": "feature",
                              "priority": 1, "title": "A", "deps": ["other/dep-z"]])
        let tickets = TkDataLayer.parse(jsonl, project: "proj")
        XCTAssertEqual(tickets[0].deps, ["other/dep-z"])     // already namespaced, untouched
    }

    func testParseToleratesNullAndMissingLists() {
        // deps as explicit null, no tags/parent — the empty-list/null quirk.
        let line = #"{"id":"x-1","status":"open","type":"feature","priority":2,"title":"X","deps":null}"#
        let tickets = TkDataLayer.parse(line, project: "proj")
        XCTAssertEqual(tickets.count, 1)
        XCTAssertEqual(tickets[0].deps, [])
        XCTAssertEqual(tickets[0].tags, [])
        XCTAssertNil(tickets[0].parent)
        XCTAssertNil(tickets[0].anvilState)
    }

    func testParseReadsAnvilStateExtra() {
        let line = jsonLine(["id": "x-1", "status": "open", "type": "feature", "priority": 2,
                             "title": "X", "anvil-state": "needs-input"])
        let tickets = TkDataLayer.parse(line, project: "proj")
        XCTAssertEqual(tickets[0].anvilState, "needs-input")
    }

    // MARK: ready / blocked

    private func summary(_ id: String, _ status: String, deps: [String] = [], parent: String? = nil) -> TicketSummary {
        TicketSummary(
            id: id, project: String(id.split(separator: "/").first ?? "proj"),
            status: status, type: "feature", priority: 2, title: id,
            parent: parent, deps: deps, tags: [], anvilState: nil
        )
    }

    func testReadyBlockedActionability() {
        let tickets = [
            summary("proj/done", "done"),
            summary("proj/closedparent", "closed"),
            summary("proj/activeparent", "open"),
            summary("proj/a", "open"),                                   // ready: no deps, no parent
            summary("proj/b", "open", deps: ["proj/a"]),                 // blocked: dep a is open
            summary("proj/c", "open", deps: ["proj/done"]),             // ready: dep done
            summary("proj/d", "open", deps: ["proj/missing"]),          // blocked: missing dep
            summary("proj/e", "open", parent: "proj/closedparent"),     // neither: parent terminal
            summary("proj/f", "open", parent: "proj/activeparent"),     // ready: parent active
            summary("proj/bk", "backlog"),                              // excluded: backlog
        ]

        let result = TkDataLayer.readyBlocked(tickets)
        let ready = Set(result.ready.map(\.id))
        let blocked = Set(result.blocked.map(\.id))

        XCTAssertEqual(ready, ["proj/a", "proj/c", "proj/f", "proj/activeparent"])
        XCTAssertEqual(blocked, ["proj/b", "proj/d"])
        XCTAssertFalse(ready.contains("proj/e"))     // parent chain inactive
        XCTAssertFalse(ready.contains("proj/bk"))    // backlog excluded
        XCTAssertFalse(blocked.contains("proj/e"))
    }

    // MARK: storeInfo / projects(launchable:)

    func testStoreInfoLaunchableIsIntersection() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let central = dir.appendingPathComponent("store", isDirectory: true)
        let ticketsDir = central.appendingPathComponent("tickets", isDirectory: true)
        // Projects WITH tickets: proja, projb, ghost.
        for name in ["proja", "projb", "ghost"] {
            try FileManager.default.createDirectory(
                at: ticketsDir.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let repoA = dir.appendingPathComponent("repoA", isDirectory: true)
        let repoB = dir.appendingPathComponent("repoB", isDirectory: true)
        let repoP = dir.appendingPathComponent("repoPlanning", isDirectory: true)
        // Config: proja, projb (cloned + tickets) and planning (cloned, NO tickets).
        let configURL = try writeTicketConfig(
            ["proja": repoA, "projb": repoB, "planning": repoP], centralRoot: central, in: dir)

        let layer = TkDataLayer(tk: TkClient(executableURL: URL(fileURLWithPath: "/usr/bin/true")), configURL: configURL)

        let info = try await layer.storeInfo()
        XCTAssertEqual(info.centralRoot.path, central.path)

        let byName = Dictionary(uniqueKeysWithValues: info.projects.map { ($0.name, $0) })
        XCTAssertTrue(byName["proja"]?.launchable ?? false)
        XCTAssertTrue(byName["projb"]?.launchable ?? false)
        // ghost: tickets but no clone → browse-only.
        XCTAssertEqual(byName["ghost"]?.hasTickets, true)
        XCTAssertEqual(byName["ghost"]?.launchable, false)
        // planning: clone but no tickets → not launchable.
        XCTAssertEqual(byName["planning"]?.hasTickets, false)
        XCTAssertEqual(byName["planning"]?.launchable, false)

        let launchable = try await layer.projects(launchable: true).map(\.name)
        XCTAssertEqual(launchable, ["proja", "projb"])
    }

    // MARK: allTickets / tickets / inbox (via stub tk)

    func testAllTicketsAndInboxAcrossProjects() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let central = dir.appendingPathComponent("store", isDirectory: true)
        let ticketsDir = central.appendingPathComponent("tickets", isDirectory: true)
        for name in ["proja", "projb"] {
            try FileManager.default.createDirectory(
                at: ticketsDir.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let repoA = dir.appendingPathComponent("repoA", isDirectory: true)
        let repoB = dir.appendingPathComponent("repoB", isDirectory: true)
        try FileManager.default.createDirectory(at: repoA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoB, withIntermediateDirectories: true)
        let configURL = try writeTicketConfig(["proja": repoA, "projb": repoB], centralRoot: central, in: dir)

        // Same canned JSONL for both projects → ids namespaced per project prove multi-project.
        let jsonl = [
            jsonLine(["id": "alpha", "status": "open", "type": "feature", "priority": 1, "title": "Alpha"]),
            jsonLine(["id": "beta", "status": "open", "type": "bug", "priority": 2, "title": "Beta",
                      "anvil-state": "needs-input"]),
        ].joined(separator: "\n")
        let stub = try makeStubTk(in: dir, queryJSONL: jsonl)
        let layer = TkDataLayer(tk: TkClient(executableURL: stub.url), configURL: configURL)

        let all = try await layer.allTickets()
        XCTAssertEqual(Set(all.map(\.id)), ["proja/alpha", "proja/beta", "projb/alpha", "projb/beta"])

        let onlyA = try await layer.tickets(project: "proja")
        XCTAssertEqual(Set(onlyA.map(\.id)), ["proja/alpha", "proja/beta"])

        // inbox surfaces only the anvil-state tickets.
        let inbox = try await layer.inbox()
        XCTAssertEqual(Set(inbox.map(\.id)), ["proja/beta", "projb/beta"])

        // query was scoped per project ticket dir (TICKETS_DIR), not --repo.
        let log = readLog(stub.argsLog)
        XCTAssertTrue(log.contains("query tdir=\(central.path)/tickets/proja"), log)
        XCTAssertTrue(log.contains("query tdir=\(central.path)/tickets/projb"), log)
    }

    func testAllTicketsCoversStoreOnlyProjectAndCrossProjectDep() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let central = dir.appendingPathComponent("store", isDirectory: true)
        let ticketsDir = central.appendingPathComponent("tickets", isDirectory: true)
        // "cloned" has a repo path; "storeonly" has tickets but no clone.
        for name in ["cloned", "storeonly"] {
            try FileManager.default.createDirectory(
                at: ticketsDir.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let repoCloned = dir.appendingPathComponent("repoCloned", isDirectory: true)
        try FileManager.default.createDirectory(at: repoCloned, withIntermediateDirectories: true)
        // Only "cloned" is in config; "storeonly" is store-only.
        let configURL = try writeTicketConfig(["cloned": repoCloned], centralRoot: central, in: dir)

        // cloned/feature depends on storeonly/done-dep (which is done) → should be ready.
        let clonedJSONL = jsonLine([
            "id": "feature", "status": "open", "type": "feature", "priority": 1,
            "title": "Feature", "deps": ["storeonly/done-dep"],
        ])
        let storeonlyJSONL = jsonLine([
            "id": "done-dep", "status": "done", "type": "bug", "priority": 2, "title": "Dep",
        ])
        let stub = try makeStubTk(in: dir, queryByProject: [
            "cloned": clonedJSONL, "storeonly": storeonlyJSONL,
        ])
        let layer = TkDataLayer(tk: TkClient(executableURL: stub.url), configURL: configURL)

        // Browse covers BOTH projects, including the store-only one.
        let all = try await layer.allTickets()
        XCTAssertEqual(Set(all.map(\.id)), ["cloned/feature", "storeonly/done-dep"])

        // The cross-project dep is done, so the dependent is ready (not blocked).
        let ready = try await layer.ready().map(\.id)
        let blocked = try await layer.blocked().map(\.id)
        XCTAssertTrue(ready.contains("cloned/feature"), "ready=\(ready)")
        XCTAssertFalse(blocked.contains("cloned/feature"), "blocked=\(blocked)")
    }

    // MARK: live (opt-in) — real tk, hermetic store (no echo chamber)

    private func runTkLive(_ args: [String], cwd: URL, home: URL) async throws -> ProcessSupport.Output {
        try await ProcessSupport.run(
            executableURL: TkClient.resolveTkOnPath(), arguments: args, cwd: cwd,
            environment: ["HOME": home.path]
        )
    }

    func testLiveDataLayerReadsRealTk() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["ANVIL_LIVE_TK"] != nil,
            "set ANVIL_LIVE_TK to read real tk output through the data layer"
        )
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = dir.appendingPathComponent("home", isDirectory: true)
        let central = dir.appendingPathComponent("store", isDirectory: true)
        let repo = dir.appendingPathComponent("repo", isDirectory: true)
        for d in [home, repo] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        try git(["init", "-q"], in: repo)
        try git(["config", "user.email", "t@e.com"], in: repo)
        try git(["config", "user.name", "T"], in: repo)

        let initOut = try await runTkLive(
            ["init", "--project", "liveproj", "--central-root", central.path, "--yes"], cwd: repo, home: home)
        XCTAssertEqual(initOut.exitCode, 0, initOut.stderr)
        let createOut = try await runTkLive(["create", "Live ticket", "--type", "feature"], cwd: repo, home: home)
        XCTAssertEqual(createOut.exitCode, 0, createOut.stderr)
        let bare = try XCTUnwrap(TkClient.frontmatterValue("id", in: createOut.stdout))
        _ = try await runTkLive(["edit", bare, "--set", "anvil-state=needs-input", "--status", "open"], cwd: repo, home: home)

        // Real tk via the data layer (query scoped by TICKETS_DIR, config read from hermetic HOME).
        let configURL = home.appendingPathComponent(".ticket/config.yaml")
        let layer = TkDataLayer(tk: TkClient(), configURL: configURL)

        let all = try await layer.allTickets()
        let ticket = try XCTUnwrap(all.first { $0.id == "liveproj/\(bare)" }, "ids=\(all.map(\.id))")
        XCTAssertEqual(ticket.status, "open")
        XCTAssertEqual(ticket.anvilState, "needs-input")

        let inbox = try await layer.inbox()
        XCTAssertTrue(inbox.contains { $0.id == "liveproj/\(bare)" }, "inbox=\(inbox.map(\.id))")
    }

    // MARK: writes route to the bare slug + project repo

    func testWritesUseBareSlugAndRepoScope() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repoA = dir.appendingPathComponent("repoA", isDirectory: true)
        try FileManager.default.createDirectory(at: repoA, withIntermediateDirectories: true)
        let configURL = try writeTicketConfig(["proja": repoA], in: dir)
        let stub = try makeStubTk(in: dir)
        let layer = TkDataLayer(tk: TkClient(executableURL: stub.url), configURL: configURL)

        try await layer.setStatus(ticketID: "proja/alpha-1234", "open")
        try await layer.addNote(ticketID: "proja/alpha-1234", text: "hi")

        let log = readLog(stub.argsLog)
        XCTAssertTrue(log.contains("edit alpha-1234 --status open --repo \(repoA.path)"), log)
        XCTAssertTrue(log.contains("add-note alpha-1234 hi --repo \(repoA.path)"), log)
        XCTAssertFalse(log.contains("proja/alpha-1234"), log)
    }
}
