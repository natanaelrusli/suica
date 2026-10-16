import AppKit
import MRACore
import SwiftUI

struct MenuView: View {
    let model: MenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusLine
            if let text = model.errorText {
                notice(text, tint: .red)
            }
            if let text = model.banner {
                notice(text, tint: .secondary)
            }
            content
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 380)
        .task { await model.refresh() }
    }

    private var statusLine: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(Copy.appName) · \(model.isPaused ? Copy.paused : Copy.running)").fontWeight(.bold)
            if let state = model.state {
                Text("\(Copy.tracked(state.trackedAuthored)) · \(Copy.waitingForYou(state.reviewRequested))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let teams = model.state?.teams {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Copy.attentionHeading).font(.headline)
                    if teams.attention.isEmpty {
                        Text(Copy.attentionEmpty).foregroundStyle(.secondary)
                    }
                    ForEach(teams.attention) { row($0) }
                    if teams.attentionHidden > 0 {
                        Text(Copy.moreHidden(teams.attentionHidden)).font(.caption).foregroundStyle(.secondary)
                    }
                    if !teams.recent.isEmpty {
                        DisclosureGroup(Copy.recentHeading) {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(teams.recent) { row($0) }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 420)
        } else if model.state != nil {
            Text(Copy.teamsDisabled).foregroundStyle(.secondary)
        }
    }

    private func row(_ item: OutboxItem) -> some View {
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

    private var footer: some View {
        HStack {
            Button(model.isPaused ? Copy.resume : Copy.pause) { Task { await model.togglePause() } }
            Button(Copy.refresh) { Task { await model.refresh() } }
            Spacer()
            Button(Copy.quit) { NSApplication.shared.terminate(nil) }
        }
    }

    private func notice(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.callout)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }
}
