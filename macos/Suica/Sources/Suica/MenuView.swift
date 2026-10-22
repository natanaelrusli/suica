import AppKit
import SuicaCore
import SwiftUI

struct MenuView: View {
    let model: MenuModel
    let window: WindowModel
    let reviews: ReviewsModel
    let settings: AppearanceSettings
    let navigator: Navigator
    let onboarding: OnboardingModel
    @State private var tab: PanelTab = .recent
    /// Set once the Owner picks a tab, so the opening refresh does not switch it back.
    @State private var tabPicked = false
    /// The outcome of a Cancel pressed here; the Reviews page's own banner is not repeated.
    @State private var cancelNotice: String?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.motionLevel) private var motion
    @Environment(\.metrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.gap * 0.75) {
            if onboarding.needsSetup {
                // Every command fails without a config file: no errors, only the way in.
                Spacer(minLength: 0)
                setupCard
                Spacer(minLength: 0)
            } else {
                content
            }
            Divider()
            footer
        }
        .padding(metrics.padding)
        .background(alignment: .top) {
            // Appearance → Backdrop behind the header, fading out before the content.
            BackdropView(backdrop: settings.backdrop, strength: settings.backdrop == .wash ? 0.16 : 0.3)
                .frame(height: 96)
        }
        // Fixed, so the lists have room even with one row in them.
        .frame(width: 460, height: 640, alignment: .top)
        // Grows out of the menu bar icon when it opens and shrinks back into it when it closes.
        .background(MenuPanelMotion(level: motion))
        .motion(value: onboarding.needsSetup)
        .motion(value: settings.showsPopoverCounters)
        .motion(value: model.errorText)
        .motion(value: model.banner)
        .motion(value: cancelNotice)
        .motion(value: model.state?.teams)
        .motion(value: model.confirmation?.id)
        .motion(value: model.isPaused)
        .motion(value: runningReviews.map(\.id))
        .motion(value: tab)
        // Runs each time the panel opens.
        .task {
            await onboarding.checkNeeded()
            if onboarding.needsSetup { return }
            cancelNotice = nil
            tabPicked = false
            tab = PanelTab.opening(badgeCount: model.badgeCount)
            await model.refresh()
            // A message that arrived since the last refresh can change where the panel should open.
            if !tabPicked { tab = PanelTab.opening(badgeCount: model.badgeCount) }
            await window.refreshStatus()
            await reviews.runWaitingRereviews()
        }
    }

    @ViewBuilder private var content: some View {
            header
            if settings.showsPopoverCounters, let state = model.state {
                quickActions(state).transition(Motion.reveal(motion))
            }
            ForEach(runningReviews, id: \.id) { running in
                runningReview(running, last: running.id == runningReviews.last?.id)
                    .transition(Motion.reveal(motion))
            }
            if let text = model.errorText {
                NoticeBox(text: text, tint: .red)
            }
            if let text = model.banner {
                NoticeBox(text: text, tint: .secondary, onClose: model.dismissBanner)
            }
            if let text = cancelNotice {
                NoticeBox(text: text, tint: .secondary) { cancelNotice = nil }
            }
            lists
    }

    /// In place of the panel's status, counters and lists until there is a config file.
    private var setupCard: some View {
        VStack(spacing: 12) {
            AppIconView(size: 72)
            Text(Copy.setupWelcomeTitle).font(.title2.weight(.semibold))
            Text(Copy.setupPanelHint)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
            Button {
                open(nil)
            } label: {
                Label(Copy.setupOpen, systemImage: "sparkles").padding(.horizontal, 12)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppIconView(size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(Copy.appName).font(.headline)
                HStack(spacing: 5) {
                    StatusDot(
                        color: model.state == nil ? Color.gray : (model.isPaused ? Color.orange : Color.green),
                        active: model.state != nil && !model.isPaused)
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
            }
            Spacer()
            RefreshButton {
                Task {
                    await model.refresh()
                    await window.refreshStatus()
                }
            }
            .buttonStyle(.borderless)
        }
    }

    private var statusLine: String {
        let state = model.isPaused ? Copy.paused : Copy.running
        guard let poll = window.status?.lastPoll else { return state }
        let date = Date(timeIntervalSince1970: TimeInterval(poll.at) / 1000)
        return "\(state) · \(Copy.polled(date.formatted(.relative(presentation: .named))))"
    }

    private func quickActions(_ state: AgentState) -> some View {
        HStack(spacing: 8) {
            QuickAction(
                title: model.isPaused ? Copy.resumeShort : Copy.pauseShort,
                symbol: model.isPaused ? "play.fill" : "pause.fill", tint: model.isPaused ? .green : .orange,
                help: model.isPaused ? Copy.resume : Copy.pause
            ) {
                Task { await model.togglePause() }
            }
            QuickAction(
                title: Copy.reviewsShort, symbol: "checklist", tint: .purple, count: state.reviewRequested,
                help: Copy.openSection(WindowSection.reviews.title)
            ) {
                open(.section(.reviews))
            }
            QuickAction(
                title: Copy.statistics, symbol: "chart.bar", tint: .green,
                help: Copy.openSection(WindowSection.statistics.title)
            ) {
                open(.section(.statistics))
            }
            QuickAction(title: Copy.openShort, symbol: "macwindow", tint: .blue, help: Copy.openWindow) {
                open(nil)
            }
        }
    }

    private var runningReviews: [RunningReview] { model.state?.agentReview?.allRunning ?? [] }

    /// The queue count goes under the last running review only.
    private func runningReview(_ running: RunningReview, last: Bool) -> some View {
        HStack(alignment: .top) {
            ReviewingNow(running: running, queued: last ? model.state?.agentReview?.queued.count ?? 0 : 0)
            Spacer(minLength: 8)
            Button(Copy.cancelReview) {
                Task {
                    await reviews.cancelAgentReview(id: running.id, key: running.mrKey)
                    cancelNotice = reviews.agentBanner
                    await model.refresh()
                }
            }
            .controlSize(.small)
            .disabled(reviews.agentBusyKeys.contains(running.mrKey))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var lists: some View {
        if let teams = model.state?.teams {
            // Drawn by hand: a segmented picker keeps its natural width instead of filling the panel.
            HStack(spacing: 2) {
                tabButton(.needsYou, Copy.needsYouTab(teams.attention.count + teams.attentionHidden))
                tabButton(.recent, Copy.recentTab(teams.recent.count))
            }
            .padding(2)
            .background(.quaternary.opacity(0.5), in: Capsule())
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Copy.panelLists)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch tab {
                    case .needsYou:
                        if teams.attention.isEmpty { empty(Copy.attentionEmpty) }
                        ForEach(teams.attention) { row($0).transition(Motion.reveal(motion)) }
                        if teams.attentionHidden > 0 {
                            Text(Copy.moreHidden(teams.attentionHidden)).font(.caption).foregroundStyle(.secondary)
                        }
                    case .recent:
                        if teams.recent.isEmpty { empty(Copy.recentEmpty) }
                        ForEach(teams.recent) { row($0).transition(Motion.reveal(motion)) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        } else if model.state != nil {
            Label(Copy.teamsDisabled, systemImage: "bubble.left.and.exclamationmark.bubble.right")
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        } else {
            Spacer(minLength: 0)
        }
    }

    private func tabButton(_ value: PanelTab, _ title: String) -> some View {
        let selected = tab == value
        return Button {
            tab = value
            tabPicked = true
        } label: {
            Text(title)
                .font(.callout.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    selected ? AnyShapeStyle(.background) : AnyShapeStyle(.clear), in: Capsule()
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func empty(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }

    private func row(_ item: OutboxItem) -> some View {
        OutboxItemRow(model: model, item: item)
    }

    private var footer: some View {
        HStack {
            // With the quick actions hidden, Pause stays reachable here.
            if !settings.showsPopoverCounters {
                Button {
                    Task { await model.togglePause() }
                } label: {
                    Label(
                        model.isPaused ? Copy.resume : Copy.pause,
                        systemImage: model.isPaused ? "play.fill" : "pause.fill")
                }
            }
            Spacer()
            Button {
                open(nil)
            } label: {
                Label(Copy.openWindow, systemImage: "macwindow")
            }
            .keyboardShortcut("o")
            Button {
                open(.section(.appearance))
            } label: {
                Image(systemName: "paintpalette")
            }
            .help(Copy.appearance)
            .accessibilityLabel(Copy.appearance)
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help(Copy.quit)
            .accessibilityLabel(Copy.quit)
        }
        .controlSize(.regular)
    }

    /// Closes the popover, then opens the window on `item`, or on the page it would open on anyway.
    private func open(_ item: SidebarItem?) {
        // Close the popover first: it would otherwise stay open over the window.
        dismiss()
        if let item {
            OpenPageAction(navigator: navigator, openWindow: openWindow)(item)
        } else {
            openWindow(id: "main")
            NSApp.activate()
        }
    }
}

/// One of the panel's quick-action tiles: a coloured symbol over a short label, with a count.
private struct QuickAction: View {
    let title: String
    let symbol: String
    let tint: Color
    var count: Int?
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                SidebarIcon(symbol: symbol, tint: tint, size: 24)
                HStack(spacing: 4) {
                    Text(title).lineLimit(1)
                    if let count {
                        Text("\(count)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText(value: Double(count)))
                            .pulse(on: count)
                    }
                }
                .font(.caption.weight(.medium))
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .hoverLift(cornerRadius: 8)
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityHint(help)
    }
}
