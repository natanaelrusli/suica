import SuicaCore
import SwiftUI

private enum MessageGroup: Hashable {
    case yours, others

    func contains(_ item: OutboxItem) -> Bool { item.isAboutYourMR == (self == .yours) }
}

/// The popover's lists, on the same `MenuModel`, split into messages about your MRs and about
/// MRs you reviewed for others.
struct MessagesView: View {
    let model: MenuModel
    @State private var group: MessageGroup = .yours

    var body: some View {
        List {
            if let teams = model.state?.teams {
                Picker("", selection: $group.animation(Motion.content)) {
                    Text(label(Copy.yourMRs, .yours, teams)).tag(MessageGroup.yours)
                    Text(label(Copy.othersMRs, .others, teams)).tag(MessageGroup.others)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowSeparator(.hidden)
                Text(group == .yours ? Copy.yourMRsHint : Copy.othersMRsHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
            if let text = model.errorText {
                NoticeBox(text: text, tint: .red).listRowSeparator(.hidden)
            }
            if let text = model.banner {
                NoticeBox(text: text, tint: .secondary).listRowSeparator(.hidden)
            }
            if let teams = model.state?.teams {
                let attention = teams.attention.filter(group.contains)
                let recent = teams.recent.filter(group.contains)
                Section(Copy.attentionHeading) {
                    if attention.isEmpty {
                        Label(Copy.attentionEmpty, systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    }
                    ForEach(attention) { OutboxItemRow(model: model, item: $0).listRowSeparator(.hidden) }
                    if teams.attentionHidden > 0 {
                        Text(Copy.moreHidden(teams.attentionHidden)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !recent.isEmpty {
                    Section(Copy.recentHeading(recent.count)) {
                        ForEach(recent) { OutboxItemRow(model: model, item: $0).listRowSeparator(.hidden) }
                    }
                }
            } else if model.state != nil {
                Text(Copy.teamsDisabled).foregroundStyle(.secondary)
            } else if model.errorText == nil {
                ProgressView(Copy.loading)
            }
        }
        .motion(value: model.errorText)
        .motion(value: model.banner)
        .motion(value: model.state?.teams)
        .motion(value: group)
        .task { await model.refresh() }
        .toolbar {
            Button { Task { await model.refresh() } } label: {
                Label(Copy.refresh, systemImage: "arrow.clockwise")
            }
            .help(Copy.refresh)
        }
    }

    /// The tab name, with the number of its messages that need you.
    private func label(_ title: String, _ group: MessageGroup, _ teams: TeamsSection) -> String {
        let count = teams.attention.filter(group.contains).count
        return count == 0 ? title : "\(title) (\(count))"
    }
}
