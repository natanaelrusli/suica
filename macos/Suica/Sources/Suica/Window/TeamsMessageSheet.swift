import SuicaCore
import SwiftUI

/// Writes a Teams message from an MR's page: pick who gets it and the template it starts from,
/// edit the text the agent drafts from that template, see it as Teams will, and send it now.
struct TeamsMessageSheet: View {
    let detail: MergeRequestDetail
    let model: ReviewsModel
    /// Called with the recipient's name once the message is sent.
    let onSent: (String) -> Void
    @State private var recipient: MessageRecipient?
    @State private var template = ""
    @State private var text = ""
    @State private var drafting = false
    @State private var sending = false
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    private var yours: Bool { model.isYours(detail.key) }
    private var recipients: [MessageRecipient] {
        TeamsMessageChoices.recipients(detail, me: model.list?.me, yours: yours)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Copy.messageOnTeams.replacingOccurrences(of: "…", with: "")).font(.headline)
            Text(DisplayText.clean(detail.title, max: 200)).foregroundStyle(.secondary).lineLimit(2)
            if recipients.isEmpty {
                NoticeBox(text: Copy.noOneToMessage, tint: .secondary, closable: false)
            } else {
                form
            }
            if let problem { NoticeBox(text: problem, tint: .red) }
            HStack {
                Text(Copy.messageSendsNow).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(Copy.cancel, role: .cancel) { dismiss() }
                Button(Copy.sendMessage) { Task { await send() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        recipient == nil || drafting || sending
                            || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            guard recipient == nil, let first = recipients.first else { return }
            recipient = first
            template = TeamsMessageChoices.defaultTemplate(for: first, in: detail, me: model.list?.me, yours: yours)
        }
        // A new recipient or template drafts the text again from the template.
        .task(id: "\(recipient?.username ?? "")|\(template)") { await draft() }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(Copy.messageTo, selection: $recipient) {
                ForEach(recipients, id: \.self) { person in
                    Text(
                        Copy.messageRecipient(
                            DisplayText.clean(person.name, max: 60),
                            role: person.isAuthor ? Copy.authorRole : Copy.reviewerRole)
                    )
                    .tag(Optional(person))
                }
            }
            Picker(Copy.messageTemplate, selection: $template) {
                ForEach(TeamsMessageChoices.templates(yours: yours), id: \.self) { name in
                    Text(Copy.templateLabel(name)).tag(name)
                }
            }
            .pickerStyle(.segmented)
            HStack(spacing: 6) {
                Text(Copy.messageText).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if drafting {
                    ProgressView().controlSize(.mini)
                    Text(Copy.messageDrafting).font(.caption).foregroundStyle(.secondary)
                }
            }
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 90, maxHeight: 140)
                .editorBox()
                .disabled(drafting || sending)
            Text(Copy.messagePreview).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                TeamsMessagePreview(recipient: recipient?.name ?? "", text: text)
            }
            .frame(maxHeight: 200)
        }
    }

    private func draft() async {
        guard let recipient, !template.isEmpty else { return }
        drafting = true
        problem = nil
        let reply = await model.draftMessage(detail.key, to: recipient.username, template: template)
        // A newer pick may have started its own draft while this one ran.
        guard !Task.isCancelled else { return }
        drafting = false
        if let draft = reply.text { text = draft } else { problem = Copy.messageOutcome(reply) }
    }

    private func send() async {
        guard let recipient else { return }
        sending = true
        problem = nil
        let reply = await model.sendMessage(detail.key, to: recipient.username, template: template, text: text)
        sending = false
        if reply.status == "sent" {
            dismiss()
            onSent(recipient.name)
        } else {
            problem = Copy.messageOutcome(reply)
        }
    }
}
