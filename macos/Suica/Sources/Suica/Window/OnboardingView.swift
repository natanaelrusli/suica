import AppKit
import SuicaCore
import SwiftUI

/// Set up Suica, in place of the window's sidebar and pages while there is no config file: one step
/// at a time on a card over the backdrop, then the first config file and the agent.
struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    let backdrop: Backdrop
    /// Done on the last step: back to the pages, reloaded now that the agent runs.
    let onDone: () -> Void
    @Environment(\.motionLevel) private var motion

    private static let modelCliOptions = ["auto", "claude", "codex", "gemini"]

    var body: some View {
        // Centred, not scrolled: every step fits the window's minimum height, and a scroll view drew
        // its top edge effect across the backdrop.
        card
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            BackdropView(backdrop: backdrop == .plain ? .wash : backdrop, strength: 0.35)
                .ignoresSafeArea()
        }
        .background(.background)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            stepContent
                .id(model.step)
                .transition(Motion.page(motion))
                .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
            if let failure = model.failure {
                NoticeBox(text: failure, tint: .red, closable: false)
            }
            Divider()
            buttons
        }
        .padding(28)
        .frame(width: 560)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.separator.opacity(0.5)))
        .shadow(color: .black.opacity(0.12), radius: 24, y: 8)
        .motion(Motion.page, value: model.step)
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppIconView(size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.finished ? Copy.setupAllSet : Copy.setupStepTitle(model.step))
                    .font(.title2.weight(.semibold))
                Text("\(Copy.setupTitle) · \(model.step.rawValue + 1) of \(OnboardingStep.allCases.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 5) {
                ForEach(OnboardingStep.allCases, id: \.self) { step in
                    Capsule()
                        .fill(step.rawValue <= model.step.rawValue ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                        .frame(width: step == model.step ? 18 : 7, height: 7)
                }
            }
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var stepContent: some View {
        switch model.step {
        case .welcome: welcome
        case .gitlab: gitlab
        case .codingAgent: codingAgent
        case .teams: teams
        case .finish: finish
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Copy.setupWelcome)
            Text(Copy.setupWelcomeSteps).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var gitlab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Copy.setupGitlabHint).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text("https://").foregroundStyle(.secondary)
                // A pasted URL keeps only its host, as in Configuration.
                TextField(
                    Copy.setupHostPlaceholder,
                    text: Binding(get: { model.hostText }, set: { model.hostText = ConfigInputs.host(from: $0) }))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.checkConnection() } }
                Button(Copy.setupCheck) { Task { await model.checkConnection() } }
                    .disabled(model.host.isEmpty || model.checking)
            }
            if model.checking {
                ProgressView().controlSize(.small)
            } else if let error = model.checkError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if let check = model.check {
                checkResult(check)
            }
        }
    }

    @ViewBuilder private func checkResult(_ check: GitlabCheck) -> some View {
        if check.status == "ok" {
            Label(Copy.setupSignedIn(check.username ?? ""), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label(Copy.setupCheckLine(check.status), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                if let command = Copy.setupFixCommand(check.status, host: model.host) {
                    HStack {
                        Text(command).font(.callout.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button(Copy.setupCopy) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                        }
                        .controlSize(.small)
                    }
                    .padding(8)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                }
                Text(Copy.setupCheckLater).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var codingAgent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Copy.setupCodingAgentHint).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                ForEach(Self.modelCliOptions, id: \.self) { option in
                    AgentRow(option: option, picked: model.modelCli == option, clis: model.modelClis) {
                        withMotion(Motion.content, motion) { model.modelCli = option }
                    }
                }
            }
            if let missing = missingPick {
                Label(Copy.setupAgentMissingWarning(missing), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .transition(Motion.reveal(motion))
            }
        }
        .motion(value: missingPick)
    }

    /// The name of the picked CLI when the agent found it not installed.
    private var missingPick: String? {
        guard let cli = model.modelClis?.clis.first(where: { $0.id == model.modelCli }), cli.path == nil else {
            return nil
        }
        return cli.name
    }

    private var teams: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(Copy.setupTeamsToggle, isOn: $model.teamsEnabled).toggleStyle(.switch)
            Text(Copy.setupTeamsHint).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var finish: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.finished {
                Label {
                    Text(Copy.setupFinished).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    summaryRow(Copy.setupSummaryHost, model.host)
                    summaryRow(Copy.setupSummaryAgent, Copy.optionTitle("model.cli", model.modelCli) ?? model.modelCli)
                    summaryRow(Copy.setupSummaryTeams, model.teamsEnabled ? Copy.setupOn : Copy.setupOff)
                }
                Text(Copy.setupFinishHint).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func summaryRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).fontWeight(.medium)
        }
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack {
            Spacer()
            if model.finishing { ProgressView().controlSize(.small) }
            if model.step != .welcome && !model.finished {
                Button(Copy.setupBack) { withMotion(Motion.page, motion) { model.back() } }
                    .disabled(model.finishing)
            }
            primary
        }
    }

    @ViewBuilder private var primary: some View {
        if model.finished {
            Button(Copy.setupDone, action: onDone)
            .keyboardShortcut(.defaultAction)
        } else if model.step == .finish {
            Button(Copy.setupStart) { Task { await model.finish() } }
                .keyboardShortcut(.defaultAction)
                .disabled(model.finishing)
        } else {
            Button(Copy.setupContinue) { withMotion(Motion.page, motion) { model.next() } }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canContinue)
        }
    }
}

/// One coding agent CLI to pick: what it is, what it does here, and whether this Mac has it.
private struct AgentRow: View {
    let option: String
    let picked: Bool
    let clis: ModelCliStatus?
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(Copy.optionTitle("model.cli", option) ?? option).fontWeight(.semibold)
                        if let badge { badge }
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(picked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                picked ? AnyShapeStyle(.tint.opacity(0.1)) : AnyShapeStyle(.background.secondary),
                in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(picked ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator.opacity(0.6)), lineWidth: picked ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .opacity(installed == false ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private var symbol: String {
        switch option {
        case "auto": "wand.and.stars"
        case "claude": "sparkle"
        case "codex": "chevron.left.forwardslash.chevron.right"
        default: "diamond"
        }
    }

    private var tint: Color {
        switch option {
        case "auto": .accentColor
        case "claude": .orange
        case "codex": .gray
        default: .blue
        }
    }

    /// Nil for Auto, and while the agent has not said.
    private var installed: Bool? {
        clis?.clis.first { $0.id == option }.map { $0.path != nil }
    }

    private var detail: String {
        guard option == "auto" else { return Copy.optionDetail("model.cli", option) ?? "" }
        guard let clis else { return Copy.optionDetail("model.cli", option) ?? "" }
        let first = clis.clis.first { $0.path != nil }
        return first.map { Copy.setupAutoUses($0.name) } ?? Copy.setupAutoNone
    }

    private var badge: Badge? {
        if option == "auto" { return Badge(text: Copy.setupRecommended, tint: .tint) }
        return installed.map { $0 ? Badge(text: Copy.installed, tint: Color.green) : Badge(text: Copy.notInstalledShort, tint: Color.orange) }
    }
}
