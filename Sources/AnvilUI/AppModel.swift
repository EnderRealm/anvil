import Foundation
import Observation
import AnvilEngine

/// Sidebar badge counts.
public struct SidebarCounts: Sendable, Equatable {
    public var inbox = 0
    public var ready = 0
    public var running = 0
    public var all = 0
}

/// The app's single view-model. `@MainActor` + `@Observable` bridge the actor backend
/// (`TkDataLayer` / `RunSupervisor`) into observable UI state. Holds no SwiftUI types.
@MainActor
@Observable
public final class AppModel {
    private let dataLayer: TkDataLayer
    private let supervisor: RunSupervisor

    // Loaded data
    public private(set) var tickets: [TicketSummary] = []
    public private(set) var projects: [ProjectInfo] = []
    public private(set) var readyIDs: Set<String> = []
    public private(set) var blockedIDs: Set<String> = []
    public private(set) var runsByTicket: [String: RunModel] = [:]
    public private(set) var pending: [PendingInput] = []
    public private(set) var detail: TicketDetail?
    public private(set) var lastError: String?

    // UI state
    public var selection: SidebarSelection = .ready
    public var selectedTicketID: String?
    public var searchText: String = ""

    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: StoreWatcher?

    public init(dataLayer: TkDataLayer, supervisor: RunSupervisor) {
        self.dataLayer = dataLayer
        self.supervisor = supervisor
    }

    /// Wire real backend instances pointed at the real central store + `~/.ticket/config.yaml`.
    public static func live() -> AppModel {
        let engine = AnvilEngine(config: EngineConfig())
        let tk = TkClient()
        return AppModel(
            dataLayer: TkDataLayer(tk: tk),
            supervisor: RunSupervisor(engine: engine, tk: tk)
        )
    }

    // MARK: - Lifecycle

    /// Load data, subscribe to live run events, and (optionally) start the FSEvents watcher.
    public func start(watch: Bool = true) async {
        await refresh()
        await subscribeEvents()
        if watch { await startWatcher() }
    }

    /// MUST be called on teardown — the watcher retains itself until released.
    public func stop() {
        eventTask?.cancel()
        watchTask?.cancel()
        watcher?.stop()
        watcher = nil
        eventTask = nil
        watchTask = nil
    }

    private func subscribeEvents() async {
        let stream = await supervisor.makeEventStream()
        // Seed from the current snapshot so existing runs show immediately.
        for run in await supervisor.runModels() { runsByTicket[run.ticketID] = run }
        pending = await supervisor.pendingInputs()
        eventTask = Task { [weak self] in
            for await event in stream { self?.apply(event) }
        }
    }

    private func startWatcher() async {
        guard let watcher = try? await dataLayer.makeWatcher() else { return }
        self.watcher = watcher
        watcher.start()
        let changes = watcher.changes()
        watchTask = Task { [weak self] in
            for await _ in changes { await self?.refresh() }
        }
    }

    private func apply(_ event: SupervisorEvent) {
        switch event {
        case .runUpdated(let run): runsByTicket[run.ticketID] = run
        case .queueChanged(let queue): pending = queue
        }
    }

    // MARK: - Reads

    public func dismissError() { lastError = nil }

    public func refresh() async {
        do {
            let loadedProjects = try await dataLayer.projects()
            let loaded = try await dataLayer.allTickets()
            let actionability = TkDataLayer.readyBlocked(loaded)
            projects = loadedProjects
            tickets = loaded
            readyIDs = Set(actionability.ready.map(\.id))
            blockedIDs = Set(actionability.blocked.map(\.id))
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }

    public func select(_ ticketID: String?) {
        selectedTicketID = ticketID
        detail = nil
        guard let ticketID else { return }
        Task { await loadDetail(ticketID) }
    }

    private func loadDetail(_ id: String) async {
        do { detail = try await dataLayer.ticketDetail(id: id) }
        catch { lastError = "\(error)" }
    }

    // MARK: - Derived state

    public var visibleTickets: [TicketSummary] {
        TicketFilter.visible(
            tickets: tickets, selection: selection, search: searchText,
            ready: readyIDs, blocked: blockedIDs, runsByTicket: runsByTicket
        )
    }

    public var selectedTicket: TicketSummary? {
        guard let id = selectedTicketID else { return nil }
        return tickets.first { $0.id == id }
    }

    public var selectedRun: RunModel? {
        guard let id = selectedTicketID else { return nil }
        return runsByTicket[id]
    }

    public func run(for ticketID: String) -> RunModel? { runsByTicket[ticketID] }

    public func statusKind(for ticket: TicketSummary) -> StatusKind {
        StatusKind.of(ticket: ticket, run: runsByTicket[ticket.id], ready: readyIDs, blocked: blockedIDs)
    }

    public func isLaunchable(_ project: String) -> Bool {
        projects.first { $0.name == project }?.launchable ?? false
    }

    /// Launchable project with no in-flight run.
    public func canLaunch(_ ticket: TicketSummary) -> Bool {
        guard isLaunchable(ticket.project) else { return false }
        if let run = runsByTicket[ticket.id] { return run.state.isTerminal }
        return true
    }

    public var counts: SidebarCounts {
        var counts = SidebarCounts()
        counts.all = tickets.count
        counts.ready = tickets.filter { readyIDs.contains($0.id) }.count
        counts.running = tickets.filter { runsByTicket[$0.id]?.state.isActive ?? false }.count
        counts.inbox = tickets.filter {
            TicketFilter.isInbox($0, run: runsByTicket[$0.id], ready: readyIDs)
        }.count
        return counts
    }

    public func ticketCount(project: String) -> Int {
        tickets.filter { $0.project == project }.count
    }

    // MARK: - Commands

    @discardableResult
    public func launch(_ ticketID: String) async -> RunID? {
        do { return try await supervisor.launch(ticketID: ticketID) }
        catch { lastError = "\(error)"; return nil }
    }

    public func launchSelected() async {
        guard let ticket = selectedTicket, canLaunch(ticket) else { return }
        await launch(ticket.id)
    }

    public func answer(_ runID: RunID, text: String) async {
        do { try await supervisor.answer(runID, text: text) }
        catch { lastError = "\(error)" }
    }

    public func answerSelected(text: String) async {
        guard let run = selectedRun, case .needsInput = run.state else { return }
        await answer(run.id, text: text)
    }

    // MARK: - Grooming (writes route through TkDataLayer; acceptance is read-only — no CLI flag)

    public func saveWhy(_ text: String) async { await groom { try await $0.setDescription(ticketID: $1, text) } }
    public func setStatus(_ status: String) async { await groom { try await $0.setStatus(ticketID: $1, status) } }
    public func setPriority(_ priority: Int) async { await groom { try await $0.setPriority(ticketID: $1, priority) } }
    public func addNote(_ text: String) async { await groom { try await $0.addNote(ticketID: $1, text: text) } }

    private func groom(_ work: (TkDataLayer, String) async throws -> Void) async {
        guard let id = selectedTicketID else { return }
        do {
            try await work(dataLayer, id)
            await loadDetail(id)
            await refresh()
        } catch {
            lastError = "\(error)"
        }
    }
}
