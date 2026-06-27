import XCTest
@testable import AnvilEngine

final class WorktreeManagerTests: XCTestCase {

    // MARK: WorktreeManager unit

    func testCreateMakesPreparedWorktree() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try makeGitRepo(in: dir)
        let root = dir.appendingPathComponent("worktrees", isDirectory: true)
        let manager = WorktreeManager(worktreeRoot: root)

        let worktree = try await manager.create(ticketID: "proj/slug-abcd", repoURL: repo)

        XCTAssertEqual(worktree.branch, "anvil/slug-abcd")
        XCTAssertTrue(worktree.path.path.hasSuffix("/proj/slug-abcd"), worktree.path.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path.path))

        // checked out on the anvil branch
        let listed = try await manager.list(repoURL: repo)
        XCTAssertTrue(listed.contains { $0.branch == "anvil/slug-abcd" }, "\(listed)")

        // .env symlinked into the worktree, pointing at the source repo's .env
        let envDest = worktree.path.appendingPathComponent(".env")
        let attrs = try FileManager.default.attributesOfItem(atPath: envDest.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink)
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: envDest.path)
        XCTAssertEqual(target, repo.appendingPathComponent(".env").path)

        // prepare hook ran (touched the marker, cwd = worktree)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path.appendingPathComponent("prepared.marker").path))
    }

    func testCleanupRemovesWorktreeKeepsBranch() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try makeGitRepo(in: dir)
        let manager = WorktreeManager(worktreeRoot: dir.appendingPathComponent("worktrees"))
        let worktree = try await manager.create(ticketID: "proj/slug-clean", repoURL: repo)

        try await manager.cleanup(worktree)

        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.path.path))
        let listed = try await manager.list(repoURL: repo)
        XCTAssertFalse(listed.contains { $0.branch == "anvil/slug-clean" }, "\(listed)")
        // branch retained by default
        let branches = try runGit(["branch", "--list", "anvil/slug-clean"], cwd: repo)
        XCTAssertTrue(branches.output.contains("anvil/slug-clean"), branches.output)
    }

    func testRelaunchReusesExistingBranch() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try makeGitRepo(in: dir)
        let manager = WorktreeManager(worktreeRoot: dir.appendingPathComponent("worktrees"))

        let first = try await manager.create(ticketID: "proj/slug-relaunch", repoURL: repo)
        try await manager.cleanup(first)  // keeps the branch

        // Relaunch: the branch already exists; create must not crash.
        let second = try await manager.create(ticketID: "proj/slug-relaunch", repoURL: repo)
        XCTAssertEqual(second.branch, "anvil/slug-relaunch")
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path.appendingPathComponent("prepared.marker").path))
    }

    func testPrepareFailureTearsDownAndRelaunchPrepares() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try makeGitRepo(in: dir)
        let root = dir.appendingPathComponent("worktrees")

        // A prepare command that fails must abort create and leave no worktree behind.
        let failing = WorktreeManager(
            worktreeRoot: root,
            prepare: WorktreePrepareConfig(prepareCommand: ["/bin/sh", "-c", "exit 7"])
        )
        do {
            _ = try await failing.create(ticketID: "proj/slug-prep", repoURL: repo)
            XCTFail("expected prepare failure")
        } catch is WorktreeError {
            // expected
        }
        let path = failing.worktreePath(forTicket: "proj/slug-prep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        let listedAfterFail = try await failing.list(repoURL: repo)
        XCTAssertFalse(listedAfterFail.contains { $0.branch == "anvil/slug-prep" }, "\(listedAfterFail)")

        // Relaunch with a working prepare → fully-prepared worktree, no half-baked reuse.
        let working = WorktreeManager(worktreeRoot: root)
        let worktree = try await working.create(ticketID: "proj/slug-prep", repoURL: repo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path.appendingPathComponent("prepared.marker").path))
        let attrs = try FileManager.default.attributesOfItem(atPath: worktree.path.appendingPathComponent(".env").path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink)
    }

    func testCleanupIsIdempotent() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try makeGitRepo(in: dir)
        let manager = WorktreeManager(worktreeRoot: dir.appendingPathComponent("worktrees"))
        let worktree = try await manager.create(ticketID: "proj/slug-idem", repoURL: repo)

        try await manager.cleanup(worktree)
        // A second cleanup of the same (already-removed) worktree must not throw.
        try await manager.cleanup(worktree)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.path.path))
    }

    func testRejectsUnsafeSymlinkPath() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try makeGitRepo(in: dir)
        let manager = WorktreeManager(
            worktreeRoot: dir.appendingPathComponent("worktrees"),
            prepare: WorktreePrepareConfig(symlinkPaths: ["../escape"])
        )
        do {
            _ = try await manager.create(ticketID: "proj/slug-unsafe", repoURL: repo)
            XCTFail("expected invalidSymlinkPath")
        } catch let error as WorktreeError {
            guard case .invalidSymlinkPath = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
        // The freshly-added worktree was torn down on the prepare failure.
        let path = manager.worktreePath(forTicket: "proj/slug-unsafe")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    // MARK: Supervisor integration

    private func makeWorktreeSupervisor(
        claude: StubClaude,
        tk: StubTk,
        configURL: URL,
        root: URL,
        cleanupPolicy: WorktreeCleanup
    ) -> RunSupervisor {
        let engine = AnvilEngine(config: EngineConfig(
            claudeExecutableURL: claude.url,
            ticketConfigURL: configURL
        ))
        return RunSupervisor(
            engine: engine,
            tk: TkClient(executableURL: tk.url),
            worktrees: WorktreeManager(worktreeRoot: root),
            cleanupPolicy: cleanupPolicy,
            hostName: "test-host"
        )
    }

    func testLaunchBlockSetsRealWorktreeExtra() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try makeGitRepo(in: dir)
        let configURL = try writeTicketConfig(["proj": repo], in: dir)
        let root = dir.appendingPathComponent("worktrees")
        let sid = "sess-wt-block"
        let claude = try makeStubClaude(in: dir, launchOutput: [
            initLine(sessionID: sid, cwd: repo.path),
            resultLine(needsInputBlock(question: "Which database", options: ["postgres"]), sessionID: sid),
        ].joined(separator: "\n"))
        let tk = try makeStubTk(in: dir)
        let supervisor = makeWorktreeSupervisor(claude: claude, tk: tk, configURL: configURL, root: root, cleanupPolicy: .keep)

        let runID = try await supervisor.launch(ticketID: "proj/slug-wtb-1234", workdir: nil)
        try await waitUntil { await supervisor.pendingInputs().count == 1 }

        let model = await supervisor.model(for: runID)
        let worktree = try XCTUnwrap(model?.worktree)
        XCTAssertEqual(worktree.branch, "anvil/slug-wtb-1234")
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path.path))
        let firstCwd = await supervisor.pendingInputs().first?.cwd
        XCTAssertEqual(firstCwd, worktree.path)

        // The break-glass pointer is the real worktree path.
        let tkLog = readLog(tk.argsLog)
        XCTAssertTrue(tkLog.contains("anvil-worktree=\(worktree.path.path)"), tkLog)
    }

    func testOnSuccessCleanupRemovesWorktreeAfterDone() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try makeGitRepo(in: dir)
        let configURL = try writeTicketConfig(["proj": repo], in: dir)
        let root = dir.appendingPathComponent("worktrees")
        let sid = "sess-wt-success"
        let claude = try makeStubClaude(
            in: dir,
            launchOutput: [
                initLine(sessionID: sid, cwd: repo.path),
                resultLine(needsInputBlock(question: "Which database", options: ["postgres"]), sessionID: sid),
            ].joined(separator: "\n"),
            resumeOutput: [
                initLine(sessionID: sid, cwd: repo.path),
                resultLine(doneBlock(summary: "done"), sessionID: sid),
            ].joined(separator: "\n")
        )
        let tk = try makeStubTk(in: dir, showStatus: "done")
        let supervisor = makeWorktreeSupervisor(claude: claude, tk: tk, configURL: configURL, root: root, cleanupPolicy: .onSuccess)

        let runID = try await supervisor.launch(ticketID: "proj/slug-wts-5678", workdir: nil)
        try await waitUntil { await supervisor.pendingInputs().count == 1 }
        let blockedModel = await supervisor.model(for: runID)
        let worktree = try XCTUnwrap(blockedModel?.worktree)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path.path))

        try await supervisor.answer(runID, text: "postgres")
        try await waitUntil {
            if case .done? = await supervisor.model(for: runID)?.state { return true }
            return false
        }
        // onSuccess removed the worktree after .done
        try await waitUntil { !FileManager.default.fileExists(atPath: worktree.path.path) }
        let listed = try await WorktreeManager(worktreeRoot: root).list(repoURL: repo)
        XCTAssertFalse(listed.contains { $0.branch == worktree.branch }, "\(listed)")
    }

    func testKeepLeavesWorktreeAfterDone() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try makeGitRepo(in: dir)
        let configURL = try writeTicketConfig(["proj": repo], in: dir)
        let root = dir.appendingPathComponent("worktrees")
        let sid = "sess-wt-keep"
        let claude = try makeStubClaude(in: dir, launchOutput: [
            initLine(sessionID: sid, cwd: repo.path),
            resultLine(doneBlock(summary: "done"), sessionID: sid),
        ].joined(separator: "\n"))
        let tk = try makeStubTk(in: dir, showStatus: "done")
        let supervisor = makeWorktreeSupervisor(claude: claude, tk: tk, configURL: configURL, root: root, cleanupPolicy: .keep)

        let runID = try await supervisor.launch(ticketID: "proj/slug-wtk-9012", workdir: nil)
        try await waitUntil {
            if case .done? = await supervisor.model(for: runID)?.state { return true }
            return false
        }
        let doneModel = await supervisor.model(for: runID)
        let worktree = try XCTUnwrap(doneModel?.worktree)
        // keep policy leaves it on disk, cleanable on demand
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path.path))

        try await supervisor.cleanupWorktree(runID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.path.path))
    }

    func testConcurrentLaunchesUseDistinctWorktrees() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repoA = try makeGitRepo(in: dir)
        let repoB = try makeGitRepo(in: dir)
        let configURL = try writeTicketConfig(["proja": repoA, "projb": repoB], in: dir)
        let root = dir.appendingPathComponent("worktrees")
        let claude = try makeStubClaude(in: dir, launchOutput: [
            initLine(sessionID: "sess-conc", cwd: dir.path),
            resultLine(doneBlock(summary: "done"), sessionID: "sess-conc"),
        ].joined(separator: "\n"))
        let tk = try makeStubTk(in: dir, showStatus: "done")
        let supervisor = makeWorktreeSupervisor(claude: claude, tk: tk, configURL: configURL, root: root, cleanupPolicy: .keep)

        async let a = supervisor.launch(ticketID: "proja/slug-aaaa", workdir: nil)
        async let b = supervisor.launch(ticketID: "projb/slug-bbbb", workdir: nil)
        let runA = try await a
        let runB = try await b

        try await waitUntil {
            if case .done? = await supervisor.model(for: runA)?.state,
               case .done? = await supervisor.model(for: runB)?.state { return true }
            return false
        }

        let modelA = await supervisor.model(for: runA)
        let modelB = await supervisor.model(for: runB)
        let wtA = try XCTUnwrap(modelA?.worktree)
        let wtB = try XCTUnwrap(modelB?.worktree)
        XCTAssertNotEqual(wtA.path, wtB.path)
        XCTAssertEqual(wtA.branch, "anvil/slug-aaaa")
        XCTAssertEqual(wtB.branch, "anvil/slug-bbbb")
        XCTAssertTrue(wtA.path.path.contains("/proja/"))
        XCTAssertTrue(wtB.path.path.contains("/projb/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: wtA.path.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: wtB.path.path))

        let listedA = try await WorktreeManager(worktreeRoot: root).list(repoURL: repoA)
        let listedB = try await WorktreeManager(worktreeRoot: root).list(repoURL: repoB)
        XCTAssertEqual(listedA.map(\.branch), ["anvil/slug-aaaa"])
        XCTAssertEqual(listedB.map(\.branch), ["anvil/slug-bbbb"])
    }
}
