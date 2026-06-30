import Foundation

/// Injectable configuration for `AnvilEngine`. All fields have host-sensible defaults so a
/// bare `EngineConfig()` works, while tests can point the executable, contract, and config
/// path at fixtures.
public struct EngineConfig: Sendable {
    /// Path to the real `claude` binary. The user's `claude` is a shell alias, so the engine
    /// always execs the resolved binary directly (never via a shell).
    public var claudeExecutableURL: URL
    public var model: String
    /// `claude --permission-mode`. Default `bypassPermissions`: `/work` needs Bash tools
    /// (swift build/test, installs) that `acceptEdits` does NOT auto-approve, so a run would
    /// otherwise block at the build/test step and never complete unattended. bypassPermissions
    /// approves all tools except explicit deny/ask rules. Runs are workspace-isolated by the
    /// per-run worktree (F2) but NOT sandboxed — true blast-radius isolation is deferred to v2
    /// (DESIGN §8). Dial back (acceptEdits / an allowlist) per risk tolerance.
    public var permissionMode: String
    public var headlessContract: String
    /// When set, every raw stdout line plus the spawned argv/cwd are appended here for replay.
    public var debugLogURL: URL?
    /// tk config that maps `project -> repo path` (`projects[<project>].path`).
    public var ticketConfigURL: URL

    public init(
        claudeExecutableURL: URL = EngineConfig.resolveClaudeOnPath(),
        model: String = "opus",
        permissionMode: String = "bypassPermissions",
        headlessContract: String = EngineConfig.defaultHeadlessContract,
        debugLogURL: URL? = nil,
        ticketConfigURL: URL = EngineConfig.defaultTicketConfigURL()
    ) {
        self.claudeExecutableURL = claudeExecutableURL
        self.model = model
        self.permissionMode = permissionMode
        self.headlessContract = headlessContract
        self.debugLogURL = debugLogURL
        self.ticketConfigURL = ticketConfigURL
    }

    public static func defaultTicketConfigURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ticket/config.yaml")
    }

    /// Resolve `claude` from `PATH`, plus the well-known install locations a GUI/launchd
    /// context may be missing from its inherited `PATH`. Returns a bare-name URL if nothing
    /// is found; `launch` validates executability and throws a clear error.
    public static func resolveClaudeOnPath() -> URL {
        let claudeLocal = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/local").path
        return ProcessSupport.resolveExecutable(named: "claude", extraDirectories: [claudeLocal])
    }

    /// The headless preamble injected via `--append-system-prompt`. Keeps `/work` pristine
    /// while teaching the agent anvil's sentinel contract.
    public static let defaultHeadlessContract = """
    You are a non-interactive worker supervised by a program called anvil. No human is available during your turn. Never ask a human in prose.
    - When you need a human decision or are blocked, make the FINAL lines of your message exactly:
    <<<ANVIL:NEEDS_INPUT>>>
    {"question": "<one line>", "options": ["<opt1>", "<opt2>"]}
    <<<ANVIL:END>>>
    - When the task is fully complete, make the FINAL lines of your message exactly:
    <<<ANVIL:DONE>>>
    {"summary": "<one line>"}
    <<<ANVIL:END>>>
    Output exactly one sentinel block as the FINAL lines of the turn. Brief reasoning before it is allowed; output nothing after the closing delimiter.
    """
}
