import AppKit
import SuicaCore
import SwiftUI

struct QuickIdeaCapture: View {
    let model: IdeasModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Capture an idea").font(.title2.weight(.semibold))
            Text("Save a thought for later. Capture stays on this Mac and does not start an agent.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                .frame(minHeight: 170)
                .focused($focused)
                .accessibilityLabel("Idea text")
            if let error = model.errorText { NoticeBox(text: error, tint: .red) }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button {
                    Task {
                        model.draft = text
                        model.projectPath = ""
                        if await model.create() { text = ""; dismiss() }
                    }
                } label: {
                    if model.busy { ProgressView().controlSize(.small) } else { Label("Save idea", systemImage: "tray.and.arrow.down") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { focused = true }
    }
}

struct IdeasView: View {
    @Bindable var model: IdeasModel
    let office: OfficeModel
    let plans: PlansModel
    let navigator: Navigator
    @State private var showingPlanPicker = false
    @State private var showingPrompt = false
    @State private var creating = false
    @State private var pendingSelection: Int?
    @State private var showingDiscardAlert = false

    private var dirty: Bool {
        if creating { return !model.draft.isEmpty || !model.projectPath.isEmpty || !model.noteDraft.isEmpty }
        guard let idea = model.selected else { return !model.noteDraft.isEmpty }
        return idea.text != model.draft || (idea.projectPath ?? "") != model.projectPath || !model.noteDraft.isEmpty
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Picker("Ideas", selection: Binding(get: { model.archived }, set: { model.archived = $0; model.select(nil); Task { await model.load() } })) {
                        Text("Inbox").tag(false)
                        Text("Archived").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .disabled(dirty)
                    Button {
                        creating = true
                        model.select(nil)
                        model.draft = ""
                        model.projectPath = ""
                        model.reportError(nil)
                    } label: { Image(systemName: "plus") }
                    .help("New idea")
                    .disabled(dirty)
                }
                .padding(12)
                TextField("Search ideas and notes", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 12).padding(.bottom, 8)
                List(selection: Binding(get: { model.selectedId }, set: { pick($0) })) {
                    ForEach(model.matches) { idea in
                        IdeaRow(idea: idea, checked: model.selectedIDs.contains(idea.id), toggle: { model.toggleSelection(idea.id) })
                            .tag(idea.id)
                    }
                }
                .listStyle(.sidebar)
                HStack {
                    Text("\(model.selectedIDs.count) selected for brainstorm")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Brainstorm…") { showingPrompt = true; Task { await model.buildPrompt() } }
                        .disabled((model.selectedIDs.isEmpty && model.selectedId == nil) || dirty || creating)
                }
                .padding(10)
            }
            .frame(minWidth: 245, idealWidth: 290)

            detail
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await model.load(); await office.refresh(); await plans.refresh() }
        .alert("Discard unsaved idea edits?", isPresented: $showingDiscardAlert) {
            Button("Keep editing", role: .cancel) { pendingSelection = nil }
            Button("Discard", role: .destructive) {
                model.noteDraft = ""
                if creating {
                    creating = false
                    model.draft = ""
                    model.projectPath = ""
                }
                model.select(pendingSelection)
                pendingSelection = nil
            }
        } message: { Text("Your changes have not been saved.") }
        .sheet(isPresented: $showingPlanPicker) {
            IdeaPlanPicker(plans: plans) { path in
                Task { await model.linkPlan(path); showingPlanPicker = false }
            }
            .frame(minWidth: 420, minHeight: 360)
        }
        .sheet(isPresented: $showingPrompt) {
            BrainstormPromptSheet(model: model, office: office, navigator: navigator)
                .frame(minWidth: 560, minHeight: 520)
        }
    }

    @ViewBuilder private var detail: some View {
        if creating {
            createDetail
        } else if let idea = model.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(model.archived ? "Archived idea" : "Idea").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button { Task { await model.setArchived(!model.archived) } } label: {
                            Label(model.archived ? "Restore" : "Archive", systemImage: model.archived ? "tray.and.arrow.up" : "archivebox")
                        }
                        .disabled(model.busy || dirty)
                    }
                    TextEditor(text: $model.draft)
                        .font(.body).frame(minHeight: 150)
                        .padding(7).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Idea text")
                    if model.hasConflict {
                        Button("Reload saved version") { Task { await model.reloadCurrent() } }
                            .disabled(model.busy)
                    }
                    TextField("Project folder (optional)", text: $model.projectPath)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Text("Revision \(idea.revision)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Save changes") { Task { _ = await model.save() } }
                            .buttonStyle(.borderedProminent).disabled(!dirty || model.busy)
                    }
                    if !idea.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Notes", systemImage: "text.bubble")
                                .font(.headline)
                            ForEach(idea.notes) { note in
                                Text(note.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Add a note").font(.headline)
                        TextEditor(text: $model.noteDraft).frame(minHeight: 72)
                            .padding(5).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                        Button("Save note") { Task { await model.addNote() } }
                            .disabled(model.noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
                    }
                    links(idea)
                    if let text = model.errorText { NoticeBox(text: text, tint: .red) }
                    if let text = model.notice { NoticeBox(text: text, tint: .secondary) }
                }
                .padding(20)
            }
        } else {
            ContentUnavailableView("Select or capture an idea", systemImage: "lightbulb", description: Text("Thoughts, questions and plans stay available offline."))
        }
    }

    private var createDetail: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New idea").font(.title2.weight(.semibold))
            Text("Capture the thought as-is. Project folder is optional.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $model.draft)
                .font(.body).frame(minHeight: 180).padding(6)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            TextField("Project folder (optional)", text: $model.projectPath).textFieldStyle(.roundedBorder)
            if let error = model.errorText { NoticeBox(text: error, tint: .red) }
            HStack {
                Button("Cancel") { creating = false; model.draft = ""; model.projectPath = "" }
                Spacer()
                Button("Save idea") {
                    Task { if await model.create() { creating = false } }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func links(_ idea: Idea) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Linked plans", systemImage: "doc.text")
                    .font(.headline)
                Spacer()
                Button("Link plan…") { showingPlanPicker = true }
            }
            if idea.planPaths.isEmpty { Text("No plans linked.").font(.caption).foregroundStyle(.secondary) }
            ForEach(idea.planPaths, id: \.self) { path in
                Button {
                    guard FileManager.default.fileExists(atPath: path) else { model.reportError("This linked plan is unavailable at its saved location: \(path)"); return }
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                } label: {
                    Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: FileManager.default.fileExists(atPath: path) ? "doc.text" : "doc.text.magnifyingglass")
                }
                .buttonStyle(.link)
                .help(path)
            }
            if !idea.sessions.isEmpty {
                Label("Linked discussions", systemImage: "bubble.left.and.bubble.right").font(.headline).padding(.top, 6)
                ForEach(idea.sessions) { link in
                    if let session = office.sessions.first(where: { $0.agent == link.agent && $0.sessionId == link.sessionId }) {
                        Button {
                            office.select(session.id)
                            navigator.selection = .section(.office)
                        } label: {
                            Label("\(link.agent) · \(link.sessionId)", systemImage: "bubble.left.and.bubble.right")
                        }
                        .buttonStyle(.link)
                    } else {
                        Text("\(link.agent) · \(link.sessionId) — unavailable")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            .help("The linked conversation is no longer available. The idea and notes are still saved.")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pick(_ id: Int?) {
        guard id != model.selectedId else { return }
        if dirty { pendingSelection = id; showingDiscardAlert = true }
        else { creating = false; model.select(id) }
    }
}
private struct IdeaPlanPicker: View {
    let plans: PlansModel
    let link: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Link an existing plan").font(.title2.weight(.semibold))
            Text("Only plans found in your configured Plans folders are listed.")
                .font(.callout).foregroundStyle(.secondary)
            if plans.plans.isEmpty {
                ContentUnavailableView("No local plans found", systemImage: "doc.text.magnifyingglass",
                                       description: Text("Add a folder in Plans, then return here."))
            } else {
                List(plans.plans) { plan in
                    Button {
                        link(plan.path)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(plan.title).font(.body.weight(.medium))
                            Text(plan.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack { Spacer(); Button("Cancel") { dismiss() } }
        }
        .padding(18)
    }
}


private struct IdeaRow: View {
    let idea: Idea
    let checked: Bool
    let toggle: () -> Void

    private var title: String {
        idea.text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "Untitled idea"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: toggle) { Image(systemName: checked ? "checkmark.circle.fill" : "circle") }
                .buttonStyle(.plain).foregroundStyle(checked ? Color.accentColor : Color.secondary)
                .help(checked ? "Remove from brainstorm selection" : "Select for brainstorm")
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium)).lineLimit(2)
                Text(idea.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 6) {
                    if let project = idea.projectPath { Label(URL(fileURLWithPath: project).lastPathComponent, systemImage: "folder").lineLimit(1) }
                    if !idea.notes.isEmpty { Label("\(idea.notes.count)", systemImage: "text.bubble") }
                }.font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contextMenu { Button(checked ? "Remove from brainstorm" : "Select for brainstorm", action: toggle) }
    }
}

private struct BrainstormPromptSheet: View {
    @Bindable var model: IdeasModel
    let office: OfficeModel
    let navigator: Navigator
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSessionId = ""

    private var availableSessions: [OfficeSession] {
        office.sessions.filter { $0.status == .idle && ["claude", "codex", "gemini"].contains($0.agent) }
    }
    private var chosenSession: OfficeSession? { availableSessions.first { $0.id == selectedSessionId } }

    private func projectMismatch(for session: OfficeSession) -> Bool {
        let selected = model.selectedIDs.isEmpty ? model.selectedId.map { [$0] } ?? [] : model.selectedIDs.sorted()
        let paths = selected.compactMap { id in model.ideas.first(where: { $0.id == id })?.projectPath }
        func related(_ first: String, _ second: String) -> Bool {
            let a = URL(fileURLWithPath: first).standardizedFileURL.path
            let b = URL(fileURLWithPath: second).standardizedFileURL.path
            return a == b || b.hasPrefix(a.hasSuffix("/") ? a : a + "/")
                || a.hasPrefix(b.hasSuffix("/") ? b : b + "/")
        }
        return paths.contains { !related($0, session.cwd) && !related($0, session.room) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Brainstorm ideas").font(.title2.weight(.semibold))
                    Text("Preview the complete prompt before sharing it.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            TextField("Optional question", text: $model.promptQuestion, prompt: Text("What would you like to explore?"))
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Refresh prompt") { Task { await model.buildPrompt() } }.disabled(model.busy)
                if let length = model.prompt?.length, let maxLength = model.prompt?.maxLength {
                    Text("\(length) / \(maxLength) characters").font(.caption)
                        .foregroundStyle(model.prompt?.withinLimit == true ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                }
                Spacer()
                Button("Copy brainstorm prompt") { _ = model.copyPrompt() }
                    .disabled(model.prompt?.status != "ok")
            }
            if let prompt = model.prompt, let text = prompt.prompt {
                TextEditor(text: .constant(text)).font(.system(.body, design: .monospaced))
                    .textSelection(.enabled).frame(minHeight: 210)
                    .padding(6).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                if prompt.withinLimit == false {
                    NoticeBox(text: "The full prompt is available to copy, but exceeds Office’s 8,000-character limit. Narrow your selection before sending to Office.", tint: .orange)
                }
            } else {
                ContentUnavailableView("No prompt yet", systemImage: "text.quote", description: Text(model.errorText ?? "Build a prompt to preview it."))
            }
            if let error = model.errorText { NoticeBox(text: error, tint: .red) }
            if let notice = model.notice { NoticeBox(text: notice, tint: .secondary) }
            if model.hasConflict { NoticeBox(text: "Reload the saved version before brainstorming; the prompt uses saved idea content.", tint: .orange) }
            Divider()
            Text("Discussion-only guidance is not a sandbox. The agent retains its existing permissions and context; it may send this content to its configured provider.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let session = chosenSession, projectMismatch(for: session) {
                NoticeBox(text: "This Office session’s project folder differs from at least one selected idea’s project. Review the destination before sending.", tint: .orange)
            }
            HStack {
                Picker("Idle Office session", selection: $selectedSessionId) {
                    Text("Choose a session").tag("")
                    ForEach(availableSessions) { session in
                        Text("\(session.heading) — \(session.room)").tag(session.id)
                    }
                }
                .frame(maxWidth: .infinity)
                Button("Brainstorm in Office") {
                    guard let session = availableSessions.first(where: { $0.id == selectedSessionId }) else { return }
                    Task {
                        if await model.handoff(to: session, office: office) {
                            dismiss()
                            navigator.selection = .section(.office)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedSessionId.isEmpty || model.prompt?.withinLimit != true || model.busy)
            }
        }
        .padding(18)
        .task { if model.prompt == nil { await model.buildPrompt() } }
    }
}

