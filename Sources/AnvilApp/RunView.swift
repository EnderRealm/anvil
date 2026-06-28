import SwiftUI
import AnvilUI
import AnvilEngine

struct RunView: View {
    @Bindable var model: AppModel
    let run: RunModel
    @State private var answerText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("RUN").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                stateBadge
                Spacer()
                if let session = run.sessionID {
                    Text(session.prefix(8)).font(Theme.monoSmall).foregroundStyle(.tertiary)
                }
            }

            if let branch = run.worktree?.branch {
                Text(branch).font(Theme.monoSmall).foregroundStyle(.secondary)
            }

            if case .needsInput(let question, let options) = run.state {
                needsInput(question: question, options: options)
            }

            if case .done(let summary) = run.state, let summary {
                Label(summary, systemImage: "checkmark.seal.fill").font(.callout).foregroundStyle(.green)
            }

            if case .failed(let message) = run.state {
                Label(message, systemImage: "xmark.octagon.fill").font(.callout).foregroundStyle(.red)
            }

            if let discrepancy = run.discrepancy {
                Label(discrepancy, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.yellow)
            }

            if !run.output.isEmpty {
                ScrollView {
                    Text(run.output)
                        .font(Theme.monoSmall)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 220)
                .background(.black.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            usageBar
        }
    }

    private var stateBadge: some View {
        let kind = StatusKind.of(ticket: TicketSummary(
            id: run.ticketID, project: "", status: "open", type: "", priority: 0,
            title: "", parent: nil, deps: [], tags: [], anvilState: nil
        ), run: run, ready: [], blocked: [])
        return HStack(spacing: 4) {
            Image(systemName: Theme.symbol(kind)).foregroundStyle(Theme.color(kind)).pulse(kind == .running)
            Text(Theme.label(kind)).foregroundStyle(Theme.color(kind))
        }
        .font(.caption)
    }

    private func needsInput(question: String, options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\"\(question)\"", systemImage: "circle.lefthalf.filled")
                .font(.callout.weight(.medium)).foregroundStyle(.orange)
            HStack {
                ForEach(options, id: \.self) { option in
                    Button(option) { Task { await model.answerSelected(text: option) } }
                        .controlSize(.small)
                }
            }
            HStack {
                TextField("Answer…", text: $answerText).textFieldStyle(.roundedBorder).font(.callout)
                Button("Answer  ⌘↵") { submit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .controlSize(.small)
                    .disabled(answerText.isEmpty)
            }
        }
        .padding(8)
        .background(.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var usageBar: some View {
        HStack(spacing: 10) {
            if let usage = run.usage {
                if let input = usage.inputTokens, let output = usage.outputTokens {
                    Text("\(formatTokens(input + output)) tok").font(Theme.monoSmall).foregroundStyle(.secondary)
                }
                if let cost = usage.totalCostUSD {
                    Text(String(format: "$%.2f", cost)).font(Theme.monoSmall).foregroundStyle(.secondary)
                }
                if let limit = usage.rateLimit?.rateLimitType {
                    Text(limit).font(Theme.monoSmall).foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
    }

    private func submit() {
        let text = answerText
        answerText = ""
        Task { await model.answerSelected(text: text) }
    }

    private func formatTokens(_ count: Int) -> String {
        count >= 1000 ? "\(count / 1000)k" : "\(count)"
    }
}
