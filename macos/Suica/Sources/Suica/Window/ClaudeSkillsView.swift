import AppKit
import SuicaCore
import SwiftUI

struct ClaudeSkillsView: View {
    @State private var library = ClaudeSkillLibrary()
    @State private var skills: [ClaudeSkill] = []
    @State private var selected: URL?
    @State private var query = ""
    @State private var working = false
    @State private var loaded = false
    @State private var error: String?
    @State private var previewRevision = 0
    @State private var trashCandidate: ClaudeSkill?
    @State private var confirmingTrash = false

    private var filtered: [ClaudeSkill] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return skills.filter {
            search.isEmpty || $0.name.localizedStandardContains(search) || sourceTitle($0).localizedStandardContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error {
                NoticeBox(text: error, tint: .red) { self.error = nil }
                    .padding(12)
            }
            HSplitView {
                skillList.frame(minWidth: 180, idealWidth: 225, maxWidth: 300)
                Group {
                    if let skill = skills.first(where: { $0.id == selected }) {
                        detail(skill).id(skill.id)
                    } else if loaded {
                        ContentUnavailableView(Copy.selectClaudeSkill, systemImage: "puzzlepiece.extension")
                    } else if error == nil {
                        ProgressView(Copy.loading)
                    }
                }
                .frame(minWidth: 230, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .searchable(text: $query, prompt: Copy.searchClaudeSkills)
        .toolbar {
            Button(action: importSkill) { Label(Copy.importClaudeSkill, systemImage: "folder.badge.plus") }
                .disabled(working)
            Button { Task { await update() } } label: { Label(Copy.refresh, systemImage: "arrow.clockwise") }
                .disabled(working)
                .keyboardShortcut("r")
        }
        .task { await update() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await update() }
        }
        .confirmationDialog(Copy.trashClaudeSkill, isPresented: $confirmingTrash, presenting: trashCandidate) { skill in
            Button(Copy.moveSkillToTrash, role: .destructive) {
                Task { await update { try await library.trash(skill); return nil } }
            }
            Button(Copy.cancel, role: .cancel) {}
        } message: { skill in
            Text(Copy.confirmTrashClaudeSkill(skill.name))
        }
    }

    private var skillList: some View {
        let matches = filtered
        return List(selection: $selected) {
            skillSection(Copy.personalClaudeSkills, matches.filter { $0.source == .personal })
            skillSection(Copy.disabledClaudeSkills, matches.filter { $0.source == .disabled })
            skillSection(Copy.pluginClaudeSkills, matches.filter { !$0.source.isPersonal })
        }
        .overlay {
            if loaded && matches.isEmpty {
                Text(skills.isEmpty ? Copy.noClaudeSkills : Copy.noMatchingClaudeSkills)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(12)
            }
        }
    }

    @ViewBuilder private func skillSection(_ title: String, _ entries: [ClaudeSkill]) -> some View {
        if !entries.isEmpty {
            Section(title) {
                ForEach(entries) { skill in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(skill.name).lineLimit(1)
                        if case .plugin(let name) = skill.source {
                            Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .tag(skill.id)
                }
            }
        }
    }

    private func detail(_ skill: ClaudeSkill) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(skill.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                Text(sourceTitle(skill)).font(.callout).foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { actions(skill) }
                    VStack(alignment: .leading, spacing: 8) { actions(skill) }
                }
                .disabled(working)
                Divider()
                ClaudeSkillPreview(library: library, skill: skill, revision: previewRevision)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    @ViewBuilder private func actions(_ skill: ClaudeSkill) -> some View {
        Button(Copy.showInFinder) { NSWorkspace.shared.activateFileViewerSelecting([skill.directory]) }
        if skill.source.isPersonal {
            Button(Copy.editClaudeSkill) {
                if !NSWorkspace.shared.open(skill.file) { error = Copy.skillEditorUnavailable }
            }
            Menu(Copy.skillActions) {
                Button(skill.source == .disabled ? Copy.enableClaudeSkill : Copy.disableClaudeSkill) {
                    Task { await update { try await library.toggle(skill) } }
                }
                Button(Copy.trashClaudeSkill, role: .destructive) {
                    trashCandidate = skill
                    confirmingTrash = true
                }
            }
            .fixedSize()
        }
    }

    private func sourceTitle(_ skill: ClaudeSkill) -> String {
        switch skill.source {
        case .personal: Copy.personalClaudeSkills
        case .disabled: Copy.disabledClaudeSkills
        case .plugin(let name): Copy.claudeSkillPlugin(name)
        }
    }

    private func importSkill() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = Copy.importClaudeSkillPrompt
        panel.message = Copy.importClaudeSkillHelp
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { await update { try await library.importSkill(from: folder) } }
    }

    private func update(_ operation: (() async throws -> URL?)? = nil) async {
        guard !working else { return }
        working = true
        defer { working = false }
        error = nil
        do {
            let preferred = try await operation?()
            skills = try await library.list()
            if let preferred { query = ""; selected = preferred }
            if !skills.contains(where: { $0.id == selected }) { selected = skills.first?.id }
            previewRevision += 1
            loaded = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ClaudeSkillPreview: View {
    let library: ClaudeSkillLibrary
    let skill: ClaudeSkill
    let revision: Int
    @State private var result: Result<String, Error>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SKILL.md").font(.headline)
            switch result {
            case .success(let content):
                Text(verbatim: content).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            case .failure(let error):
                Text(error.localizedDescription).foregroundStyle(.secondary)
            case nil:
                ProgressView().controlSize(.small)
            }
        }
        .task(id: revision) {
            do {
                let text = try await library.preview(skill)
                if !Task.isCancelled { result = .success(text) }
            } catch {
                if !Task.isCancelled { result = .failure(error) }
            }
        }
    }
}
