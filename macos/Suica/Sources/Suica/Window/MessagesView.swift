import SuicaCore
import SwiftUI

/// The popover's lists, on the same `MenuModel`, split into messages about your MRs and about
/// MRs you reviewed for others.
struct MessagesView: View {
    @Bindable var window: WindowModel
    @State private var query = ""
    @Environment(\.motionLevel) private var motion

    private var model: MenuModel { window.menu }
    private var group: MessageGroup { window.messageGroup }

    var body: some View {
        ScrollViewReader { proxy in
            list
                // A `suica://message/<id>` link selects a row: bring it into view.
                .onChange(of: window.selectedMessageId, initial: true) { _, id in
                    guard let id else { return }
                    // A search could hide the linked message.
                    query = ""
                    withMotion(Motion.content, motion) { proxy.scrollTo(id, anchor: .center) }
                }
        }
        .searchable(text: $query, placement: .toolbar, prompt: Copy.searchMessages)
        // Back to Your MRs, with nothing selected, the next time the page opens.
        .onDisappear {
            window.messageGroup = .yours
            window.selectedMessageId = nil
        }
    }

    private var list: some View {
        List {
            if let teams = model.state?.teams {
                Picker("", selection: $window.messageGroup.animation(Motion.animation(Motion.content, motion))) {
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
                NoticeBox(text: text, tint: .red, onClose: model.dismissError).listRowSeparator(.hidden)
            }
            if let text = model.banner {
                NoticeBox(text: text, tint: .secondary, onClose: model.dismissBanner).listRowSeparator(.hidden)
            }
            if let teams = model.state?.teams {
                let attention = shown(teams.attention, in: group)
                let recent = shown(teams.recent, in: group)
                if searching, attention.isEmpty, recent.isEmpty {
                    noMatches(teams).listRowSeparator(.hidden)
                }
                // While searching, only sections with a match.
                if !searching || !attention.isEmpty {
                    Section(Copy.attentionHeading) {
                        if attention.isEmpty {
                            Label(Copy.attentionEmpty, systemImage: "checkmark.circle").foregroundStyle(.secondary)
                        }
                        ForEach(attention) { row($0) }
                        if teams.attentionHidden > 0 {
                            Text(Copy.moreHidden(teams.attentionHidden)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !recent.isEmpty {
                    Section(Copy.recentHeading(recent.count)) {
                        ForEach(recent) { row($0) }
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
            .help("\(Copy.refresh) (⌘R)")
            .keyboardShortcut("r")
        }
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private func shown(_ items: [OutboxItem], in group: MessageGroup) -> [OutboxItem] {
        items.filter { group.contains($0) && $0.matches(query) }
    }

    /// Says so when the other tab has matches, since the search looks in this tab only.
    private func noMatches(_ teams: TeamsSection) -> some View {
        let other: MessageGroup = group == .yours ? .others : .yours
        let elsewhere = shown(teams.attention + teams.recent, in: other).count
        let text = Copy.noMessagesMatch(query.trimmingCharacters(in: .whitespaces))
        let tab = other == .yours ? Copy.yourMRs : Copy.othersMRs
        return Text(elsewhere == 0 ? text : "\(text) \(Copy.matchesInOtherTab(elsewhere, tab))")
            .foregroundStyle(.secondary)
    }

    private func row(_ item: OutboxItem) -> some View {
        OutboxItemRow(model: model, item: item, highlighted: window.selectedMessageId == item.id)
            .id(item.id)
            .listRowSeparator(.hidden)
    }

    /// The tab name, with the number of its messages that need you.
    private func label(_ title: String, _ group: MessageGroup, _ teams: TeamsSection) -> String {
        let count = teams.attention.filter(group.contains).count
        return count == 0 ? title : "\(title) (\(count))"
    }
}
