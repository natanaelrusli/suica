import SuicaCore
import SwiftUI

/// The popover's lists, on the same `MenuModel`.
struct MessagesView: View {
    let model: MenuModel

    var body: some View {
        List {
            if let text = model.errorText {
                NoticeBox(text: text, tint: .red).listRowSeparator(.hidden)
            }
            if let text = model.banner {
                NoticeBox(text: text, tint: .secondary).listRowSeparator(.hidden)
            }
            if let teams = model.state?.teams {
                Section(Copy.attentionHeading) {
                    if teams.attention.isEmpty {
                        Text(Copy.attentionEmpty).foregroundStyle(.secondary)
                    }
                    ForEach(teams.attention) { OutboxItemRow(model: model, item: $0).listRowSeparator(.hidden) }
                    if teams.attentionHidden > 0 {
                        Text(Copy.moreHidden(teams.attentionHidden)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !teams.recent.isEmpty {
                    Section(Copy.recentHeading) {
                        ForEach(teams.recent) { OutboxItemRow(model: model, item: $0).listRowSeparator(.hidden) }
                    }
                }
            } else if model.state != nil {
                Text(Copy.teamsDisabled).foregroundStyle(.secondary)
            } else if model.errorText == nil {
                ProgressView(Copy.loading)
            }
        }
        .task { await model.refresh() }
        .toolbar {
            Button { Task { await model.refresh() } } label: {
                Label(Copy.refresh, systemImage: "arrow.clockwise")
            }
            .help(Copy.refresh)
        }
    }
}
