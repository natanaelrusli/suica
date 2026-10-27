import AppKit
import SuicaCore
import SwiftUI

extension PlanStatus {
    var tint: Color {
        switch self {
        case .planned: .gray
        case .inProgress: .blue
        case .inReview: .orange
        case .done: .green
        case .dropped: .red
        }
    }
}

/// The plans of the Owner's folders: the list on the left, the selected plan and its marks on the right.
struct PlansView: View {
    @Bindable var model: PlansModel
    @State private var selectedPath: String?

    var body: some View {
        Group {
            if model.folders.isEmpty {
                ContentUnavailableView {
                    Label(Copy.noPlanFoldersTitle, systemImage: "folder.badge.plus")
                } description: {
                    Text(Copy.noPlanFoldersHint)
                } actions: {
                    Button(Copy.addPlanFolder, action: addFolders).buttonStyle(.borderedProminent)
                }
            } else if model.plans.isEmpty && !model.isScanning {
                ContentUnavailableView(Copy.noPlansTitle, systemImage: "list.bullet.clipboard", description: Text(Copy.noPlansHint))
            } else {
                split
            }
        }
        .task { await model.refresh() }
        .toolbar {
            Menu {
                ForEach(model.folders, id: \.self) { folder in
                    Button("\(folder) ✕") {
                        model.removeFolder(folder)
                        Task { await model.refresh() }
                    }
                }
            } label: { Label(Copy.plansFolders, systemImage: "folder") }
            .disabled(model.folders.isEmpty)
            Button(action: addFolders) { Label(Copy.addPlanFolder, systemImage: "folder.badge.plus") }
            Button { Task { await model.refresh() } } label: { Label(Copy.rescanPlans, systemImage: "arrow.clockwise") }
                .keyboardShortcut("r")
                .disabled(model.isScanning)
        }
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        panel.prompt = Copy.addFoldersPrompt
        guard panel.runModal() == .OK else { return }
        model.addFolders(panel.urls.map(\.path))
        Task { await model.refresh() }
    }

    private var split: some View {
        UnderTitleBar { titleBar in
            HStack(spacing: 0) {
                list(titleBar: titleBar).frame(width: 340)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.top, titleBar)
            }
        }
        .searchable(text: $model.query, placement: .toolbar, prompt: Copy.searchPlans)
    }

    private func list(titleBar: CGFloat) -> some View {
        let shown = model.visible
        return List(selection: $selectedPath) {
            if shown.isEmpty { Text(Copy.noPlansMatch).foregroundStyle(.secondary).listRowSeparator(.hidden) }
            ForEach(shown) { plan in PlanRow(plan: plan, status: model.status(of: plan), isSet: model.hasSetStatus(plan)).tag(plan.path) }
        }
        .modifier(ListTopBar(titleBar: titleBar) { statusChips })
    }

    private var statusChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(PlanStatus.allCases) { status in
                    let on = model.filter == status
                    Button { model.filter = on ? nil : status } label: {
                        Text("\(status.title) \(model.counts[status] ?? 0)")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(on ? AnyShapeStyle(status.tint.opacity(0.25)) : AnyShapeStyle(.quaternary.opacity(0.5)), in: Capsule())
                            .foregroundStyle(on ? status.tint : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
    }

    @ViewBuilder private var detail: some View {
        if let plan = model.plans.first(where: { $0.path == selectedPath }) {
            PlanDetail(model: model, plan: plan).id(plan.path)
        } else {
            ContentUnavailableView(Copy.plans, systemImage: "list.bullet.clipboard")
        }
    }
}

private struct PlanRow: View {
    let plan: PlanDocument
    let status: PlanStatus
    let isSet: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(DisplayText.clean(plan.title, max: 160)).fontWeight(.medium).lineLimit(2)
                Spacer(minLength: 4)
                Badge(text: status.title, tint: status.tint).opacity(isSet ? 1 : 0.7)
            }
            if let goal = plan.goal {
                Text(DisplayText.clean(goal, max: 200)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 6) {
                if let date = plan.date { Text(date) }
                Text(Copy.planSteps(done: plan.stepsDone, total: plan.stepsTotal))
            }
            .font(.caption).foregroundStyle(.tertiary)
            if plan.stepsTotal > 0 {
                ProgressView(value: Double(plan.stepsDone), total: Double(plan.stepsTotal)).controlSize(.small)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

private struct PlanDetail: View {
    let model: PlansModel
    let plan: PlanDocument
    @State private var note = ""

    private var statusChoice: Binding<PlanStatus?> {
        Binding(get: { model.hasSetStatus(plan) ? model.status(of: plan) : nil }, set: { model.setStatus($0, for: plan) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(DisplayText.clean(plan.title, max: 200)).font(.title2.weight(.semibold))
                if let goal = plan.goal { Text(DisplayText.clean(goal, max: 600)).foregroundStyle(.secondary) }
                Picker(Copy.planStatusLabel, selection: statusChoice) {
                    Text("\(Copy.planStatusAuto) (\(plan.derivedStatus.title))").tag(PlanStatus?.none)
                    ForEach(PlanStatus.allCases) { Text($0.title).tag(PlanStatus?.some($0)) }
                }
                .frame(maxWidth: 360)
                TextField(Copy.planNotePrompt, text: $note)
                    .onSubmit { model.setNote(note, for: plan) }
                    .onChange(of: note) { _, text in model.setNote(text, for: plan) }
                if let spec = plan.spec {
                    LabeledContent(Copy.planSpec) { Text(spec).font(.callout.monospaced()).textSelection(.enabled) }
                }
                if !plan.tasks.isEmpty {
                    Text(Copy.planTasks).font(.headline)
                    ForEach(Array(plan.tasks.enumerated()), id: \.offset) { _, task in
                        HStack {
                            Image(systemName: task.total > 0 && task.done == task.total ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(task.done == task.total && task.total > 0 ? Color.green : Color.secondary)
                                .accessibilityHidden(true)
                            Text(DisplayText.clean(task.title, max: 160))
                            Spacer()
                            Text(Copy.planSteps(done: task.done, total: task.total)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Button(Copy.openPlan) { NSWorkspace.shared.open(URL(fileURLWithPath: plan.path)) }
                    Button(Copy.showInFinder) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: plan.path)]) }
                }
                Text(plan.path).font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { note = model.note(for: plan) }
    }
}
