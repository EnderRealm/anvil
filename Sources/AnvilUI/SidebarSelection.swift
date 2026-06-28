import Foundation

/// What the sidebar has selected: a cross-project view or a single project.
public enum SidebarSelection: Hashable, Sendable {
    case inbox
    case ready
    case running
    case all
    case project(String)
}
