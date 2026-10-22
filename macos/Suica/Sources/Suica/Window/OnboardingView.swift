import AppKit
import SuicaCore
import SwiftUI

/// The Set up Suica sheet: one step at a time, then the first config file and the agent.
struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    /// Reloads the window's pages once the agent runs.
    let onFinished: () -> Void
    @Environment(\.motionLevel) private var motion

    private static let modelCliOptions = ["auto", "claude", "codex", "gemini"]

    var body: some View {
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
        .padding(24)
        .frame(width: 540)
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
            ModelCliCards(
                selection: Binding(get: { model.modelCli }, set: { model.modelCli = $0 ?? "auto" }),
                options: Self.modelCliOptions,
                status: model.modelClis)
        }
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
            if !model.finished {
                Button(Copy.setupNotNow) { model.presented = false }
                    .disabled(model.finishing)
            }
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
            Button(Copy.setupDone) {
                model.presented = false
                onFinished()
            }
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
