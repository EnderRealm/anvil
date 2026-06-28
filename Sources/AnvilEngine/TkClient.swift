import Foundation

/// The subset of a ticket the supervisor reads back for cross-checking. F4 grows this into
/// the full read model; F3 only needs `status`.
public struct TicketInfo: Sendable, Equatable {
    public let id: String
    public let status: String

    public init(id: String, status: String) {
        self.id = id
        self.status = status
    }
}

public enum TkError: Error, Sendable, CustomStringConvertible, LocalizedError {
    case executableNotFound(String)
    case commandFailed(command: String, exitCode: Int32, stderr: String)
    case unexpectedOutput(command: String, detail: String)

    public var description: String {
        switch self {
        case .executableNotFound(let path):
            return "no executable tk found at '\(path)'"
        case .commandFailed(let command, let code, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "tk \(command) failed (\(code))" + (detail.isEmpty ? "" : ": \(detail)")
        case .unexpectedOutput(let command, let detail):
            return "tk \(command) produced unexpected output: \(detail)"
        }
    }

    public var errorDescription: String? { description }
}

/// Thin wrapper over the `tk` CLI. Headless and dependency-free; the executable is injectable
/// so tests can point it at a stub. Minimal by design — F4 grows this into the full
/// read/FSEvents data layer.
///
/// Note: the `tk` CLI addresses tickets by their *bare* slug (the namespaced `project/slug`
/// form is rejected), and `tk show` emits YAML frontmatter even with `--json`, so `show`
/// reads the `status:` line from the frontmatter. Callers pass the bare id.
public struct TkClient: Sendable {
    public var executableURL: URL

    public init(executableURL: URL = TkClient.resolveTkOnPath()) {
        self.executableURL = executableURL
    }

    public static func resolveTkOnPath() -> URL {
        ProcessSupport.resolveExecutable(named: "tk")
    }

    /// `--repo` or `ticketDir` (`TICKETS_DIR`) scopes the command to a project; required when
    /// the process cwd isn't that project's repo (a bare slug won't resolve from a neutral cwd).
    public func show(_ ticketID: String, repoURL: URL? = nil, ticketDir: URL? = nil) async throws -> TicketInfo {
        let output = try await run(["show", ticketID] + Self.repoArgs(repoURL), environment: Self.dirEnv(ticketDir))
        guard let status = Self.frontmatterValue("status", in: output.stdout) else {
            throw TkError.unexpectedOutput(command: "show", detail: "no status in frontmatter")
        }
        let id = Self.frontmatterValue("id", in: output.stdout) ?? ticketID
        return TicketInfo(id: id, status: status)
    }

    /// Per-ticket ops accept either `repoURL` (`--repo`) or `ticketDir` (`TICKETS_DIR`).
    /// `ticketDir` works for any project in the store, including uncloned ones.
    public func addNote(_ ticketID: String, text: String, repoURL: URL? = nil, ticketDir: URL? = nil) async throws {
        _ = try await run(["add-note", ticketID, text] + Self.repoArgs(repoURL), environment: Self.dirEnv(ticketDir))
    }

    /// Set extra fields via `tk edit <id> --set k=v ...`. An empty value removes the key.
    public func setExtras(_ ticketID: String, _ extras: [String: String], repoURL: URL? = nil, ticketDir: URL? = nil) async throws {
        guard !extras.isEmpty else { return }
        var arguments = ["edit", ticketID]
        for key in extras.keys.sorted() {
            arguments.append("--set")
            arguments.append("\(key)=\(extras[key]!)")
        }
        _ = try await run(arguments + Self.repoArgs(repoURL), environment: Self.dirEnv(ticketDir))
    }

    /// Update core fields. Scoped to `repoURL` or `ticketDir`. Note: tk has no flag for the
    /// acceptance-criteria / design body sections — only `--description` (the "why").
    public func edit(
        _ ticketID: String,
        repoURL: URL? = nil,
        ticketDir: URL? = nil,
        status: String? = nil,
        priority: Int? = nil,
        title: String? = nil,
        description: String? = nil,
        tags: [String]? = nil
    ) async throws {
        var arguments = ["edit", ticketID]
        if let status { arguments += ["--status", status] }
        if let priority { arguments += ["--priority", String(priority)] }
        if let title { arguments += ["--title", title] }
        if let description { arguments += ["--description", description] }
        if let tags { arguments += ["--tags", tags.joined(separator: ",")] }
        _ = try await run(arguments + Self.repoArgs(repoURL), environment: Self.dirEnv(ticketDir))
    }

    private static func dirEnv(_ ticketDir: URL?) -> [String: String]? {
        ticketDir.map { ["TICKETS_DIR": $0.path] }
    }

    /// Raw `tk show` output (YAML frontmatter + markdown body) for a ticket, scoped by ticket
    /// dir so it works for any project.
    public func showRaw(_ ticketID: String, ticketDir: URL) async throws -> String {
        let output = try await run(["show", ticketID], environment: ["TICKETS_DIR": ticketDir.path])
        return output.stdout
    }

    /// Create a ticket in the given project repo; returns the new bare slug.
    public func create(repoURL: URL, title: String, type: String? = nil, priority: Int? = nil) async throws -> String {
        var arguments = ["create", title]
        if let type { arguments += ["--type", type] }
        if let priority { arguments += ["--priority", String(priority)] }
        let output = try await run(arguments + Self.repoArgs(repoURL))
        guard let id = Self.frontmatterValue("id", in: output.stdout) else {
            throw TkError.unexpectedOutput(command: "create", detail: "no id in output")
        }
        return id
    }

    /// Raw `tk query` JSONL (one JSON object per line) for the project whose tickets live at
    /// `ticketDir` (`<central_root>/tickets/<project>`). Scoped via `TICKETS_DIR` so it works
    /// for store-only projects too (`--repo` requires a registered store; the ticket dir alone
    /// is not one).
    public func query(ticketDir: URL) async throws -> String {
        let output = try await run(["query"], environment: ["TICKETS_DIR": ticketDir.path])
        return output.stdout
    }

    private static func repoArgs(_ repoURL: URL?) -> [String] {
        guard let repoURL else { return [] }
        return ["--repo", repoURL.path]
    }

    @discardableResult
    private func run(_ arguments: [String], environment: [String: String]? = nil) async throws -> ProcessSupport.Output {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw TkError.executableNotFound(executableURL.path)
        }
        let output = try await ProcessSupport.run(
            executableURL: executableURL, arguments: arguments, environment: environment
        )
        guard output.exitCode == 0 else {
            throw TkError.commandFailed(
                command: arguments.first ?? "?",
                exitCode: output.exitCode,
                stderr: output.stderr
            )
        }
        return output
    }

    // Read a value from the leading `--- ... ---` YAML frontmatter block.
    static func frontmatterValue(_ key: String, in text: String) -> String? {
        var inFrontmatter = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                if inFrontmatter { break }
                inFrontmatter = true
                continue
            }
            guard inFrontmatter else { continue }
            let prefix = key + ":"
            if trimmed.hasPrefix(prefix) {
                let value = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}
