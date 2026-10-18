import SuicaCore
import SwiftUI

struct ItemRow: View {
    let item: OutboxItem
    let busy: Bool
    let confirming: Bool
    let onAction: (ItemAction) -> Void
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var name: String { DisplayText.clean(item.recipientName) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            kindIcon
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Copy.kindLabel(item.kind)) → \(name)").fontWeight(.semibold).lineLimit(1)
                    Spacer(minLength: 6)
                    chip
                }
                mrLine
                if mrApproved {
                    Label(Copy.youApprovedMr, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if let hint {
                    Label(hint, systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
                }
                if item.state == .pending, let text = item.text {
                    Text(DisplayText.clean(text, max: confirming ? 600 : 200))
                        .font(.callout)
                        .lineLimit(confirming ? nil : 4)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Color.accentColor.opacity(0.6)).frame(width: 3)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                actions
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .motion(value: confirming)
        .motion(value: busy)
        .motion(value: item.status)
        .accessibilityElement(children: .contain)
    }

    private var mrApproved: Bool { item.mrApproved == true }

    @ViewBuilder private var kindIcon: some View {
        let icon = Image(systemName: kindSymbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(kindTint.gradient, in: Circle())
        if mrApproved {
            icon.help(Copy.youApprovedMr).accessibilityLabel(Copy.youApprovedMr)
        } else {
            icon.accessibilityHidden(true)
        }
    }

    private var kindSymbol: String {
        if mrApproved { return "checkmark" }
        return switch item.kind {
        case "nudge": "hand.wave.fill"
        case "reminder": "bell.fill"
        case "notice": "checkmark.bubble.fill"
        default: "bubble.left.fill"
        }
    }

    private var kindTint: Color {
        if mrApproved { return .green }
        return switch item.kind {
        case "nudge": .blue
        case "reminder": .orange
        case "notice": .teal
        default: .gray
        }
    }

    @ViewBuilder private var mrLine: some View {
        VStack(alignment: .leading, spacing: 1) {
            let title = DisplayText.clean(item.mrTitle, max: 120)
            if !title.isEmpty {
                Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 4) {
                if let url = DisplayText.safeURL(item.mrUrl) {
                    Link(DisplayText.clean(item.mrKey), destination: url)
                } else {
                    Text(DisplayText.clean(item.mrKey)).foregroundStyle(.secondary)
                }
                Text("·").foregroundStyle(.tertiary)
                Text(updated).foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    private var updated: String {
        Date(timeIntervalSince1970: TimeInterval(item.updatedAt) / 1000)
            .formatted(.relative(presentation: .named))
    }

    /// Finished rows say how they ended, above all whether you approved them; open rows say what
    /// they are waiting for.
    private var chip: Chip {
        if let outcome = item.outcome {
            return Chip(text: Copy.outcomeLabel(outcome), symbol: symbol(for: outcome), tint: tint(for: outcome))
        }
        let tint: Color =
            switch item.state {
            case .pending: .orange
            case .unresolved, .failed: .red
            default: .secondary
            }
        let symbol =
            switch item.state {
            case .pending: "hourglass"
            case .sending: "paperplane"
            case .unresolved: "person.fill.questionmark"
            case .queued: "tray"
            default: "questionmark.circle"
            }
        return Chip(text: Copy.stateLabel(item.state), symbol: symbol, tint: tint)
    }

    private func symbol(for outcome: ItemOutcome) -> String {
        switch outcome {
        case .approvedByYou: "person.fill.checkmark"
        case .sentAutomatically: "bolt.fill"
        case .sent: "paperplane.fill"
        case .skippedByYou, .skipped: "xmark.circle"
        case .noLongerNeeded: "minus.circle"
        case .dryRun: "eye"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func tint(for outcome: ItemOutcome) -> Color {
        switch outcome {
        case .approvedByYou: .blue
        case .sentAutomatically: .secondary
        case .dryRun: .purple
        case .failed: .red
        case .sent, .skippedByYou, .noLongerNeeded, .skipped: .secondary
        }
    }

    @ViewBuilder private var actions: some View {
        if confirming {
            VStack(alignment: .leading, spacing: 6) {
                Text(Copy.confirmTitle(name)).fontWeight(.semibold)
                HStack {
                    Button(Copy.confirmSend, action: onConfirm)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                    Button(Copy.confirmCancel, action: onCancel)
                }
            }
            .padding(.top, 2)
            .transition(Motion.reveal(reduceMotion: reduceMotion))
        } else if !item.actions.isEmpty {
            HStack {
                ForEach(Array(item.actions.enumerated()), id: \.offset) { _, action in
                    if action == .skip {
                        Button(label(for: action)) { onAction(action) }.disabled(busy)
                    } else {
                        Button(label(for: action)) { onAction(action) }
                            .buttonStyle(.borderedProminent)
                            .disabled(busy)
                    }
                }
                if busy { ProgressView().controlSize(.small).transition(.opacity) }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
    }

    private var hint: String? {
        switch item.state {
        case .sending: Copy.maybeSent
        case .failed: Copy.notRetried
        case .unresolved: Copy.needsPeople
        default: nil
        }
    }

    private func label(for action: ItemAction) -> String {
        switch action {
        case .send: Copy.send
        case .skip: Copy.skip
        case .retry: Copy.retry
        }
    }
}

/// One outbox row wired to the model: the popover and the window share this, and the model, so
/// an action started in one place blocks the other.
struct OutboxItemRow: View {
    let model: MenuModel
    let item: OutboxItem

    var body: some View {
        ItemRow(
            item: item,
            busy: model.busyIds.contains(item.id),
            confirming: model.confirmation?.id == item.id,
            onAction: { action in
                switch action {
                case .send: model.requestSend(item)
                case .skip: Task { await model.skip(item) }
                case .retry: Task { await model.retry(item) }
                }
            },
            onConfirm: { Task { await model.confirmSend() } },
            onCancel: { model.cancelConfirmation() })
    }
}
