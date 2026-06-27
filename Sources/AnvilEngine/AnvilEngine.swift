import Foundation

/// Headless core: spawns supervised `claude -p` runs, parses their `stream-json` output into
/// `AnvilEvent`s, and exposes a command-in / event-stream-out surface. No UI dependencies.
public actor AnvilEngine {
    private let config: EngineConfig
    private var runs: [RunID: RunContext] = [:]

    public init(config: EngineConfig = EngineConfig()) {
        self.config = config
    }

    // MARK: - Commands

    /// Launch `/work <ticketID>` as a supervised run. When `workdir` is nil it is resolved
    /// from the ticket's project via `~/.ticket/config.yaml`; when provided it is used
    /// verbatim (this is how F2 will hand in a worktree).
    public func launch(ticketID: String, workdir: URL? = nil) throws -> RunHandle {
        let cwd = try workdir ?? repoPath(forTicket: ticketID)
        try validateExecutable()

        let id = RunID()
        var continuation: AsyncStream<AnvilEvent>.Continuation!
        let stream = AsyncStream<AnvilEvent> { continuation = $0 }
        let run = RunContext(id: id, stream: stream, continuation: continuation, cwd: cwd)
        runs[id] = run

        try startProcess(run: run, arguments: launchArguments(ticketID: ticketID))
        return RunHandle(id: id, events: stream, engine: self)
    }

    /// Continue a blocked run with the human's answer: `claude -p --resume <session_id>`
    /// from the same cwd, feeding events into the same stream.
    public func resume(_ run: RunID, answer: String) throws {
        guard let ctx = runs[run] else { throw EngineError.runNotFound(run) }
        // Only a run waiting for input can be resumed — guards against orphan/second processes.
        guard case .needsInput = ctx.state else { throw EngineError.runNotResumable(run) }
        guard let sessionID = ctx.sessionID else { throw EngineError.noSessionID(run) }
        try validateExecutable()

        ctx.pending = nil
        ctx.state = .running
        try startProcess(run: ctx, arguments: resumeArguments(sessionID: sessionID, answer: answer))
    }

    /// Terminate the run's process. The run settles into `.canceled`.
    public func cancel(_ run: RunID) {
        guard let ctx = runs[run] else { return }
        switch ctx.state {
        case .done, .failed, .canceled: return
        default: break
        }
        ctx.canceled = true
        if let process = ctx.process, process.isRunning {
            process.terminate()
        } else {
            ctx.state = .canceled
            ctx.continuation.finish()
        }
    }

    public func state(for run: RunID) -> RunState? { runs[run]?.state }

    public func sessionID(for run: RunID) -> String? { runs[run]?.sessionID }

    /// Resolve a ticket's project to its local repo path. Throws
    /// `projectNotLaunchableOnThisHost` when the project has no local clone here.
    public func repoPath(forTicket ticketID: String) throws -> URL {
        let project = try Self.project(fromTicketID: ticketID)
        guard let yaml = try? String(contentsOf: config.ticketConfigURL, encoding: .utf8) else {
            throw EngineError.ticketConfigUnreadable(config.ticketConfigURL.path)
        }
        guard let path = RepoResolver.repoPath(forProject: project, inYAML: yaml) else {
            throw EngineError.projectNotLaunchableOnThisHost(project)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: - Process supervision

    private func validateExecutable() throws {
        let path = config.claudeExecutableURL.path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw EngineError.claudeExecutableNotFound(path)
        }
    }

    private func launchArguments(ticketID: String) -> [String] {
        [
            "-p", "/work \(ticketID)",
            "--append-system-prompt", config.headlessContract,
            "--output-format", "stream-json",
            "--verbose",
            "--model", config.model,
            "--permission-mode", config.permissionMode,
        ]
    }

    private func resumeArguments(sessionID: String, answer: String) -> [String] {
        [
            "-p", answer,
            "--resume", sessionID,
            "--append-system-prompt", config.headlessContract,
            "--output-format", "stream-json",
            "--verbose",
            "--model", config.model,
            "--permission-mode", config.permissionMode,
        ]
    }

    private func startProcess(run: RunContext, arguments: [String]) throws {
        let process = Process()
        process.executableURL = config.claudeExecutableURL
        process.arguments = arguments
        process.currentDirectoryURL = run.cwd
        process.environment = ProcessInfo.processInfo.environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        debugLog("# spawn: \(config.claudeExecutableURL.path) \(arguments) cwd=\(run.cwd.path)")

        do {
            try process.run()
        } catch {
            let engineError = EngineError.processSpawnFailed(error.localizedDescription)
            fail(run, engineError)
            throw engineError
        }

        run.process = process
        run.state = .running

        let id = run.id
        Task.detached { [weak self] in
            await self?.supervise(process: process, stdout: stdout, stderr: stderr, runID: id)
        }
    }

    // Off-actor: drain the pipes (concurrently, to avoid a full-buffer deadlock), then hand
    // the exit code back to the actor. Reads are event-driven (`readabilityHandler`) so no
    // pooled thread is ever held blocked — blocking reads here starve concurrent runs.
    nonisolated private func supervise(process: Process, stdout: Pipe, stderr: Pipe, runID: RunID) async {
        let stderrTask = Task<String, Never> {
            var collected: [String] = []
            for await line in Self.lines(of: stderr.fileHandleForReading) { collected.append(line) }
            return collected.joined(separator: "\n")
        }

        for await line in Self.lines(of: stdout.fileHandleForReading) {
            await self.ingest(line: line, runID: runID)
        }

        let stderrText = await stderrTask.value
        let exitCode = await Self.waitForExit(process)
        await self.completeProcess(runID: runID, exitCode: exitCode, stderr: stderrText)
    }

    // Accumulates pipe bytes and emits whole lines. Touched only from a FileHandle's serial
    // readability queue, hence `@unchecked Sendable`.
    private final class LineBuffer: @unchecked Sendable {
        private var buffer = Data()
        func append(_ data: Data) -> [String] {
            buffer.append(data)
            var lines: [String] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(String(decoding: buffer.subdata(in: buffer.startIndex..<newline), as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            return lines
        }
        func flush() -> String? {
            guard !buffer.isEmpty else { return nil }
            defer { buffer.removeAll() }
            return String(decoding: buffer, as: UTF8.self)
        }
    }

    // Event-driven, ordered, newline-delimited line stream over a pipe.
    nonisolated private static func lines(of handle: FileHandle) -> AsyncStream<String> {
        AsyncStream<String> { continuation in
            let state = LineBuffer()
            handle.readabilityHandler = { fh in
                let data = fh.availableData
                if data.isEmpty {
                    fh.readabilityHandler = nil
                    if let tail = state.flush() { continuation.yield(tail) }
                    continuation.finish()
                    return
                }
                for line in state.append(data) { continuation.yield(line) }
            }
            // Release the read end deterministically rather than waiting on ARC.
            continuation.onTermination = { _ in
                handle.readabilityHandler = nil
                try? handle.close()
            }
        }
    }

    // `Process.waitUntilExit()` blocks; run it on a dedicated thread so it never competes for
    // a pooled worker. One short-lived thread per active run.
    nonisolated private static func waitForExit(_ process: Process) async -> Int32 {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            let thread = Thread {
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus)
            }
            thread.start()
        }
    }

    // MARK: - Event ingestion

    private func ingest(line: String, runID: RunID) {
        guard let run = runs[runID] else { return }
        debugLog(line)

        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(StreamLine.self, from: data),
              let type = parsed.type
        else { return }

        switch type {
        case "system" where parsed.subtype == "init":
            if let sid = parsed.session_id { run.sessionID = sid }
            run.state = .running
            run.continuation.yield(.started(
                sessionID: run.sessionID ?? "",
                model: parsed.model ?? config.model,
                cwd: parsed.cwd ?? run.cwd.path
            ))

        case "assistant":
            if let text = parsed.message?.text, !text.isEmpty {
                run.continuation.yield(.output(text))
            }

        case "rate_limit_event":
            run.continuation.yield(.usage(Usage(rateLimit: parsed.rate_limit_info)))

        case "result":
            if let sid = parsed.session_id { run.sessionID = sid }
            if parsed.total_cost_usd != nil || parsed.usage != nil {
                run.continuation.yield(.usage(Usage(
                    inputTokens: parsed.usage?.input_tokens,
                    outputTokens: parsed.usage?.output_tokens,
                    totalCostUSD: parsed.total_cost_usd
                )))
            }
            run.pending = resolveResult(parsed)

        default:
            break
        }
    }

    private func resolveResult(_ line: StreamLine) -> PendingOutcome {
        if line.is_error == true {
            return .failure(.agentFailed(line.result ?? "is_error"))
        }
        if let reason = line.terminal_reason, reason != "completed" {
            return .failure(.agentFailed("terminal_reason: \(reason)"))
        }
        switch Sentinel.parse(line.result ?? "") {
        case .value(.needsInput(let question, let options)):
            return .needsInput(question: question, options: options)
        case .value(.done(let summary)):
            return .done(summary: summary)
        case .malformed:
            // A marker was present but its JSON did not parse — never treat a blocked turn
            // as done. Fail loudly.
            return .failure(.malformedSentinel)
        case .none:
            // No sentinel: treat as done for now. F3 cross-checks tk status to confirm.
            return .done(summary: nil)
        }
    }

    private func completeProcess(runID: RunID, exitCode: Int32, stderr: String) {
        guard let run = runs[runID] else { return }
        run.process = nil
        debugLog("# exit: run=\(runID) code=\(exitCode)")

        if run.canceled {
            run.state = .canceled
            run.continuation.finish()
            return
        }
        switch run.state {
        case .done, .failed, .canceled: return
        default: break
        }

        let pending = run.pending
        run.pending = nil
        let exitFailed = exitCode != 0

        // A nonzero exit vetoes any clean-looking result, including needs-input.
        switch pending {
        case .needsInput(let question, let options):
            if exitFailed {
                fail(run, .processFailed(reason: stderr.isEmpty ? "exited \(exitCode)" : stderr, exitCode: exitCode))
            } else {
                // Turn ended with a question — keep the stream open for `resume`.
                run.state = .needsInput(question: question, options: options)
                run.continuation.yield(.needsInput(question: question, options: options))
            }

        case .done(let summary):
            if exitFailed {
                fail(run, .processFailed(reason: stderr.isEmpty ? "exited \(exitCode)" : stderr, exitCode: exitCode))
            } else {
                run.state = .done(summary: summary)
                run.continuation.yield(.done(summary: summary))
                run.continuation.finish()
            }

        case .failure(let error):
            fail(run, error)

        case nil:
            if exitFailed {
                fail(run, .processFailed(reason: stderr.isEmpty ? "exited \(exitCode)" : stderr, exitCode: exitCode))
            } else {
                run.state = .done(summary: nil)
                run.continuation.yield(.done(summary: nil))
                run.continuation.finish()
            }
        }
    }

    private func fail(_ run: RunContext, _ error: EngineError) {
        run.state = .failed(error.description)
        run.continuation.yield(.failed(error))
        run.continuation.finish()
    }

    // MARK: - Helpers

    static func project(fromTicketID ticketID: String) throws -> String {
        let parts = ticketID.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else {
            throw EngineError.invalidTicketID(ticketID)
        }
        return String(parts[0])
    }

    // Append-only debug log: raw stdout lines verbatim, meta lines prefixed `#`, for replay.
    private func debugLog(_ message: String) {
        guard let url = config.debugLogURL else { return }
        let line = message.hasSuffix("\n") ? message : message + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}
