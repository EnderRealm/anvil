import SwiftUI
import AnvilUI
import AnvilEngine

struct TicketListView: View {
    @Bindable var model: AppModel
    var searchFocused: FocusState<Bool>.Binding

    private var title: String {
        switch model.selection {
        case .inbox: return "INBOX"
        case .ready: return "READY"
        case .running: return "RUNNING"
        case .all: return "ALL"
        case .project(let name): return name.uppercased()
        }
    }

    var body: some View {
        let items = model.visibleTickets
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.caption2).foregroundStyle(.secondary)
                TextField("Filter…", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused(searchFocused)
            }
            .padding(.horizontal, Theme.pad)
            .padding(.vertical, 6)
            Divider()

            HStack {
                Text("\(title) · \(items.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, Theme.pad)
            .padding(.top, 6)
            .padding(.bottom, 2)

            if items.isEmpty {
                emptyState
            } else {
                List(selection: Binding(
                    get: { model.selectedTicketID },
                    set: { model.select($0) }
                )) {
                    ForEach(items, id: \.id) { ticket in
                        TicketRow(ticket: ticket, kind: model.statusKind(for: ticket), blocked: model.selection == .inbox)
                            .tag(ticket.id)
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(title)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray").font(.largeTitle).foregroundStyle(.tertiary)
            Text(model.searchText.isEmpty ? "Nothing here" : "No matches")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TicketRow: View {
    let ticket: TicketSummary
    let kind: StatusKind
    var blocked: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: Theme.symbol(kind))
                .font(.caption)
                .foregroundStyle(Theme.color(kind))
                .pulse(kind == .running)
            VStack(alignment: .leading, spacing: 1) {
                Text(ticket.title).font(.callout).lineLimit(1)
                Text(ticket.id).font(Theme.monoSmall).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            if kind == .needsInput {
                Image(systemName: "arrowtriangle.left.fill").font(.caption2).foregroundStyle(.orange)
            }
            Text("P\(ticket.priority)").font(Theme.monoSmall).foregroundStyle(.secondary)
        }
        .padding(.vertical, Theme.rowSpacing)
    }
}
