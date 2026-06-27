import Foundation

/// An isolated git worktree for one run, in the ticket's own project repo.
public struct Worktree: Sendable, Equatable {
    public let path: URL
    public let branch: String
    public let sourceRepo: URL

    public init(path: URL, branch: String, sourceRepo: URL) {
        self.path = path
        self.branch = branch
        self.sourceRepo = sourceRepo
    }
}

/// How a fresh worktree is made usable: a bare worktree shares `.git` but not untracked/
/// ignored files, so `/work`'s test step would fail without this.
public struct WorktreePrepareConfig: Sendable {
    /// Paths (relative to the source repo) to symlink into the worktree when they exist.
    public var symlinkPaths: [String]
    /// Explicit prepare command (argv); run with cwd = the worktree. Takes precedence over the
    /// script hook. Install commands differ per ecosystem — never hardcode them here.
    public var prepareCommand: [String]?
    /// Per-repo prepare hook, relative to the source repo, run when present and no explicit
    /// command is configured.
    public var prepareScriptPath: String

    public init(
        symlinkPaths: [String] = [".env"],
        prepareCommand: [String]? = nil,
        prepareScriptPath: String = ".anvil/prepare.sh"
    ) {
        self.symlinkPaths = symlinkPaths
        self.prepareCommand = prepareCommand
        self.prepareScriptPath = prepareScriptPath
    }
}

public enum WorktreeError: Error, Sendable, CustomStringConvertible, LocalizedError {
    case gitNotFound(String)
    case commandFailed(command: String, stderr: String)
    case prepareFailed(stderr: String)
    case invalidSymlinkPath(String)

    public var description: String {
        switch self {
        case .gitNotFound(let path):
            return "no executable git found at '\(path)'"
        case .commandFailed(let command, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "git \(command) failed" + (detail.isEmpty ? "" : ": \(detail)")
        case .prepareFailed(let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "worktree prepare step failed" + (detail.isEmpty ? "" : ": \(detail)")
        case .invalidSymlinkPath(let path):
            return "invalid prepare symlink path '\(path)' — must be repo-relative with no '..'"
        }
    }

    public var errorDescription: String? { description }
}

/// Creates and tears down per-run git worktrees, plus the per-project prepare step. Headless
/// and dependency-free; `worktreeRoot`, prepare config, and the git binary are injectable.
public struct WorktreeManager: Sendable {
    public var worktreeRoot: URL
    public var prepare: WorktreePrepareConfig
    public var gitURL: URL

    public init(
        worktreeRoot: URL = WorktreeManager.defaultRoot(),
        prepare: WorktreePrepareConfig = WorktreePrepareConfig(),
        gitURL: URL = WorktreeManager.defaultGitURL()
    ) {
        self.worktreeRoot = worktreeRoot
        self.prepare = prepare
        self.gitURL = gitURL
    }

    /// Persisted (not temp) so branches under review and the resume cwd survive across runs.
    public static func defaultRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".anvil/worktrees", isDirectory: true)
    }

    public static func defaultGitURL() -> URL {
        ProcessSupport.resolveExecutable(named: "git")
    }

    /// Project-prefixed to avoid cross-project slug collisions: `<root>/<project>/<slug>`.
    public func worktreePath(forTicket ticketID: String) -> URL {
        worktreeRoot
            .appendingPathComponent(TicketID.project(ticketID), isDirectory: true)
            .appendingPathComponent(TicketID.slug(ticketID), isDirectory: true)
    }

    public func create(ticketID: String, repoURL: URL) async throws -> Worktree {
        let slug = TicketID.slug(ticketID)
        let path = worktreePath(forTicket: ticketID)
        let branch = "anvil/\(slug)"
        let worktree = Worktree(path: path, branch: branch, sourceRepo: repoURL)

        // Relaunch into an existing checkout: reuse it as-is (already prepared).
        if isWorktreeCheckout(path) {
            return worktree
        }

        // Normal case: a new branch off HEAD.
        let add = try await git(["worktree", "add", path.path, "-b", branch], in: repoURL)
        if add.exitCode == 0 {
            try await prepareOrTeardown(worktree)
            return worktree
        }

        // The branch already exists (a prior run whose worktree was removed) — reuse it.
        let reuse = try await git(["worktree", "add", path.path, branch], in: repoURL)
        if reuse.exitCode == 0 {
            try await prepareOrTeardown(worktree)
            return worktree
        }

        // A concurrent create may have produced the checkout in the meantime.
        if isWorktreeCheckout(path) {
            return worktree
        }
        throw WorktreeError.commandFailed(
            command: "worktree add \(branch)",
            stderr: reuse.stderr.isEmpty ? add.stderr : reuse.stderr
        )
    }

    // Prepare a freshly-added worktree; if prepare fails, tear it down so a relaunch starts
    // clean rather than reusing a half-prepared checkout.
    private func prepareOrTeardown(_ worktree: Worktree) async throws {
        do {
            try await runPrepare(worktree)
        } catch {
            try? await cleanup(worktree)
            throw error
        }
    }

    /// Remove the worktree. Keeps the branch by default (it may be pushed / under review).
    /// Idempotent: an already-removed worktree is a no-op rather than an error.
    public func cleanup(_ worktree: Worktree, deleteBranch: Bool = false) async throws {
        if FileManager.default.fileExists(atPath: worktree.path.path) {
            var remove = try await git(["worktree", "remove", worktree.path.path], in: worktree.sourceRepo)
            if remove.exitCode != 0 {
                // The prepare step leaves untracked files (symlinks, build output) — force.
                remove = try await git(["worktree", "remove", "--force", worktree.path.path], in: worktree.sourceRepo)
            }
            guard remove.exitCode == 0 else {
                throw WorktreeError.commandFailed(command: "worktree remove", stderr: remove.stderr)
            }
        } else {
            // Already gone — drop any stale registration and treat as success.
            _ = try await git(["worktree", "prune"], in: worktree.sourceRepo)
        }
        if deleteBranch {
            _ = try await git(["branch", "-D", worktree.branch], in: worktree.sourceRepo)
        }
    }

    /// The repo's anvil worktrees (branches under `anvil/*`).
    public func list(repoURL: URL) async throws -> [Worktree] {
        let result = try await git(["worktree", "list", "--porcelain"], in: repoURL)
        guard result.exitCode == 0 else {
            throw WorktreeError.commandFailed(command: "worktree list", stderr: result.stderr)
        }
        return Self.parseWorktrees(result.stdout, sourceRepo: repoURL)
    }

    // MARK: - Prepare

    private func runPrepare(_ worktree: Worktree) async throws {
        let fm = FileManager.default

        // (a) Symlink configured paths from the source repo when they exist.
        for relative in prepare.symlinkPaths {
            guard Self.isSafeRelativePath(relative) else {
                throw WorktreeError.invalidSymlinkPath(relative)
            }
            let source = worktree.sourceRepo.appendingPathComponent(relative)
            guard fm.fileExists(atPath: source.path) else { continue }
            let dest = worktree.path.appendingPathComponent(relative)
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            try fm.createSymbolicLink(at: dest, withDestinationURL: source)
        }

        // (b) Explicit command, else the per-repo prepare hook.
        if let command = prepare.prepareCommand, let executable = command.first {
            let result = try await ProcessSupport.run(
                executableURL: commandExecutable(executable),
                arguments: Array(command.dropFirst()),
                cwd: worktree.path
            )
            guard result.exitCode == 0 else { throw WorktreeError.prepareFailed(stderr: result.stderr) }
            return
        }

        let script = worktree.sourceRepo.appendingPathComponent(prepare.prepareScriptPath)
        guard fm.fileExists(atPath: script.path) else { return }
        let executable: URL
        let arguments: [String]
        if fm.isExecutableFile(atPath: script.path) {
            executable = script
            arguments = []
        } else {
            executable = URL(fileURLWithPath: "/bin/sh")
            arguments = [script.path]
        }
        let result = try await ProcessSupport.run(executableURL: executable, arguments: arguments, cwd: worktree.path)
        guard result.exitCode == 0 else { throw WorktreeError.prepareFailed(stderr: result.stderr) }
    }

    private func commandExecutable(_ name: String) -> URL {
        name.hasPrefix("/") ? URL(fileURLWithPath: name) : ProcessSupport.resolveExecutable(named: name)
    }

    // A symlink target must stay inside the worktree: repo-relative, no `..` traversal.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.hasPrefix("/") else { return false }
        return !path.split(separator: "/").contains("..")
    }

    // MARK: - git plumbing

    private func git(_ arguments: [String], in repo: URL) async throws -> ProcessSupport.Output {
        guard FileManager.default.isExecutableFile(atPath: gitURL.path) else {
            throw WorktreeError.gitNotFound(gitURL.path)
        }
        return try await ProcessSupport.run(executableURL: gitURL, arguments: ["-C", repo.path] + arguments)
    }

    private func isWorktreeCheckout(_ path: URL) -> Bool {
        // A worktree's `.git` is a file pointing back into the main repo.
        FileManager.default.fileExists(atPath: path.appendingPathComponent(".git").path)
    }

    static func parseWorktrees(_ porcelain: String, sourceRepo: URL) -> [Worktree] {
        var result: [Worktree] = []
        var path: String?
        var branch: String?

        func flush() {
            if let path, let branch, branch.hasPrefix("anvil/") {
                result.append(Worktree(path: URL(fileURLWithPath: path), branch: branch, sourceRepo: sourceRepo))
            }
            path = nil
            branch = nil
        }

        for line in porcelain.components(separatedBy: "\n") {
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("worktree ") {
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            }
        }
        flush()
        return result
    }
}
