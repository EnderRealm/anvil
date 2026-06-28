import AnvilEngine

extension RunState {
    /// A run that has finished (no further events) — relaunchable.
    public var isTerminal: Bool {
        switch self {
        case .done, .failed, .canceled: return true
        case .queued, .running, .needsInput: return false
        }
    }

    /// A run that is in flight (or waiting for the human) — occupies the "running" lane.
    public var isActive: Bool {
        switch self {
        case .queued, .running, .needsInput: return true
        case .done, .failed, .canceled: return false
        }
    }
}
