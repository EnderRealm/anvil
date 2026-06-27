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

    public func show(_ ticketID: String) async throws -> TicketInfo {
        let output = try await run(["show", ticketID])
        guard let status = Self.frontmatterValue("status", in: output.stdout) else {
            throw TkError.unexpectedOutput(command: "show", detail: "no status in frontmatter")
        }
        let id = Self.frontmatterValue("id", in: output.stdout) ?? ticketID
        return TicketInfo(id: id, status: status)
    }

    public func addNote(_ ticketID: String, text: String) async throws {
        _ = try await run(["add-note", ticketID, text])
    }

    /// Set extra fields via `tk edit <id> --set k=v ...`. An empty value removes the key.
    public func setExtras(_ ticketID: String, _ extras: [String: String]) async throws {
        guard !extras.isEmpty else { return }
        var arguments = ["edit", ticketID]
        for key in extras.keys.sorted() {
            arguments.append("--set")
            arguments.append("\(key)=\(extras[key]!)")
        }
        _ = try await run(arguments)
    }

    @discardableResult
    private func run(_ arguments: [String]) async throws -> ProcessSupport.Output {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw TkError.executableNotFound(executableURL.path)
        }
        let output = try await ProcessSupport.run(executableURL: executableURL, arguments: arguments)
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
