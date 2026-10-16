import SuicaCore
import SwiftUI

struct ItemRow: View {
    let item: OutboxItem
    let busy: Bool
    let confirming: Bool
    let onAction: (ItemAction) -> Void
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var name: String { DisplayText.clean(item.recipientName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(Copy.kindLabel(item.kind)) → \(name)").fontWeight(.semibold).lineLimit(1)
                Spacer()
                Text(item.status).font(.caption).foregroundStyle(.secondary)
            }
            if let url = DisplayText.safeURL(item.mrUrl) {
                Link(DisplayText.clean(item.mrKey), destination: url).font(.caption)
            } else {
                Text(DisplayText.clean(item.mrKey)).font(.caption).foregroundStyle(.secondary)
            }
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.orange)
            }
            if item.state == .pending, let text = item.text {
                Text(DisplayText.clean(text, max: confirming ? 600 : 200))
                    .font(.callout)
                    .lineLimit(confirming ? nil : 4)
                    .textSelection(.enabled)
            }
            if confirming {
                Text(Copy.confirmTitle(name)).fontWeight(.semibold)
                HStack {
                    Button(Copy.confirmSend, action: onConfirm).keyboardShortcut(.defaultAction)
                    Button(Copy.confirmCancel, action: onCancel)
                }
            } else if !item.actions.isEmpty {
                HStack {
                    ForEach(Array(item.actions.enumerated()), id: \.offset) { _, action in
                        Button(label(for: action)) { onAction(action) }.disabled(busy)
                    }
                    if busy { ProgressView().controlSize(.small) }
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
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
