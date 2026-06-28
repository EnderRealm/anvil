import SwiftUI
import AnvilUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: Binding(
            get: { model.selection },
            set: { if let new = $0 { model.selection = new } }
        )) {
            Section {
                row("Inbox", system: "tray", count: model.counts.inbox, tag: .inbox, accent: model.counts.inbox > 0)
                row("Ready", system: "circle", count: model.counts.ready, tag: .ready)
                row("Running", system: "circle.dotted", count: model.counts.running, tag: .running)
                row("All", system: "square.stack", count: model.counts.all, tag: .all)
            }
            Section("Projects") {
                ForEach(model.projects, id: \.name) { project in
                    HStack(spacing: 6) {
                        Image(systemName: project.launchable ? "hammer.fill" : "eye")
                            .font(.caption2)
                            .foregroundStyle(project.launchable ? Theme.accent : .secondary)
                            .help(project.launchable ? "Launchable here" : "Browse-only (not cloned)")
                        Text(project.name).font(.callout)
                        Spacer()
                        Text("\(model.ticketCount(project: project.name))")
                            .font(Theme.monoSmall).foregroundStyle(.secondary)
                    }
                    .tag(SidebarSelection.project(project.name))
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("anvil")
    }

    private func row(_ title: String, system: String, count: Int, tag: SidebarSelection, accent: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: system).font(.caption2).foregroundStyle(accent ? Color.orange : .secondary)
            Text(title).font(.callout)
            Spacer()
            Text("\(count)")
                .font(Theme.monoSmall)
                .foregroundStyle(accent ? Color.orange : .secondary)
        }
        .tag(tag)
    }
}
