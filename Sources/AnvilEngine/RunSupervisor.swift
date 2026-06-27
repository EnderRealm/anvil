import Foundation

// Ticket extra-field keys for the break-glass resume pointer (DESIGN §3.3).
enum AnvilTicketKey {
    static let state = "anvil-state"
    static let question = "anvil-question"
    static let session = "anvil-session"
    static let worktree = "anvil-worktree"
    static let host = "anvil-host"
}

enum AnvilTicketState {
    static let needsInput = "needs-input"
    static let failed = "failed"
}

/// A run blocked on a human decision. Held in the supervisor's live queue and mirrored to the
/// ticket as a break-glass resume pointer.
public struct PendingInput: Sendable, Equatable {
    public let runID: RunID
    public let ticketID: String
    public let sessionID: String
    public let question: String
    public let options: [String]
    public let cwd: URL
    public let blockedAt: Date
}

/// UI-facing view of a run. No UI framework — a plain value the supervisor re-broadcasts.
public struct RunModel: Sendable, Equatable {
    public let id: RunID
    public let ticketID: String
    public var sessionID: String?
    public var state: RunState
    public var cwd: URL
    /// Set when the run reports done but tk status disagrees — do not trust the sentinel alone.
    public var discrepancy: String?
    /// Most recent tk side-effect failure, if any.
    public var lastTkError: String?
}

public enum SupervisorEvent: Sendable {
    case runUpdated(RunModel)
    case queueChanged([PendingInput])
}

/// Composes `AnvilEngine` (the pure runner) with `TkClient`. It is the single consumer of the
/// engine's per-run event stream, performs the tk side effects + queue management, and
/// re-broadcasts an observable model for a future UI (F5). No UI framework.
public actor RunSupervisor {
    private let engine: AnvilEngine
    private let tk: TkClient
    private let hostName: String

    private var runs: [RunID: RunModel] = [:]
    private var queue: [PendingInput] = []

    // Per-consumer fan-out: each observer gets its own stream; events broadcast to all.
    private var subscribers: [UUID: AsyncStream<SupervisorEvent>.Continuation] = [:]

    public init(
        engine: AnvilEngine,
        tk: TkClient,
        hostName: String = ProcessInfo.processInfo.hostName
    ) {
        self.engine = engine
        self.tk = tk
        self.hostName = hostName
    }

    /// A fresh event stream for one observer. Each caller gets every event (no competition for
    /// a shared continuation); the subscription is released when the stream terminates.
    public func makeEventStream() -> AsyncStream<SupervisorEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private func broadcast(_ event: SupervisorEvent) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    // MARK: - Commands

    /// Launch a supervised run. `workdir` is resolved from the ticket's project when nil; the
    /// supervisor owns the cwd because it is the break-glass `anvil-worktree` pointer.
    @discardableResult
    public func launch(ticketID: String, workdir: URL? = nil) async throws -> RunID {
        let cwd: URL
        if let workdir {
            cwd = workdir
        } else {
            cwd = try await engine.repoPath(forTicket: ticketID)
        }
        let handle = try await engine.launch(ticketID: ticketID, workdir: cwd)
        let model = RunModel(
            id: handle.id, ticketID: ticketID, sessionID: nil,
            state: .running, cwd: cwd, discrepancy: nil, lastTkError: nil
        )
        store(model)

        let stream = handle.events
        Task { await self.consume(stream, runID: handle.id) }
        return handle.id
    }

    /// Answer a blocked run: resume the engine session first, then clear the waiting markers.
    /// Resuming first means a throwing `resume` (e.g. a non-blocked run) leaves the markers
    /// intact rather than clearing them on a still-blocked run. If the run blocks again, the
    /// consumer re-marks it with the new question.
    public func answer(_ runID: RunID, text: String) async throws {
        guard let model = runs[runID] else { throw EngineError.runNotFound(runID) }
        try await engine.resume(runID, answer: text)
        // Dequeue synchronously after resume returns (before any await) so a concurrent
        // re-block enqueue for this run cannot be wiped by a trailing dequeue. Markers stay
        // intact on a throwing resume because both lines are reached only after resume succeeds.
        dequeue(runID)
        let bare = Self.bareID(model.ticketID)
        do { try await clearWaitingExtras(bare) } catch { recordTkError(runID, error) }
    }

    // MARK: - Observable model

    public func runModels() -> [RunModel] { Array(runs.values) }
    public func model(for runID: RunID) -> RunModel? { runs[runID] }
    public func pendingInputs() -> [PendingInput] { queue }

    // MARK: - Stream consumption

    private func consume(_ stream: AsyncStream<AnvilEvent>, runID: RunID) async {
        for await event in stream {
            await handle(event, runID: runID)
        }
        // The stream can end without a terminal event (engine `cancel` finishes it silently).
        // Settle the model and clear the stale break-glass markers so the ticket isn't left
        // advertising a dead session.
        await settleIfUnfinished(runID: runID)
    }

    private func settleIfUnfinished(runID: RunID) async {
        guard let model = runs[runID] else { return }
        switch model.state {
        case .done, .failed, .canceled:
            return
        default:
            break
        }
        let bare = Self.bareID(model.ticketID)
        dequeue(runID)
        do {
            try await clearWaitingExtras(bare)
            try await tk.addNote(bare, text: "anvil: run ended without completing — canceled")
        } catch {
            recordTkError(runID, error)
        }
        if var settled = runs[runID] {
            settled.state = .canceled
            store(settled)
        }
    }

    private func handle(_ event: AnvilEvent, runID: RunID) async {
        guard var model = runs[runID] else { return }
        switch event {
        case .started(let sessionID, _, _):
            model.sessionID = sessionID
            model.state = .running
            store(model)

        case .output, .usage:
            break

        case .needsInput(let question, let options):
            let pending = PendingInput(
                runID: runID, ticketID: model.ticketID, sessionID: model.sessionID ?? "",
                question: question, options: options, cwd: model.cwd, blockedAt: Date()
            )
            await mirrorBlocked(pending)
            // mirrorBlocked may have set lastTkError; re-read before the terminal store.
            model = runs[runID] ?? model
            model.state = .needsInput(question: question, options: options)
            store(model)
            enqueue(pending)

        case .done(let summary):
            await reconcileDone(runID: runID, summary: summary)
            if var done = runs[runID] {
                done.state = .done(summary: summary)
                store(done)
            }

        case .failed(let error):
            await markFailed(runID: runID)
            if var failed = runs[runID] {
                failed.state = .failed(error.description)
                store(failed)
            }
        }
    }

    // MARK: - tk side effects

    private func mirrorBlocked(_ pending: PendingInput) async {
        let bare = Self.bareID(pending.ticketID)
        do {
            try await tk.addNote(bare, text: "anvil: needs input — \(pending.question)")
            // Ticket stays `open`; only the break-glass pointer changes.
            try await tk.setExtras(bare, [
                AnvilTicketKey.state: AnvilTicketState.needsInput,
                AnvilTicketKey.question: pending.question,
                AnvilTicketKey.session: pending.sessionID,
                AnvilTicketKey.worktree: pending.cwd.path,
                AnvilTicketKey.host: hostName,
            ])
        } catch {
            recordTkError(pending.runID, error)
        }
    }

    private func reconcileDone(runID: RunID, summary: String?) async {
        guard let model = runs[runID] else { return }
        let bare = Self.bareID(model.ticketID)
        dequeue(runID)
        do {
            try await clearWaitingExtras(bare)
            let suffix = summary.map { " — \($0)" } ?? ""
            try await tk.addNote(bare, text: "anvil: run reported done\(suffix)")
            // Cross-check: real /work sets status=done. Don't trust the sentinel alone.
            let info = try await tk.show(bare)
            if info.status != "done" {
                runs[runID]?.discrepancy = "run reported done but tk status is '\(info.status)'"
                try await tk.addNote(bare, text: "anvil: WARNING — run reported done but ticket status is '\(info.status)'")
            }
        } catch {
            recordTkError(runID, error)
        }
    }

    private func markFailed(runID: RunID) async {
        guard let model = runs[runID] else { return }
        let bare = Self.bareID(model.ticketID)
        dequeue(runID)
        do {
            try await tk.setExtras(bare, [
                AnvilTicketKey.state: AnvilTicketState.failed,
                AnvilTicketKey.question: "",
                AnvilTicketKey.session: "",
                AnvilTicketKey.worktree: "",
                AnvilTicketKey.host: "",
            ])
            try await tk.addNote(bare, text: "anvil: run failed")
            // Cross-check: a nonzero exit after /work had already set status=done is a
            // discrepancy worth flagging.
            let info = try await tk.show(bare)
            if info.status == "done" {
                runs[runID]?.discrepancy = "run failed but tk status is 'done'"
                try await tk.addNote(bare, text: "anvil: WARNING — run failed but ticket status is 'done'")
            }
        } catch {
            recordTkError(runID, error)
        }
    }

    private func clearWaitingExtras(_ bareID: String) async throws {
        try await tk.setExtras(bareID, [
            AnvilTicketKey.state: "",
            AnvilTicketKey.question: "",
            AnvilTicketKey.session: "",
            AnvilTicketKey.worktree: "",
            AnvilTicketKey.host: "",
        ])
    }

    // MARK: - State plumbing

    private func store(_ model: RunModel) {
        runs[model.id] = model
        broadcast(.runUpdated(model))
    }

    private func enqueue(_ pending: PendingInput) {
        queue.removeAll { $0.runID == pending.runID }
        queue.append(pending)
        broadcast(.queueChanged(queue))
    }

    private func dequeue(_ runID: RunID) {
        let before = queue.count
        queue.removeAll { $0.runID == runID }
        if queue.count != before {
            broadcast(.queueChanged(queue))
        }
    }

    // Non-emitting: callers fold this into the next store.
    private func recordTkError(_ runID: RunID, _ error: Error) {
        runs[runID]?.lastTkError = (error as? TkError)?.description ?? "\(error)"
    }

    // The engine speaks namespaced ids (`project/slug`); the tk CLI wants the bare slug.
    static func bareID(_ ticketID: String) -> String {
        ticketID.split(separator: "/").last.map(String.init) ?? ticketID
    }
}
