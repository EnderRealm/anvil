import SwiftUI
import AnvilUI

/// Dark-first dense theme: one restrained ember accent for the brand, distinct from the
/// semantic status palette. Monospace for ids/branch/session/cost.
enum Theme {
    /// Brand accent — forge/ember, used sparingly (selection, primary action).
    static let accent = Color(red: 0.93, green: 0.46, blue: 0.16)

    static let rowSpacing: CGFloat = 2
    static let pad: CGFloat = 8

    static let mono = Font.system(.caption, design: .monospaced)
    static let monoSmall = Font.system(size: 11, design: .monospaced)

    /// Semantic status color — ready neutral, running blue, needs-input amber (grabs the eye),
    /// done green, failed red, blocked/backlog gray.
    static func color(_ kind: StatusKind) -> Color {
        switch kind {
        case .ready, .open: return .secondary
        case .running: return .blue
        case .needsInput: return .orange
        case .done: return .green
        case .failed: return .red
        case .blocked, .backlog, .closed: return .gray
        }
    }

    static func symbol(_ kind: StatusKind) -> String {
        switch kind {
        case .ready, .open: return "circle"
        case .running: return "circle.dotted"
        case .needsInput: return "circle.lefthalf.filled"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .blocked: return "minus.circle"
        case .backlog: return "circle.dashed"
        case .closed: return "circle.slash"
        }
    }

    static func label(_ kind: StatusKind) -> String {
        switch kind {
        case .ready: return "ready"
        case .running: return "running"
        case .needsInput: return "needs-input"
        case .done: return "done"
        case .failed: return "failed"
        case .blocked: return "blocked"
        case .backlog: return "backlog"
        case .open: return "open"
        case .closed: return "closed"
        }
    }
}

/// Subtle pulse for in-flight runs (no spinners).
struct PulseModifier: ViewModifier {
    let active: Bool
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .opacity(active ? (on ? 0.45 : 1.0) : 1.0)
            .animation(active ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: on)
            .onAppear { if active { on = true } }
    }
}

extension View {
    func pulse(_ active: Bool) -> some View { modifier(PulseModifier(active: active)) }
}
