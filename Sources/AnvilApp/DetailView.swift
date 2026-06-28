import SwiftUI
import AnvilUI
import AnvilEngine

struct DetailView: View {
    @Bindable var model: AppModel

    var body: some View {
        if let ticket = model.selectedTicket {
            TicketDetailPane(model: model, ticket: ticket)
                .id(ticket.id)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.text").font(.largeTitle).foregroundStyle(.tertiary)
                Text("Select a ticket").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct TicketDetailPane: View {
    @Bindable var model: AppModel
    let ticket: TicketSummary
    @State private var why = ""
    @State private var seededWhy = ""
    @State private var noteText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                Divider()
                grooming
                if let run = model.selectedRun {
                    Divider()
                    RunView(model: model, run: run)
                } else {
                    launchButton
                }
            }
            .padding(Theme.pad)
        }
        .onAppear { seed(model.detail?.description ?? "") }
        // Detail loads async after selection — only (re)seed if the user hasn't edited yet, so
        // a late-arriving load can't clobber in-progress typing.
        .onChange(of: model.detail?.description) { _, new in
            let value = new ?? ""
            if why == seededWhy { why = value }
            seededWhy = value
        }
    }

    private func seed(_ value: String) {
        why = value
        seededWhy = value
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(ticket.title).font(.title3.weight(.semibold))
                Spacer()
                Text("P\(ticket.priority)").font(Theme.mono).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                let kind = model.statusKind(for: ticket)
                Image(systemName: Theme.symbol(kind)).foregroundStyle(Theme.color(kind)).font(.caption)
                Text("\(ticket.type) · \(ticket.status)").font(.caption).foregroundStyle(.secondary)
                Text(ticket.id).font(Theme.monoSmall).foregroundStyle(.tertiary)
            }
        }
    }

    private var grooming: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Why") {
                TextEditor(text: $why)
                    .font(.callout).frame(minHeight: 54)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                Button("Save Why") { Task { await model.saveWhy(why) } }
                    .controlSize(.small)
            }
            if let success = model.detail?.acceptanceCriteria, !success.isEmpty {
                field("Success (read-only)") {
                    Text(success).font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack(spacing: 12) {
                Picker("Status", selection: Binding(
                    get: { ticket.status },
                    set: { value in Task { await model.setStatus(value) } }
                )) {
                    ForEach(["backlog", "ready", "open", "done", "closed"], id: \.self) { Text($0).tag($0) }
                }.frame(width: 160)
                Picker("Priority", selection: Binding(
                    get: { ticket.priority },
                    set: { value in Task { await model.setPriority(value) } }
                )) {
                    ForEach(0..<5) { Text("P\($0)").tag($0) }
                }.frame(width: 110)
            }
            .controlSize(.small)
            if let notes = model.detail?.notes, !notes.isEmpty {
                field("Notes") {
                    ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                        Text(note).font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            HStack {
                TextField("Add note…", text: $noteText).textFieldStyle(.roundedBorder).font(.callout)
                Button("Add") { Task { await model.addNote(noteText); noteText = "" } }
                    .controlSize(.small).disabled(noteText.isEmpty)
            }
        }
    }

    private var launchButton: some View {
        Button {
            Task { await model.launch(ticket.id) }
        } label: {
            Label("Launch  ⌘R", systemImage: "hammer.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
        .disabled(!model.canLaunch(ticket))
        .help(model.isLaunchable(ticket.project) ? "Run /work in a worktree" : "Project not cloned on this host")
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            content()
        }
    }
}
