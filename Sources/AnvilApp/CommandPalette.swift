import SwiftUI
import AnvilUI
import AnvilEngine

/// Basic ⌘K palette: fuzzy-jump to any ticket, then launch/select.
struct CommandPalette: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool
    @State private var query = ""
    @FocusState private var focused: Bool

    private var matches: [TicketSummary] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = model.tickets
        let filtered = q.isEmpty ? all : all.filter {
            $0.title.lowercased().contains(q) || $0.id.lowercased().contains(q)
        }
        return Array(filtered.prefix(20))
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Jump to ticket…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($focused)
            Divider()
            List {
                ForEach(matches, id: \.id) { ticket in
                    Button {
                        model.select(ticket.id)
                        isPresented = false
                    } label: {
                        HStack {
                            let kind = model.statusKind(for: ticket)
                            Image(systemName: Theme.symbol(kind)).foregroundStyle(Theme.color(kind)).font(.caption)
                            Text(ticket.title).lineLimit(1)
                            Spacer()
                            Text(ticket.id).font(Theme.monoSmall).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
        }
        .frame(width: 520, height: 360)
        .onAppear { focused = true }
    }
}
