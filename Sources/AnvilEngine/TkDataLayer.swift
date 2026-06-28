import Foundation

/// Read-model summary of a ticket. Ids are namespaced (`project/slug`); `deps` and `parent`
/// are normalized to namespaced form. `anvilState` carries F3's `anvil-state` extra.
public struct TicketSummary: Sendable, Equatable {
    public let id: String
    public let project: String
    public let status: String
    public let type: String
    public let priority: Int
    public let title: String
    public let parent: String?
    public let deps: [String]
    public let tags: [String]
    public let anvilState: String?

    public init(
        id: String, project: String, status: String, type: String, priority: Int,
        title: String, parent: String?, deps: [String], tags: [String], anvilState: String?
    ) {
        self.id = id
        self.project = project
        self.status = status
        self.type = type
        self.priority = priority
        self.title = title
        self.parent = parent
        self.deps = deps
        self.tags = tags
        self.anvilState = anvilState
    }
}

/// A project as seen across the central store + config. `launchable` requires both tickets and
/// a local repo clone (browse = all; launch = the intersection).
public struct ProjectInfo: Sendable, Equatable {
    public let name: String
    public let repoPath: URL?
    public let ticketDir: URL?

    public var hasTickets: Bool { ticketDir != nil }
    public var launchable: Bool { repoPath != nil && ticketDir != nil }
}

public struct StoreInfo: Sendable, Equatable {
    public let centralRoot: URL
    public let projects: [ProjectInfo]
}

/// Full ticket read for the detail/grooming pane: frontmatter + markdown body sections.
/// `tk show` emits YAML+markdown (not JSON), so this is parsed from that text.
public struct TicketDetail: Sendable, Equatable {
    public let id: String
    public let project: String
    public let title: String
    public let status: String
    public let type: String
    public let priority: Int
    public let parent: String?
    public let deps: [String]
    public let tags: [String]
    public let description: String          // the "why" — text after the title, before sections
    public let acceptanceCriteria: String?  // "## Acceptance Criteria" (read-only: no CLI write)
    public let design: String?              // "## Design"
    public let notes: [String]              // "## Notes" entries
}

public enum TkDataError: Error, Sendable, CustomStringConvertible, LocalizedError {
    case configUnreadable(String)
    case configInvalid(String)
    case projectNotLaunchable(String)
    case ticketUnavailable(String)

    public var description: String {
        switch self {
        case .configUnreadable(let path): return "could not read tk config at '\(path)'"
        case .configInvalid(let detail): return "invalid tk config: \(detail)"
        case .projectNotLaunchable(let project): return "project '\(project)' has no local repo path"
        case .ticketUnavailable(let id): return "ticket '\(id)' is not available in the store"
        }
    }
    public var errorDescription: String? { description }
}

// One JSONL row from `tk query`. Lenient: tolerates missing/null fields and the empty-list
// "null" serialization quirk the spike flagged.
private struct RawTicket: Decodable {
    let id: String
    let status: String
    let type: String?
    let priority: Int?
    let title: String?
    let parent: String?
    let deps: [String]?
    let tags: [String]?
    let anvilState: String?

    private enum CodingKeys: String, CodingKey {
        case id, status, type, priority, title, parent, deps, tags
        case anvilState = "anvil-state"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        status = ((try? c.decodeIfPresent(String.self, forKey: .status)) ?? nil) ?? "backlog"
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? nil
        priority = (try? c.decodeIfPresent(Int.self, forKey: .priority)) ?? nil
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
        parent = (try? c.decodeIfPresent(String.self, forKey: .parent)) ?? nil
        deps = (try? c.decodeIfPresent([String].self, forKey: .deps)) ?? nil
        tags = (try? c.decodeIfPresent([String].self, forKey: .tags)) ?? nil
        anvilState = (try? c.decodeIfPresent(String.self, forKey: .anvilState)) ?? nil
    }
}

/// Multi-project tk data layer over the `tk` CLI. Reads via `tk query` per project; computes
/// `ready`/`blocked`/`inbox`/`storeInfo` client-side (tk exposes those only over MCP). Writes
/// delegate to `TkClient` with the bare slug, scoped to the project repo. Never runs
/// `tk serve`; the markdown store is never parsed directly.
public actor TkDataLayer {
    private let tk: TkClient
    private let configURL: URL

    public init(tk: TkClient = TkClient(), configURL: URL = EngineConfig.defaultTicketConfigURL()) {
        self.tk = tk
        self.configURL = configURL
    }

    // MARK: - Store / projects

    public func storeInfo() throws -> StoreInfo {
        guard let yaml = try? String(contentsOf: configURL, encoding: .utf8) else {
            throw TkDataError.configUnreadable(configURL.path)
        }
        guard let rootPath = RepoResolver.centralRoot(inYAML: yaml) else {
            throw TkDataError.configInvalid("missing central_root")
        }
        let centralRoot = URL(fileURLWithPath: rootPath, isDirectory: true)
        let configProjects = RepoResolver.projects(inYAML: yaml)

        // Projects that have tickets = subdirectories of <central_root>/tickets.
        let ticketsDir = centralRoot.appendingPathComponent("tickets", isDirectory: true)
        var storeNames: Set<String> = []
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: ticketsDir, includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for entry in entries {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue {
                    storeNames.insert(entry.lastPathComponent)
                }
            }
        }

        let names = Set(configProjects.keys).union(storeNames).sorted()
        let projects = names.map { name -> ProjectInfo in
            ProjectInfo(
                name: name,
                repoPath: configProjects[name].map { URL(fileURLWithPath: $0, isDirectory: true) },
                ticketDir: storeNames.contains(name)
                    ? ticketsDir.appendingPathComponent(name, isDirectory: true) : nil
            )
        }
        return StoreInfo(centralRoot: centralRoot, projects: projects)
    }

    public func projects(launchable: Bool = false) throws -> [ProjectInfo] {
        let all = try storeInfo().projects
        return launchable ? all.filter(\.launchable) : all
    }

    /// An FSEvents watcher on the central store root. Caller owns its lifetime.
    public func makeWatcher(debounce: TimeInterval = 0.2) throws -> StoreWatcher {
        StoreWatcher(path: try storeInfo().centralRoot, debounce: debounce)
    }

    // MARK: - Reads

    /// Tickets across EVERY project in the store (cloned or not) — browse is all-projects;
    /// cloned-ness gates launch, not browse. Reads each project by its ticket dir so
    /// cross-project deps/parents resolve and readiness is correct. Queries run concurrently.
    public func allTickets() async throws -> [TicketSummary] {
        let projects = try storeInfo().projects.filter(\.hasTickets)
        let client = tk
        return try await withThrowingTaskGroup(of: [TicketSummary].self) { group in
            for project in projects {
                guard let ticketDir = project.ticketDir else { continue }
                let name = project.name
                group.addTask {
                    Self.parse(try await client.query(ticketDir: ticketDir), project: name)
                }
            }
            var all: [TicketSummary] = []
            for try await chunk in group { all += chunk }
            return all
        }
    }

    public func tickets(project: String) async throws -> [TicketSummary] {
        guard let info = try storeInfo().projects.first(where: { $0.name == project }),
              let ticketDir = info.ticketDir else { return [] }
        return Self.parse(try await tk.query(ticketDir: ticketDir), project: project)
    }

    /// Full ticket (frontmatter + body) for the detail/grooming pane. Works for any project in
    /// the store (scoped by ticket dir).
    public func ticketDetail(id: String) async throws -> TicketDetail {
        let project = TicketID.project(id)
        guard let info = try storeInfo().projects.first(where: { $0.name == project }),
              let ticketDir = info.ticketDir else {
            throw TkDataError.ticketUnavailable(id)
        }
        let raw = try await tk.showRaw(TicketID.slug(id), ticketDir: ticketDir)
        return Self.parseDetail(raw, id: id)
    }

    public func ready() async throws -> [TicketSummary] {
        Self.readyBlocked(try await allTickets()).ready
    }

    public func blocked() async throws -> [TicketSummary] {
        Self.readyBlocked(try await allTickets()).blocked
    }

    /// Needs-intervention signal: tickets carrying F3's `anvil-state` (needs-input/failed).
    /// File-backed and cross-device — tk's native inbox is MCP-only.
    public func inbox() async throws -> [TicketSummary] {
        try await allTickets().filter { ($0.anvilState?.isEmpty == false) }
    }

    // MARK: - Writes (delegate to TkClient, bare slug + ticket-dir scope)
    //
    // Grooming writes scope by the ticket dir (TICKETS_DIR), which works for ANY project in the
    // store — including uncloned ones. Clone-ness gates LAUNCH (worktrees), not grooming.

    public func addNote(ticketID: String, text: String) async throws {
        try await tk.addNote(TicketID.slug(ticketID), text: text, ticketDir: try ticketDir(for: ticketID))
    }

    public func setExtras(ticketID: String, _ extras: [String: String]) async throws {
        try await tk.setExtras(TicketID.slug(ticketID), extras, ticketDir: try ticketDir(for: ticketID))
    }

    public func setStatus(ticketID: String, _ status: String) async throws {
        try await tk.edit(TicketID.slug(ticketID), ticketDir: try ticketDir(for: ticketID), status: status)
    }

    public func setPriority(ticketID: String, _ priority: Int) async throws {
        try await tk.edit(TicketID.slug(ticketID), ticketDir: try ticketDir(for: ticketID), priority: priority)
    }

    /// Set the "why" (description). tk has no flag for acceptance criteria, so "success" is
    /// read-only in the UI.
    public func setDescription(ticketID: String, _ text: String) async throws {
        try await tk.edit(TicketID.slug(ticketID), ticketDir: try ticketDir(for: ticketID), description: text)
    }

    /// Create requires a registered project repo (you create where you can work).
    @discardableResult
    public func create(project: String, title: String, type: String? = nil, priority: Int? = nil) async throws -> String {
        let repo = try projectRepo("\(project)/_")
        let bare = try await tk.create(repoURL: repo, title: title, type: type, priority: priority)
        return "\(project)/\(bare)"
    }

    private func projectRepo(_ ticketID: String) throws -> URL {
        let project = TicketID.project(ticketID)
        guard let yaml = try? String(contentsOf: configURL, encoding: .utf8),
              let path = RepoResolver.repoPath(forProject: project, inYAML: yaml) else {
            throw TkDataError.projectNotLaunchable(project)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func ticketDir(for ticketID: String) throws -> URL {
        let project = TicketID.project(ticketID)
        guard let info = try storeInfo().projects.first(where: { $0.name == project }),
              let dir = info.ticketDir else {
            throw TkDataError.ticketUnavailable(ticketID)
        }
        return dir
    }

    // MARK: - Parsing + actionability

    static func parse(_ jsonl: String, project: String) -> [TicketSummary] {
        var result: [TicketSummary] = []
        for line in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
                  let raw = try? JSONDecoder().decode(RawTicket.self, from: data) else { continue }
            result.append(TicketSummary(
                id: "\(project)/\(raw.id)",
                project: project,
                status: raw.status,
                type: raw.type ?? "feature",
                priority: raw.priority ?? 2,
                title: raw.title ?? "",
                parent: raw.parent.map { normalize($0, project: project) },
                deps: (raw.deps ?? []).map { normalize($0, project: project) },
                tags: raw.tags ?? [],
                anvilState: raw.anvilState
            ))
        }
        return result
    }

    static func isTerminal(_ status: String) -> Bool {
        status == "done" || status == "closed"
    }

    static func normalize(_ id: String, project: String) -> String {
        id.contains("/") ? id : "\(project)/\(id)"
    }

    /// tk's actionability logic, computed locally:
    /// - ready: non-terminal, non-backlog, all deps terminal, full parent chain active.
    /// - blocked: non-terminal, non-backlog, with a non-terminal or missing dep.
    public static func readyBlocked(_ tickets: [TicketSummary]) -> (ready: [TicketSummary], blocked: [TicketSummary]) {
        let byID = Dictionary(tickets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var ready: [TicketSummary] = []
        var blocked: [TicketSummary] = []
        for ticket in tickets {
            guard !isTerminal(ticket.status), ticket.status != "backlog" else { continue }

            let depsAllTerminal = ticket.deps.allSatisfy { byID[$0].map { isTerminal($0.status) } ?? false }
            let hasUnresolvedDep = ticket.deps.contains { byID[$0].map { !isTerminal($0.status) } ?? true }

            if hasUnresolvedDep {
                blocked.append(ticket)
            }
            if depsAllTerminal && parentChainActive(ticket, byID: byID) {
                ready.append(ticket)
            }
        }
        return (ready, blocked)
    }

    private static func parentChainActive(_ ticket: TicketSummary, byID: [String: TicketSummary]) -> Bool {
        var current = ticket
        var seen: Set<String> = [ticket.id]
        while let parentID = current.parent {
            guard let parent = byID[parentID] else { return true }  // unknown (e.g. uncloned) — don't block
            if isTerminal(parent.status) { return false }
            if seen.contains(parentID) { return true }  // cycle guard
            seen.insert(parentID)
            current = parent
        }
        return true
    }

    // MARK: - `tk show` detail parsing

    static func parseDetail(_ showOutput: String, id: String) -> TicketDetail {
        let project = TicketID.project(id)
        let (frontmatter, body) = splitFrontmatter(showOutput)
        let (title, description, sections) = parseBody(body)

        func section(_ name: String) -> String? {
            sections.first { $0.heading.caseInsensitiveCompare(name) == .orderedSame }?.body
        }
        let notesSection = section("Notes")

        return TicketDetail(
            id: id,
            project: project,
            title: title,
            status: frontmatterScalar("status", frontmatter) ?? "backlog",
            type: frontmatterScalar("type", frontmatter) ?? "feature",
            priority: frontmatterScalar("priority", frontmatter).flatMap(Int.init) ?? 2,
            parent: frontmatterScalar("parent", frontmatter),
            deps: frontmatterList("deps", frontmatter),
            tags: frontmatterList("tags", frontmatter),
            description: description,
            acceptanceCriteria: section("Acceptance Criteria"),
            design: section("Design"),
            notes: notesSection.map(parseNotes) ?? []
        )
    }

    // Body = everything after the second `---`. Frontmatter = lines between the two `---`.
    private static func splitFrontmatter(_ text: String) -> (frontmatter: String, body: String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return ("", text)
        }
        var end = -1
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            end = i
            break
        }
        guard end > 0 else { return ("", text) }
        let frontmatter = lines[1..<end].joined(separator: "\n")
        let body = lines[(end + 1)...].joined(separator: "\n")
        return (frontmatter, body)
    }

    private static func frontmatterScalar(_ key: String, _ frontmatter: String) -> String? {
        let prefix = key + ":"
        for line in frontmatter.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(prefix) {
                let value = t.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    // YAML inline list, e.g. `deps: [a, b]` or `tags: []`.
    private static func frontmatterList(_ key: String, _ frontmatter: String) -> [String] {
        guard var value = frontmatterScalar(key, frontmatter) else { return [] }
        if value.hasPrefix("[") { value.removeFirst() }
        if value.hasSuffix("]") { value.removeLast() }
        return value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // Markdown body: first `# ` is the title; text up to the first `## ` is the description;
    // each `## Heading` opens a section.
    static func parseBody(_ body: String) -> (title: String, description: String, sections: [(heading: String, body: String)]) {
        var title = ""
        var descriptionLines: [String] = []
        var sections: [(heading: String, body: String)] = []
        var heading: String?
        var sectionLines: [String] = []

        func flush() {
            if let heading {
                sections.append((heading, sectionLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            sectionLines = []
        }

        for line in body.components(separatedBy: "\n") {
            if heading == nil, title.isEmpty, line.hasPrefix("# ") {
                title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("## ") {
                flush()
                heading = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if heading == nil {
                descriptionLines.append(line)
            } else {
                sectionLines.append(line)
            }
        }
        flush()
        let description = descriptionLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (title, description, sections)
    }

    // Notes section: timestamped blocks `**<timestamp>**` followed by body text.
    static func parseNotes(_ section: String) -> [String] {
        var notes: [String] = []
        var current: [String] = []
        var started = false
        func flush() {
            let text = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { notes.append(text) }
            current = []
        }
        for line in section.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("**"), t.hasSuffix("**"), t.count >= 4 {
                flush()
                started = true
            } else if started {
                current.append(line)
            }
        }
        flush()
        // No timestamp markers (plain note body) — treat the whole section as one note.
        if notes.isEmpty {
            let whole = section.trimmingCharacters(in: .whitespacesAndNewlines)
            if !whole.isEmpty { notes.append(whole) }
        }
        return notes
    }
}
