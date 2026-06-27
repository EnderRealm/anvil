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

/// Write a `#!/bin/sh` stub that records each invocation's argv and returns canned YAML
/// frontmatter for `show` (with `showStatus`). Other subcommands just exit 0. When `failVerb`
/// is set, that subcommand exits nonzero (to exercise tk write-failure paths).
func makeStubTk(
    in dir: URL,
    showStatus: String = "done",
    showExit: Int32 = 0,
    failVerb: String? = nil,
    failExit: Int32 = 1
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

    let script = """
    #!/bin/sh
    printf 'argv: %s\\n' "$*" >> "\(argsLog.path)"
    \(failBlock)
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
