import SwiftUI
import AnvilUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showPalette = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 240)
        } content: {
            TicketListView(model: model, searchFocused: $searchFocused)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        } detail: {
            DetailView(model: model)
        }
        .tint(Theme.accent)
        .safeAreaInset(edge: .bottom) {
            if let error = model.lastError {
                ErrorBanner(message: error) { model.dismissError() }
            }
        }
        .background(shortcuts)
        .sheet(isPresented: $showPalette) {
            CommandPalette(model: model, isPresented: $showPalette)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("ANVIL").font(.headline.monospaced()).foregroundStyle(Theme.accent)
            }
        }
    }

    // Dismissible banner for the most recent failure — a control plane must not fail silently.
    private struct ErrorBanner: View {
        let message: String
        let dismiss: () -> Void
        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.white)
                Text(message).font(.callout).foregroundStyle(.white).lineLimit(2)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.white)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.red.opacity(0.85))
        }
    }

    // Hidden buttons capture window-scoped keyboard shortcuts.
    private var shortcuts: some View {
        Group {
            Button("") { showPalette.toggle() }
                .keyboardShortcut("k", modifiers: .command)
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
            Button("") { Task { await model.launchSelected() } }
                .keyboardShortcut("r", modifiers: .command)
            Button("") { Task { await model.refresh() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }
}
