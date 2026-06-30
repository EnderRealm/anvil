import XCTest
@testable import AnvilEngine

final class AnvilEngineTests: XCTestCase {

    // MARK: 1. needs-input

    func testNeedsInputCleanBlock() async throws {
        try await runNeedsInput(preamble: nil)
    }

    func testNeedsInputWithProsePreamble() async throws {
        // Opus prepends reasoning before the sentinel — the parser must still find it.
        try await runNeedsInput(preamble: "I weighed the tradeoffs and need a call here.")
    }

    private func runNeedsInput(preamble: String?) async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sid = "sess-needs-1"
        let result = needsInputBlock(
            question: "Which database?",
            options: ["postgres", "sqlite"],
            preamble: preamble
        )
        let output = [
            initLine(sessionID: sid, cwd: dir.path),
            assistantLine("Looking into it.", sessionID: sid),
            resultLine(result, sessionID: sid),
        ].joined(separator: "\n")
        let stub = try makeStubClaude(in: dir, launchOutput: output)
        let engine = AnvilEngine(config: EngineConfig(claudeExecutableURL: stub.url))

        try await withTimeout {
            let handle = try await engine.launch(ticketID: "demo/x", workdir: dir)
            var iterator = handle.events.makeAsyncIterator()
            var sawStarted = false
            var question: String?
            var options: [String] = []
            while let event = await iterator.next() {
                switch event {
                case .started: sawStarted = true
                case .needsInput(let q, let o): question = q; options = o
                default: break
                }
                if question != nil { break }
            }
            XCTAssertTrue(sawStarted, "expected a .started before .needsInput")
            XCTAssertEqual(question, "Which database?")
            XCTAssertEqual(options, ["postgres", "sqlite"])
            let state = await engine.state(for: handle.id)
            XCTAssertEqual(state, .needsInput(question: "Which database?", options: ["postgres", "sqlite"]))
        }

        let loggedArgs = try String(contentsOf: stub.argsLog, encoding: .utf8)
        XCTAssertTrue(loggedArgs.contains("/work demo/x"), "launched with the work prompt")
        XCTAssertTrue(loggedArgs.contains("--append-system-prompt"))
        XCTAssertTrue(loggedArgs.contains("stream-json"))
        // Autonomous runs need Bash tool permissions (build/test) — bypassPermissions by default.
        XCTAssertTrue(loggedArgs.contains("--permission-mode bypassPermissions"), loggedArgs)
    }

    // MARK: 2. done

    func testDoneRun() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sid = "sess-done-1"
        let output = [
            initLine(sessionID: sid, cwd: dir.path),
            assistantLine("Shipping it.", sessionID: sid),
            resultLine(doneBlock(summary: "Implemented the feature"), sessionID: sid),
        ].joined(separator: "\n")
        let stub = try makeStubClaude(in: dir, launchOutput: output)
        let engine = AnvilEngine(config: EngineConfig(claudeExecutableURL: stub.url))

        try await withTimeout {
            let handle = try await engine.launch(ticketID: "demo/x", workdir: dir)
            var summary: String?
            var done = false
            for await event in handle.events {
                if case .done(let s) = event { summary = s; done = true }
            }
            XCTAssertTrue(done)
            XCTAssertEqual(summary, "Implemented the feature")
            let state = await engine.state(for: handle.id)
            XCTAssertEqual(state, .done(summary: "Implemented the feature"))
        }
    }

    // MARK: 3. failed

    func testFailedViaNonzeroExit() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sid = "sess-fail-1"
        let output = [
            initLine(sessionID: sid, cwd: dir.path),
            assistantLine("Trying...", sessionID: sid),
        ].joined(separator: "\n")
        let stub = try makeStubClaude(in: dir, launchOutput: output, launchExit: 3)
        let engine = AnvilEngine(config: EngineConfig(claudeExecutableURL: stub.url))

        try await withTimeout {
            let handle = try await engine.launch(ticketID: "demo/x", workdir: dir)
            var failure: EngineError?
            for await event in handle.events {
                if case .failed(let error) = event { failure = error }
            }
            guard case .processFailed(_, let code)? = failure else {
                return XCTFail("expected .processFailed, got \(String(describing: failure))")
            }
            XCTAssertEqual(code, 3)
            let state = await engine.state(for: handle.id)
            if case .failed? = state {} else { XCTFail("expected .failed state, got \(String(describing: state))") }
        }
    }

    func testFailedViaIsError() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sid = "sess-fail-2"
        let output = [
            initLine(sessionID: sid, cwd: dir.path),
            resultLine("boom", sessionID: sid, isError: true),
        ].joined(separator: "\n")
        let stub = try makeStubClaude(in: dir, launchOutput: output)
        let engine = AnvilEngine(config: EngineConfig(claudeExecutableURL: stub.url))

        try await withTimeout {
            let handle = try await engine.launch(ticketID: "demo/x", workdir: dir)
            var failure: EngineError?
            for await event in handle.events {
                if case .failed(let error) = event { failure = error }
            }
            guard case .agentFailed? = failure else {
                return XCTFail("expected .agentFailed, got \(String(describing: failure))")
            }
        }
    }

    func testNonzeroExitVetoesCleanDone() async throws {
        // A clean DONE block but a nonzero exit must still fail — the exit code wins.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sid = "sess-fail-3"
        let output = [
            initLine(sessionID: sid, cwd: dir.path),
            resultLine(doneBlock(summary: "looks done"), sessionID: sid),
        ].joined(separator: "\n")
        let stub = try makeStubClaude(in: dir, launchOutput: output, launchExit: 2)
        let engine = AnvilEngine(config: EngineConfig(claudeExecutableURL: stub.url))

        try await withTimeout {
            let handle = try await engine.launch(ticketID: "demo/x", workdir: dir)
            var failure: EngineError?
            for await event in handle.events {
                if case .failed(let error) = event { failure = error }
                if case .done = event { return XCTFail("nonzero exit should veto a clean done") }
            }
            guard case .processFailed(_, let code)? = failure else {
                return XCTFail("expected .processFailed, got \(String(describing: failure))")
            }
            XCTAssertEqual(code, 2)
            let state = await engine.state(for: handle.id)
            if case .failed? = state {} else { XCTFail("expected .failed state, got \(String(describing: state))") }
        }
    }

    func testFailedViaTerminalReason() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sid = "sess-fail-4"
        let output = [
            initLine(sessionID: sid, cwd: dir.path),
            resultLine(doneBlock(summary: "n/a"), sessionID: sid, terminalReason: "max_turns"),
        ].joined(separator: "\n")
        let stub = try makeStubClaude(in: dir, launchOutput: output)
        let engine = AnvilEngine(config: EngineConfig(claudeExecutableURL: stub.url))

        try await withTimeout {
            let handle = try await engine.launch(ticketID: "demo/x", workdir: dir)
            var failure: EngineError?
            for await event in handle.events {
                if case .failed(let error) = event { failure = error }
                if case .done = event { return XCTFail("terminal_reason != completed should fail") }
            }
            guard case .agentFailed(let reason)? = failure else {
                return XCTFail("expected .agentFailed, got \(String(describing: failure))")
            }
            XCTAssertTrue(reason.contains("max_turns"))
        }
    }

    func testMalformedSentinelFails() async throws {
        // A NEEDS_INPUT marker with unparseable JSON must fail, not be marked done.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sid = "sess-malformed-1"
        let brokenBlock = """
        \(Sentinel.needsInputMarker)
        {"question": "broken" "options": [oops]}
        \(Sentinel.endMarker)
        """
        let output = [
            initLine(sessionID: sid, cwd: dir.path),
            resultLine(brokenBlock, sessionID: sid),
        ].joined(separator: "\n")
        let stub = try makeStubClaude(in: dir, launchOutput: output)
        let engine = AnvilEngine(config: EngineConfig(claudeExecutableURL: stub.url))

        try await withTimeout {
            let handle = try await engine.launch(ticketID: "demo/x", workdir: dir)
            var failure: EngineError?
            for await event in handle.events {
                if case .failed(let error) = event { failure = error }
                if case .done = event { return XCTFail("malformed sentinel should not be done") }
            }
            XCTAssertEqual(failure, .malformedSentinel)
        }
    }

    func testUsageCarriesCostTokensAndRateLimit() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sid = "sess-usage-1"
        let output = [
            initLine(sessionID: sid, cwd: dir.path),
            rateLimitLine(sessionID: sid),
            resultLine(doneBlock(summary: "ok"), sessionID: sid, cost: 0.042),
        ].joined(separator: "\n")
        let stub = try makeStubClaude(in: dir, launchOutput: output)
        let engine = AnvilEngine(config: EngineConfig(claudeExecutableURL: stub.url))

        try await withTimeout {
            let handle = try await engine.launch(ticketID: "demo/x", workdir: dir)
            var usages: [Usage] = []
            for await event in handle.events {
                if case .usage(let usage) = event { usages.append(usage) }
            }
            // The rate_limit_event carries window info.
            let rateUsage = usages.first { $0.rateLimit != nil }
            XCTAssertEqual(rateUsage?.rateLimit?.rateLimitType, "five_hour")
            XCTAssertEqual(rateUsage?.rateLimit?.status, "allowed")
            XCTAssertEqual(rateUsage?.rateLimit?.overageStatus, "none")
            XCTAssertEqual(rateUsage?.rateLimit?.isUsingOverage, false)
            // The result carries cost + token counts.
            let costUsage = usages.first { $0.totalCostUSD != nil }
            XCTAssertEqual(costUsage?.totalCostUSD, 0.042)
            XCTAssertEqual(costUsage?.inputTokens, 120)
            XCTAssertEqual(costUsage?.outputTokens, 45)
        }
    }

    func testResumeRejectsNonBlockedRun() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sid = "sess-guard-1"
        let output = [
            initLine(sessionID: sid, cwd: dir.path),
            resultLine(doneBlock(summary: "done"), sessionID: sid),
        ].joined(separator: "\n")
        let stub = try makeStubClaude(in: dir, launchOutput: output)
        let engine = AnvilEngine(config: EngineConfig(claudeExecutableURL: stub.url))

        try await withTimeout {
            let handle = try await engine.launch(ticketID: "demo/x", workdir: dir)
            for await event in handle.events {
                if case .done = event { break }
            }
            do {
                try await engine.resume(handle.id, answer: "too late")
                XCTFail("expected runNotResumable")
            } catch let error as EngineError {
                XCTAssertEqual(error, .runNotResumable(handle.id))
            }
        }
    }

    // MARK: 4. resume

    func testResumeReachesDoneOnSameSession() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sid = "sess-resume-1"
        let launch = [
            initLine(sessionID: sid, cwd: dir.path),
            assistantLine("I need a decision.", sessionID: sid),
            resultLine(needsInputBlock(question: "Which database?", options: ["postgres", "sqlite"]), sessionID: sid),
        ].joined(separator: "\n")
        let resumeOut = [
            initLine(sessionID: sid, cwd: dir.path),
            assistantLine("Resuming with your answer.", sessionID: sid),
            resultLine(doneBlock(summary: "Picked postgres"), sessionID: sid),
        ].joined(separator: "\n")
        let stub = try makeStubClaude(in: dir, launchOutput: launch, resumeOutput: resumeOut)
        let engine = AnvilEngine(config: EngineConfig(claudeExecutableURL: stub.url))

        try await withTimeout {
            let handle = try await engine.launch(ticketID: "demo/x", workdir: dir)
            var iterator = handle.events.makeAsyncIterator()

            var blocked = false
            while let event = await iterator.next() {
                if case .needsInput = event { blocked = true; break }
            }
            XCTAssertTrue(blocked)
            let sessionBefore = await engine.sessionID(for: handle.id)
            XCTAssertEqual(sessionBefore, sid)

            try await engine.resume(handle.id, answer: "use postgres")

            var summary: String?
            var done = false
            while let event = await iterator.next() {
                if case .done(let s) = event { summary = s; done = true; break }
                if case .failed(let e) = event { return XCTFail("resume failed: \(e)") }
            }
            XCTAssertTrue(done)
            XCTAssertEqual(summary, "Picked postgres")
            let sessionAfter = await engine.sessionID(for: handle.id)
            XCTAssertEqual(sessionAfter, sid)
            let state = await engine.state(for: handle.id)
            XCTAssertEqual(state, .done(summary: "Picked postgres"))
        }

        let loggedArgs = try String(contentsOf: stub.argsLog, encoding: .utf8)
        XCTAssertTrue(loggedArgs.contains("--resume \(sid)"), "resume passed the session id")
        // Resume must also carry tool permissions so a re-run can build/test. Both the launch
        // and resume invocations are logged, so assert it appears at least twice.
        let permissionOccurrences = loggedArgs.components(separatedBy: "--permission-mode bypassPermissions").count - 1
        XCTAssertGreaterThanOrEqual(permissionOccurrences, 2, "launch AND resume must carry --permission-mode bypassPermissions; log:\n\(loggedArgs)")
    }

    // MARK: 5. repo resolution

    func testRepoResolution() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = dir.appendingPathComponent("demo-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

        let yaml = """
        central_root: /tmp/store
        projects:
            demo:
                path: \(repo.path)
                auto_link: false
                auto_close: false
            other:
                path: /tmp/other
        """
        let configURL = dir.appendingPathComponent("config.yaml")
        try yaml.write(to: configURL, atomically: true, encoding: .utf8)

        let engine = AnvilEngine(config: EngineConfig(
            claudeExecutableURL: URL(fileURLWithPath: "/usr/bin/true"),
            ticketConfigURL: configURL
        ))

        let resolved = try await engine.repoPath(forTicket: "demo/some-ticket-1234")
        XCTAssertEqual(resolved.path, repo.path)

        do {
            _ = try await engine.repoPath(forTicket: "ghost/x-1")
            XCTFail("expected projectNotLaunchableOnThisHost")
        } catch let error as EngineError {
            XCTAssertEqual(error, .projectNotLaunchableOnThisHost("ghost"))
        }

        do {
            _ = try await engine.repoPath(forTicket: "noproject")
            XCTFail("expected invalidTicketID")
        } catch let error as EngineError {
            XCTAssertEqual(error, .invalidTicketID("noproject"))
        }
    }

    // MARK: debug log

    func testDebugLogCapturesRawStreamAndSpawn() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sid = "sess-debug-1"
        let output = [
            initLine(sessionID: sid, cwd: dir.path),
            resultLine(doneBlock(summary: "done"), sessionID: sid),
        ].joined(separator: "\n")
        let stub = try makeStubClaude(in: dir, launchOutput: output)
        let logURL = dir.appendingPathComponent("debug.log")
        let engine = AnvilEngine(config: EngineConfig(
            claudeExecutableURL: stub.url,
            debugLogURL: logURL
        ))

        try await withTimeout {
            let handle = try await engine.launch(ticketID: "demo/x", workdir: dir)
            for await event in handle.events {
                if case .done = event { break }
            }
        }

        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("# spawn:"), "logs the spawned argv + cwd")
        XCTAssertTrue(log.contains("/work demo/x"))
        XCTAssertTrue(log.contains("\"type\":\"system\""), "logs raw stdout lines verbatim")
        XCTAssertTrue(log.contains("# exit:"))
    }

    // MARK: Live smoke (opt-in)

    func testLiveSmoke() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["ANVIL_LIVE_TEST"] != nil,
            "set ANVIL_LIVE_TEST to exercise the real claude binary"
        )
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = AnvilEngine(config: EngineConfig())

        try await withTimeout(90) {
            // A clearly-bogus ticket: we only need spawn + stream-json parse to reach
            // .started, then cancel before the agent does meaningful work.
            let handle = try await engine.launch(
                ticketID: "anvil/anvil-live-smoke-does-not-exist-0000",
                workdir: dir
            )
            var sessionID: String?
            for await event in handle.events {
                if case .started(let sid, _, _) = event {
                    sessionID = sid
                    await engine.cancel(handle.id)
                    break
                }
                if case .failed = event { break }
                if case .done = event { break }
            }
            XCTAssertNotNil(sessionID)
            XCTAssertFalse(sessionID?.isEmpty ?? true)
        }
    }
}
