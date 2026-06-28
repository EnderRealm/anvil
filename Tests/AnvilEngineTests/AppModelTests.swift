import XCTest
@testable import AnvilEngine
@testable import AnvilUI

@MainActor
final class AppModelTests: XCTestCase {

    // Build a temp central store + config + stub tk; returns (dir, configURL, central).
    private func makeStore(
        projectsWithTickets: [String],
        configProjects: [String: URL],
        queryJSONL: String,
        in dir: URL
    ) throws -> (configURL: URL, stub: StubTk) {
        let central = dir.appendingPathComponent("store", isDirectory: true)
        let ticketsDir = central.appendingPathComponent("tickets", isDirectory: true)
        for name in projectsWithTickets {
            try FileManager.default.createDirectory(
                at: ticketsDir.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let configURL = try writeTicketConfig(configProjects, centralRoot: central, in: dir)
        let stub = try makeStubTk(in: dir, showStatus: "open", queryJSONL: queryJSONL)
        return (configURL, stub)
    }

    func testRefreshLoadsTicketsProjectsAndCounts() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = dir.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let jsonl = [
            jsonLine(["id": "ready-1", "status": "open", "type": "feature", "priority": 1, "title": "Ready one"]),
            jsonLine(["id": "back-1", "status": "backlog", "type": "bug", "priority": 2, "title": "Backlog one"]),
        ].joined(separator: "\n")
        let store = try makeStore(projectsWithTickets: ["p"], configProjects: ["p": repo], queryJSONL: jsonl, in: dir)

        let dataLayer = TkDataLayer(tk: TkClient(executableURL: store.stub.url), configURL: store.configURL)
        let engine = AnvilEngine(config: EngineConfig(claudeExecutableURL: store.stub.url))
        let model = AppModel(dataLayer: dataLayer, supervisor: RunSupervisor(engine: engine, tk: TkClient(executableURL: store.stub.url)))

        await model.refresh()

        XCTAssertEqual(Set(model.tickets.map(\.id)), ["p/ready-1", "p/back-1"])
        XCTAssertEqual(model.projects.map(\.name), ["p"])
        XCTAssertEqual(model.counts.all, 2)
        XCTAssertEqual(model.counts.ready, 1)            // ready-1 only (back-1 is backlog)
        XCTAssertTrue(model.readyIDs.contains("p/ready-1"))

        model.selection = .ready
        XCTAssertEqual(model.visibleTickets.map(\.id), ["p/ready-1"])
    }

    func testLaunchableGating() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = dir.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let jsonl = jsonLine(["id": "x", "status": "open", "type": "feature", "priority": 1, "title": "X"])
        // "p" is cloned (config), "ghost" has tickets but no config repo path.
        let store = try makeStore(
            projectsWithTickets: ["p", "ghost"], configProjects: ["p": repo], queryJSONL: jsonl, in: dir)

        let dataLayer = TkDataLayer(tk: TkClient(executableURL: store.stub.url), configURL: store.configURL)
        let engine = AnvilEngine(config: EngineConfig(claudeExecutableURL: store.stub.url))
        let model = AppModel(dataLayer: dataLayer, supervisor: RunSupervisor(engine: engine, tk: TkClient(executableURL: store.stub.url)))
        await model.refresh()

        XCTAssertTrue(model.isLaunchable("p"))
        XCTAssertFalse(model.isLaunchable("ghost"))
        let pTicket = try XCTUnwrap(model.tickets.first { $0.id == "p/x" })
        let ghostTicket = try XCTUnwrap(model.tickets.first { $0.id == "ghost/x" })
        XCTAssertTrue(model.canLaunch(pTicket))
        XCTAssertFalse(model.canLaunch(ghostTicket))
    }

    func testLaunchReachesNeedsInputThenAnswerCompletes() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try makeGitRepo(in: dir)
        let jsonl = jsonLine(["id": "feat-1", "status": "open", "type": "feature", "priority": 1, "title": "Feature one"])
        let store = try makeStore(projectsWithTickets: ["p"], configProjects: ["p": repo], queryJSONL: jsonl, in: dir)

        let sid = "sess-app-1"
        let claude = try makeStubClaude(
            in: dir,
            launchOutput: [
                initLine(sessionID: sid, cwd: repo.path),
                resultLine(needsInputBlock(question: "Which DB?", options: ["postgres"]), sessionID: sid),
            ].joined(separator: "\n"),
            resumeOutput: [
                initLine(sessionID: sid, cwd: repo.path),
                resultLine(doneBlock(summary: "picked postgres"), sessionID: sid),
            ].joined(separator: "\n")
        )
        let dataLayer = TkDataLayer(tk: TkClient(executableURL: store.stub.url), configURL: store.configURL)
        let engine = AnvilEngine(config: EngineConfig(claudeExecutableURL: claude.url, ticketConfigURL: store.configURL))
        let supervisor = RunSupervisor(
            engine: engine, tk: TkClient(executableURL: store.stub.url),
            worktrees: WorktreeManager(worktreeRoot: dir.appendingPathComponent("wt")), cleanupPolicy: .keep)
        let model = AppModel(dataLayer: dataLayer, supervisor: supervisor)

        await model.start(watch: false)
        model.select("p/feat-1")
        await model.launch("p/feat-1")

        let blocked = await waitForState(model, "p/feat-1", timeout: 15) { if case .needsInput = $0 { return true }; return false }
        XCTAssertTrue(blocked, "run should reach needsInput")
        XCTAssertEqual(model.counts.running, 1)

        await model.answerSelected(text: "postgres")
        let done = await waitForState(model, "p/feat-1", timeout: 15) { if case .done = $0 { return true }; return false }
        XCTAssertTrue(done, "run should reach done after answer")

        model.stop()
    }

    func testFailingLaunchSurfacesError() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try makeGitRepo(in: dir)
        let jsonl = jsonLine(["id": "feat-1", "status": "open", "type": "feature", "priority": 1, "title": "F"])
        let store = try makeStore(projectsWithTickets: ["p"], configProjects: ["p": repo], queryJSONL: jsonl, in: dir)

        // Engine points at a non-existent claude — launch must fail and surface a user error.
        let missingClaude = dir.appendingPathComponent("no-such-claude")
        let engine = AnvilEngine(config: EngineConfig(claudeExecutableURL: missingClaude, ticketConfigURL: store.configURL))
        let supervisor = RunSupervisor(
            engine: engine, tk: TkClient(executableURL: store.stub.url),
            worktrees: WorktreeManager(worktreeRoot: dir.appendingPathComponent("wt")), cleanupPolicy: .keep)
        let model = AppModel(
            dataLayer: TkDataLayer(tk: TkClient(executableURL: store.stub.url), configURL: store.configURL),
            supervisor: supervisor)

        XCTAssertNil(model.lastError)
        await model.launch("p/feat-1")
        XCTAssertNotNil(model.lastError, "a failing launch must set a user-visible error")

        model.dismissError()
        XCTAssertNil(model.lastError)
    }

    private func waitForState(_ model: AppModel, _ ticketID: String, timeout: Double, _ predicate: (RunState) -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if let state = model.runsByTicket[ticketID]?.state, predicate(state) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }
}
