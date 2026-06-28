import XCTest
@testable import AnvilEngine

final class RunSupervisorTests: XCTestCase {

    // Fully-cleared extras as the stub renders them (keys sorted, all values empty).
    private let clearedExtras =
        "anvil-host= --set anvil-question= --set anvil-session= --set anvil-state= --set anvil-worktree="
    // Failed extras: state=failed, the rest empty.
    private let failedExtras =
        "anvil-host= --set anvil-question= --set anvil-session= --set anvil-state=failed --set anvil-worktree="

    // Hermetic config so mirroring scopes by TICKETS_DIR=<dir>/store/tickets/<project>.
    private func makeSupervisor(
        claude: StubClaude,
        tk: StubTk,
        dir: URL,
        host: String = "test-host"
    ) throws -> RunSupervisor {
        let configURL = try writeTicketConfig([:], centralRoot: dir.appendingPathComponent("store"), in: dir)
        let engine = AnvilEngine(config: EngineConfig(claudeExecutableURL: claude.url))
        let client = TkClient(executableURL: tk.url)
        return RunSupervisor(engine: engine, tk: client, configURL: configURL, hostName: host)
    }

    private func ticketDirArg(_ dir: URL, _ project: String) -> String {
        "tdir=\(dir.appendingPathComponent("store").path)/tickets/\(project)"
    }

    // MARK: launch -> block

    func testLaunchBlockMirrorsToTicket() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sid = "sess-block-1"
        let claude = try makeStubClaude(in: dir, launchOutput: [
            initLine(sessionID: sid, cwd: dir.path),
            assistantLine("Thinking.", sessionID: sid),
            resultLine(needsInputBlock(question: "Which database engine", options: ["postgres", "sqlite"]), sessionID: sid),
        ].joined(separator: "\n"))
        let tk = try makeStubTk(in: dir)
        let supervisor = try makeSupervisor(claude: claude, tk: tk, dir: dir)

        let runID = try await supervisor.launch(ticketID: "demo/sample-block-1234", workdir: dir)
        try await waitUntil { await supervisor.pendingInputs().count == 1 }

        let pending = await supervisor.pendingInputs().first
        XCTAssertEqual(pending?.runID, runID)
        XCTAssertEqual(pending?.ticketID, "demo/sample-block-1234")
        XCTAssertEqual(pending?.sessionID, sid)
        XCTAssertEqual(pending?.question, "Which database engine")
        XCTAssertEqual(pending?.options, ["postgres", "sqlite"])
        XCTAssertEqual(pending?.cwd, dir)

        if case .needsInput? = await supervisor.model(for: runID)?.state {} else {
            XCTFail("expected model state .needsInput")
        }

        let tkLog = readLog(tk.argsLog)
        XCTAssertTrue(tkLog.contains("add-note sample-block-1234"), tkLog)
        XCTAssertTrue(tkLog.contains("anvil-state=needs-input"), tkLog)
        XCTAssertTrue(tkLog.contains("anvil-session=\(sid)"), tkLog)
        XCTAssertTrue(tkLog.contains("anvil-worktree=\(dir.path)"), tkLog)
        XCTAssertTrue(tkLog.contains("anvil-host=test-host"), tkLog)
        XCTAssertTrue(tkLog.contains("anvil-question=Which database engine"), tkLog)
        // Mirroring is scoped to the ticket's own project via TICKETS_DIR (keys sorted).
        XCTAssertTrue(tkLog.contains("add-note sample-block-1234 anvil: needs input — Which database engine | " + ticketDirArg(dir, "demo")), tkLog)
        XCTAssertTrue(tkLog.contains("--set anvil-worktree=\(dir.path) | " + ticketDirArg(dir, "demo")), tkLog)
        // tk addresses the bare slug, never the namespaced id.
        XCTAssertFalse(tkLog.contains("demo/sample-block-1234"), tkLog)

        // /work, by contrast, receives the namespaced id.
        let claudeLog = readLog(claude.argsLog)
        XCTAssertTrue(claudeLog.contains("/work demo/sample-block-1234"), claudeLog)
    }

    // MARK: answer -> resume -> done

    func testAnswerResumesAndCompletes() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sid = "sess-ad-1"
        let claude = try makeStubClaude(
            in: dir,
            launchOutput: [
                initLine(sessionID: sid, cwd: dir.path),
                resultLine(needsInputBlock(question: "Which database", options: ["postgres"]), sessionID: sid),
            ].joined(separator: "\n"),
            resumeOutput: [
                initLine(sessionID: sid, cwd: dir.path),
                resultLine(doneBlock(summary: "picked postgres"), sessionID: sid),
            ].joined(separator: "\n")
        )
        let tk = try makeStubTk(in: dir, showStatus: "done")
        let supervisor = try makeSupervisor(claude: claude, tk: tk, dir: dir)

        let runID = try await supervisor.launch(ticketID: "demo/sample-ad-5678", workdir: dir)
        try await waitUntil { await supervisor.pendingInputs().count == 1 }

        try await supervisor.answer(runID, text: "use postgres")
        try await waitUntil {
            if case .done? = await supervisor.model(for: runID)?.state { return true }
            return false
        }

        let model = await supervisor.model(for: runID)
        XCTAssertEqual(model?.state, .done(summary: "picked postgres"))
        XCTAssertNil(model?.discrepancy)
        XCTAssertNil(model?.lastTkError)
        let remaining = await supervisor.pendingInputs().count
        XCTAssertEqual(remaining, 0)

        let claudeLog = readLog(claude.argsLog)
        XCTAssertTrue(claudeLog.contains("--resume \(sid)"), claudeLog)

        let tkLog = readLog(tk.argsLog)
        // The done cross-check show is scoped to the ticket's project.
        XCTAssertTrue(tkLog.contains("show sample-ad-5678 | " + ticketDirArg(dir, "demo")), tkLog)
        XCTAssertTrue(tkLog.contains(clearedExtras + " | " + ticketDirArg(dir, "demo")), tkLog)
    }

    // MARK: done cross-check discrepancy

    func testDoneStatusDiscrepancyFlagged() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sid = "sess-disc-1"
        let claude = try makeStubClaude(in: dir, launchOutput: [
            initLine(sessionID: sid, cwd: dir.path),
            resultLine(doneBlock(summary: "claims done"), sessionID: sid),
        ].joined(separator: "\n"))
        // Run reports DONE but tk says the ticket is still open.
        let tk = try makeStubTk(in: dir, showStatus: "open")
        let supervisor = try makeSupervisor(claude: claude, tk: tk, dir: dir)

        let runID = try await supervisor.launch(ticketID: "demo/sample-disc-9012", workdir: dir)
        try await waitUntil {
            if case .done? = await supervisor.model(for: runID)?.state { return true }
            return false
        }

        let model = await supervisor.model(for: runID)
        XCTAssertNotNil(model?.discrepancy)
        XCTAssertTrue(model?.discrepancy?.contains("open") ?? false)

        let tkLog = readLog(tk.argsLog)
        XCTAssertTrue(tkLog.contains("show sample-disc-9012 | " + ticketDirArg(dir, "demo")), tkLog)
        XCTAssertTrue(tkLog.contains("WARNING"), tkLog)
    }

    // MARK: failed

    func testFailedRunMarksTicket() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sid = "sess-failed-1"
        let claude = try makeStubClaude(
            in: dir,
            launchOutput: [
                initLine(sessionID: sid, cwd: dir.path),
                assistantLine("Working.", sessionID: sid),
            ].joined(separator: "\n"),
            launchExit: 3
        )
        // tk status agrees the ticket is not done → no discrepancy.
        let tk = try makeStubTk(in: dir, showStatus: "open")
        let supervisor = try makeSupervisor(claude: claude, tk: tk, dir: dir)

        let runID = try await supervisor.launch(ticketID: "demo/sample-failed-3456", workdir: dir)
        try await waitUntil {
            if case .failed? = await supervisor.model(for: runID)?.state { return true }
            return false
        }

        let model = await supervisor.model(for: runID)
        XCTAssertNil(model?.discrepancy)
        let remaining = await supervisor.pendingInputs().count
        XCTAssertEqual(remaining, 0)
        let tkLog = readLog(tk.argsLog)
        XCTAssertTrue(tkLog.contains(failedExtras + " | " + ticketDirArg(dir, "demo")), tkLog)
        XCTAssertTrue(tkLog.contains("add-note sample-failed-3456"), tkLog)
        XCTAssertTrue(tkLog.contains("show sample-failed-3456 | " + ticketDirArg(dir, "demo")), tkLog)
    }

    func testFailedStatusDiscrepancyFlagged() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sid = "sess-faildisc-1"
        let claude = try makeStubClaude(
            in: dir,
            launchOutput: [
                initLine(sessionID: sid, cwd: dir.path),
                assistantLine("Working.", sessionID: sid),
            ].joined(separator: "\n"),
            launchExit: 3
        )
        // /work had set the ticket done, then the process exited nonzero — a discrepancy.
        let tk = try makeStubTk(in: dir, showStatus: "done")
        let supervisor = try makeSupervisor(claude: claude, tk: tk, dir: dir)

        let runID = try await supervisor.launch(ticketID: "demo/sample-faildisc-1212", workdir: dir)
        try await waitUntil {
            if case .failed? = await supervisor.model(for: runID)?.state { return true }
            return false
        }

        let model = await supervisor.model(for: runID)
        XCTAssertNotNil(model?.discrepancy)
        XCTAssertTrue(model?.discrepancy?.contains("done") ?? false)
        let tkLog = readLog(tk.argsLog)
        XCTAssertTrue(tkLog.contains("show sample-faildisc-1212"), tkLog)
        XCTAssertTrue(tkLog.contains("WARNING"), tkLog)
    }

    // MARK: canceled / stream ends without a terminal event

    func testCanceledBlockedRunSettlesAndClearsMarkers() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sid = "sess-cancel-1"
        let claude = try makeStubClaude(in: dir, launchOutput: [
            initLine(sessionID: sid, cwd: dir.path),
            resultLine(needsInputBlock(question: "Which database", options: ["postgres"]), sessionID: sid),
        ].joined(separator: "\n"))
        let tk = try makeStubTk(in: dir)
        let configURL = try writeTicketConfig([:], centralRoot: dir.appendingPathComponent("store"), in: dir)
        let engine = AnvilEngine(config: EngineConfig(claudeExecutableURL: claude.url))
        let supervisor = RunSupervisor(engine: engine, tk: TkClient(executableURL: tk.url), configURL: configURL, hostName: "test-host")

        let runID = try await supervisor.launch(ticketID: "demo/sample-cancel-2468", workdir: dir)
        try await waitUntil { await supervisor.pendingInputs().count == 1 }

        // Cancel finishes the engine stream with no terminal AnvilEvent.
        await engine.cancel(runID)

        try await waitUntil {
            if case .canceled? = await supervisor.model(for: runID)?.state { return true }
            return false
        }
        let remaining = await supervisor.pendingInputs().count
        XCTAssertEqual(remaining, 0)
        let tkLog = readLog(tk.argsLog)
        XCTAssertTrue(tkLog.contains(clearedExtras), tkLog)
        // Settle/clear is scoped to the ticket's project.
        XCTAssertTrue(tkLog.contains(ticketDirArg(dir, "demo")), tkLog)
    }

    // MARK: re-block re-marks; tk write failure is non-fatal

    func testReblockRemarksWithNewQuestion() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sid = "sess-reblock-1"
        let claude = try makeStubClaude(
            in: dir,
            launchOutput: [
                initLine(sessionID: sid, cwd: dir.path),
                resultLine(needsInputBlock(question: "Which database", options: ["postgres", "sqlite"]), sessionID: sid),
            ].joined(separator: "\n"),
            resumeOutput: [
                initLine(sessionID: sid, cwd: dir.path),
                resultLine(needsInputBlock(question: "Which migration tool", options: ["alembic", "flyway"]), sessionID: sid),
            ].joined(separator: "\n")
        )
        let tk = try makeStubTk(in: dir)
        let supervisor = try makeSupervisor(claude: claude, tk: tk, dir: dir)

        let runID = try await supervisor.launch(ticketID: "demo/sample-reblock-1313", workdir: dir)
        try await waitUntil { await supervisor.pendingInputs().first?.question == "Which database" }

        try await supervisor.answer(runID, text: "postgres")
        try await waitUntil { await supervisor.pendingInputs().first?.question == "Which migration tool" }

        let pending = await supervisor.pendingInputs().first
        XCTAssertEqual(pending?.question, "Which migration tool")
        XCTAssertEqual(pending?.options, ["alembic", "flyway"])

        let tkLog = readLog(tk.argsLog)
        XCTAssertTrue(tkLog.contains("anvil-question=Which database"), tkLog)
        XCTAssertTrue(tkLog.contains("anvil-question=Which migration tool"), tkLog)
    }

    func testTkWriteFailureRecordedNotFatal() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sid = "sess-tkfail-1"
        let claude = try makeStubClaude(in: dir, launchOutput: [
            initLine(sessionID: sid, cwd: dir.path),
            resultLine(needsInputBlock(question: "Which database", options: ["postgres"]), sessionID: sid),
        ].joined(separator: "\n"))
        // The first tk write (add-note) fails; the run must not be lost.
        let tk = try makeStubTk(in: dir, failVerb: "add-note")
        let supervisor = try makeSupervisor(claude: claude, tk: tk, dir: dir)

        let runID = try await supervisor.launch(ticketID: "demo/sample-tkfail-1414", workdir: dir)
        try await waitUntil {
            if case .needsInput? = await supervisor.model(for: runID)?.state { return true }
            return false
        }

        let model = await supervisor.model(for: runID)
        XCTAssertNotNil(model?.lastTkError)
        let pending = await supervisor.pendingInputs().count
        XCTAssertEqual(pending, 1)
    }

    // MARK: re-broadcast for F5

    func testEventsRebroadcastModel() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sid = "sess-rb-1"
        let claude = try makeStubClaude(in: dir, launchOutput: [
            initLine(sessionID: sid, cwd: dir.path),
            resultLine(doneBlock(summary: "ok"), sessionID: sid),
        ].joined(separator: "\n"))
        let tk = try makeStubTk(in: dir, showStatus: "done")
        let supervisor = try makeSupervisor(claude: claude, tk: tk, dir: dir)

        try await withTimeout {
            // Subscribe before launching so no events are missed.
            let stream = await supervisor.makeEventStream()
            let runID = try await supervisor.launch(ticketID: "demo/sample-rb-7890", workdir: dir)
            var sawDone = false
            for await event in stream {
                if case .runUpdated(let model) = event, model.id == runID,
                   case .done = model.state {
                    sawDone = true
                    break
                }
            }
            XCTAssertTrue(sawDone)
        }
    }

    func testFanOutDeliversToAllConsumers() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sid = "sess-fanout-1"
        let claude = try makeStubClaude(in: dir, launchOutput: [
            initLine(sessionID: sid, cwd: dir.path),
            resultLine(doneBlock(summary: "ok"), sessionID: sid),
        ].joined(separator: "\n"))
        let tk = try makeStubTk(in: dir, showStatus: "done")
        let supervisor = try makeSupervisor(claude: claude, tk: tk, dir: dir)

        try await withTimeout {
            // Two independent observers must each receive the terminal event.
            let first = await supervisor.makeEventStream()
            let second = await supervisor.makeEventStream()
            let runID = try await supervisor.launch(ticketID: "demo/sample-fanout-1515", workdir: dir)

            @Sendable func awaitDone(_ stream: AsyncStream<SupervisorEvent>) async -> Bool {
                for await event in stream {
                    if case .runUpdated(let model) = event, model.id == runID, case .done = model.state {
                        return true
                    }
                }
                return false
            }
            async let a = awaitDone(first)
            async let b = awaitDone(second)
            let results = await [a, b]
            XCTAssertEqual(results, [true, true])
        }
    }

    // MARK: live end-to-end (opt-in; mutates the real tk store, then cleans up)

    func testLiveEndToEnd() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["ANVIL_LIVE_E2E"] != nil,
            "set ANVIL_LIVE_E2E to exercise real claude + real tk end-to-end"
        )
        let engine = AnvilEngine(config: EngineConfig())
        let tk = TkClient()
        let supervisor = RunSupervisor(engine: engine, tk: tk)

        // Create a clearly-disposable throwaway ticket in the anvil project, with a contract
        // that forces a human decision so /work hits the block gate.
        let repo = try await engine.repoPath(forTicket: "anvil/placeholder")
        let create = try await ProcessSupport.run(
            executableURL: tk.executableURL,
            arguments: [
                "create", "THROWAWAY anvil live-e2e — delete me",
                "--type", "feature", "--status", "open",
                "-d", "Pick the database for the throwaway feature. You MUST ask the human to choose between 'postgres' and 'sqlite' before doing anything else; do not decide yourself.",
            ],
            cwd: repo
        )
        XCTAssertEqual(create.exitCode, 0, create.stderr)
        guard let bareID = TkClient.frontmatterValue("id", in: create.stdout) else {
            return XCTFail("could not read created ticket id from: \(create.stdout)")
        }
        defer {
            // Best-effort cleanup so the throwaway never lingers.
            let delete = Process()
            delete.executableURL = tk.executableURL
            delete.arguments = ["delete", bareID]
            delete.currentDirectoryURL = repo
            try? delete.run()
            delete.waitUntilExit()
        }

        let scratch = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let runID = try await supervisor.launch(ticketID: "anvil/\(bareID)", workdir: scratch)

        try await waitUntil(timeout: 240) {
            if await supervisor.pendingInputs().contains(where: { $0.runID == runID }) { return true }
            switch await supervisor.model(for: runID)?.state {
            case .done, .failed: return true
            default: return false
            }
        }

        guard let blocked = await supervisor.pendingInputs().first(where: { $0.runID == runID }) else {
            return XCTFail("expected the run to block for input; final state: \(String(describing: await supervisor.model(for: runID)?.state))")
        }
        XCTAssertFalse(blocked.question.isEmpty)

        try await supervisor.answer(runID, text: blocked.options.first ?? "postgres")
        try await waitUntil(timeout: 240) {
            switch await supervisor.model(for: runID)?.state {
            case .running, .needsInput, .done: return true
            default: return false
            }
        }
    }
}
