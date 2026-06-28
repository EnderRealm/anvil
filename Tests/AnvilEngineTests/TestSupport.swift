import Foundation
import XCTest
@testable import AnvilEngine

// MARK: - Stub claude

struct StubClaude {
    let url: URL
    let argsLog: URL
}

/// Write a `#!/bin/sh` stub that emits canned stream-json. When `resumeOutput` is set the
/// stub branches on `--resume`, so a single stub drives a launch->resume sequence.
func makeStubClaude(
    in dir: URL,
    launchOutput: String,
    launchExit: Int32 = 0,
    resumeOutput: String? = nil,
    resumeExit: Int32 = 0
) throws -> StubClaude {
    let scriptURL = dir.appendingPathComponent("claude-stub")
    let argsLog = dir.appendingPathComponent("stub-args.log")

    var resumeBlock = ""
    if let resumeOutput {
        resumeBlock = """
        if [ "$resume" = "1" ]; then
        cat <<'ANVIL_RESUME_EOF'
        \(resumeOutput)
        ANVIL_RESUME_EOF
        exit \(resumeExit)
        fi
        """
    }

    let script = """
    #!/bin/sh
    printf '%s\\n' "args: $*" >> "\(argsLog.path)"
    printf '%s\\n' "cwd: $PWD" >> "\(argsLog.path)"
    resume=0
    for a in "$@"; do
      [ "$a" = "--resume" ] && resume=1
    done
    \(resumeBlock)
    cat <<'ANVIL_EOF'
    \(launchOutput)
    ANVIL_EOF
    exit \(launchExit)
    """

    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    return StubClaude(url: scriptURL, argsLog: argsLog)
}

// MARK: - Canned stream-json lines

func jsonLine(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

func initLine(sessionID: String, model: String = "opus", cwd: String = "/tmp") -> String {
    jsonLine([
        "type": "system", "subtype": "init",
        "session_id": sessionID, "model": model, "cwd": cwd, "apiKeySource": "none",
    ])
}

func assistantLine(_ text: String, sessionID: String) -> String {
    jsonLine([
        "type": "assistant", "session_id": sessionID,
        "message": ["content": [["type": "text", "text": text]]],
    ])
}

func resultLine(
    _ resultText: String,
    sessionID: String,
    isError: Bool = false,
    terminalReason: String = "completed",
    cost: Double = 0.012
) -> String {
    jsonLine([
        "type": "result",
        "subtype": isError ? "error_during_execution" : "success",
        "session_id": sessionID,
        "result": resultText,
        "is_error": isError,
        "terminal_reason": terminalReason,
        "total_cost_usd": cost,
        "usage": ["input_tokens": 120, "output_tokens": 45],
    ])
}

func rateLimitLine(
    sessionID: String,
    rateLimitType: String = "five_hour",
    status: String = "allowed",
    overageStatus: String = "none",
    resetsAt: Double = 1_750_000_000
) -> String {
    jsonLine([
        "type": "rate_limit_event",
        "session_id": sessionID,
        "rate_limit_info": [
            "rateLimitType": rateLimitType,
            "status": status,
            "overageStatus": overageStatus,
            "isUsingOverage": false,
            "resetsAt": resetsAt,
        ],
    ])
}

func needsInputBlock(question: String, options: [String], preamble: String? = nil) -> String {
    let optionsJSON = options.map { "\"\($0)\"" }.joined(separator: ", ")
    let block = """
    \(Sentinel.needsInputMarker)
    {"question": "\(question)", "options": [\(optionsJSON)]}
    \(Sentinel.endMarker)
    """
    if let preamble { return preamble + "\n" + block }
    return block
}

func doneBlock(summary: String) -> String {
    """
    \(Sentinel.doneMarker)
    {"summary": "\(summary)"}
    \(Sentinel.endMarker)
    """
}

// MARK: - Async helpers

struct TimeoutError: Error {}

/// Run `op` with a wall-clock ceiling so a misbehaving run can't hang the suite.
func withTimeout(_ seconds: Double = 20, _ op: @escaping @Sendable () async throws -> Void) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        try await group.next()
        group.cancelAll()
    }
}

func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("anvil-tests-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Poll `condition` until it holds or the timeout fires.
func waitUntil(timeout: Double = 15, _ condition: @escaping @Sendable () async -> Bool) async throws {
    try await withTimeout(timeout) {
        while !(await condition()) {
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
    }
}

// MARK: - Stub tk

struct StubTk {
    let url: URL
    let argsLog: URL
}

/// Write a `#!/bin/sh` stub mirroring real `tk`: records argv (and `TICKETS_DIR` for `query`),
/// emits YAML frontmatter for `show`, and JSONL for `query`. `queryJSONL` returns the same
/// JSONL for any store; `queryByProject` (keyed by the `TICKETS_DIR` basename) returns
/// per-project JSONL. When `failVerb` is set, that subcommand exits nonzero.
func makeStubTk(
    in dir: URL,
    showStatus: String = "done",
    showExit: Int32 = 0,
    failVerb: String? = nil,
    failExit: Int32 = 1,
    queryJSONL: String? = nil,
    queryByProject: [String: String]? = nil
) throws -> StubTk {
    let scriptURL = dir.appendingPathComponent("tk-stub")
    let argsLog = dir.appendingPathComponent("tk-args.log")

    var failBlock = ""
    if let failVerb {
        failBlock = """
        if [ "$1" = "\(failVerb)" ]; then
        printf 'tk stub: forced failure for %s\\n' "\(failVerb)" 1>&2
        exit \(failExit)
        fi
        """
    }

    var emit = ""
    if let queryByProject {
        for (project, jsonl) in queryByProject.sorted(by: { $0.key < $1.key }) {
            emit += """
            if [ "$base" = "\(project)" ]; then
            cat <<'TK_Q_\(project)_EOF'
            \(jsonl)
            TK_Q_\(project)_EOF
            fi

            """
        }
    } else if let queryJSONL {
        emit = """
        cat <<'TK_QUERY_EOF'
        \(queryJSONL)
        TK_QUERY_EOF
        """
    }

    var queryBlock = ""
    if !emit.isEmpty {
        queryBlock = """
        if [ "$1" = "query" ]; then
        base=`basename "$TICKETS_DIR"`
        \(emit)
        exit 0
        fi
        """
    }

    // Log argv AND the TICKETS_DIR scope for every call so tests can assert scoping.
    let script = """
    #!/bin/sh
    printf 'argv: %s | tdir=%s\\n' "$*" "$TICKETS_DIR" >> "\(argsLog.path)"
    \(failBlock)
    \(queryBlock)
    if [ "$1" = "show" ]; then
    cat <<'TK_SHOW_EOF'
    ---
    status: \(showStatus)
    ---
    TK_SHOW_EOF
    exit \(showExit)
    fi
    exit 0
    """

    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    return StubTk(url: scriptURL, argsLog: argsLog)
}

func readLog(_ url: URL) -> String {
    (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

// MARK: - git fixtures

struct GitSetupError: Error { let args: [String]; let output: String }

@discardableResult
func runGit(_ args: [String], cwd: URL) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = WorktreeManager.defaultGitURL()
    process.arguments = args
    process.currentDirectoryURL = cwd
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

func git(_ args: [String], in repo: URL) throws {
    let result = try runGit(args, cwd: repo)
    if result.status != 0 { throw GitSetupError(args: args, output: result.output) }
}

/// Initialize a temp git repo with one commit. `.env` is left untracked (the case worktrees
/// don't carry); `.anvil/prepare.sh` touches a marker file and is committed.
func makeGitRepo(in dir: URL, withEnv: Bool = true, withPrepareHook: Bool = true) throws -> URL {
    let repo = dir.appendingPathComponent("repo-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try git(["init", "-q"], in: repo)
    try git(["config", "user.email", "test@example.com"], in: repo)
    try git(["config", "user.name", "Anvil Test"], in: repo)

    try "# repo\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    if withEnv {
        try "SECRET=1\n".write(to: repo.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    }
    if withPrepareHook {
        let anvil = repo.appendingPathComponent(".anvil")
        try FileManager.default.createDirectory(at: anvil, withIntermediateDirectories: true)
        let script = anvil.appendingPathComponent("prepare.sh")
        try "#!/bin/sh\ntouch prepared.marker\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try git(["add", ".anvil/prepare.sh"], in: repo)
    }
    try git(["add", "README.md"], in: repo)
    try git(["commit", "-q", "-m", "init"], in: repo)
    return repo
}

/// Write a tk `config.yaml` mapping projects to repo paths, for engine/data-layer resolution.
func writeTicketConfig(_ projects: [String: URL], centralRoot: URL? = nil, in dir: URL) throws -> URL {
    var lines = ["central_root: \(centralRoot?.path ?? "/tmp/store")", "projects:"]
    for (name, url) in projects.sorted(by: { $0.key < $1.key }) {
        lines.append("    \(name):")
        lines.append("        path: \(url.path)")
    }
    let configURL = dir.appendingPathComponent("config.yaml")
    try (lines.joined(separator: "\n") + "\n").write(to: configURL, atomically: true, encoding: .utf8)
    return configURL
}
