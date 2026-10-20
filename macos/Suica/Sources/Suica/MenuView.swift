import AppKit
import SuicaCore
import SwiftUI

struct MenuView: View {
    let model: MenuModel
    let settings: AppearanceSettings
    let navigator: Navigator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.motionLevel) private var motion
    @Environment(\.metrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.gap * 0.75) {
            header
            if settings.showsPopoverCounters, let state = model.state {
                counters(state).transition(Motion.reveal(motion))
            }
            if let running = model.state?.agentReview?.running {
                ReviewingNow(running: running, queued: model.state?.agentReview?.queued.count ?? 0)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    .transition(Motion.reveal(motion))
            }
            if let text = model.errorText {
                NoticeBox(text: text, tint: .red)
            }
            if let text = model.banner {
                NoticeBox(text: text, tint: .secondary)
            }
            content
            Divider()
            footer
        }
        .padding(metrics.padding)
        .background(alignment: .top) {
            // A wash of the accent colour behind the header, fading out before the content.
            Rectangle()
                .fill(.tint.opacity(0.16))
                .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                .frame(height: 96)
                .allowsHitTesting(false)
        }
        .frame(width: 400)
        .motion(value: settings.showsPopoverCounters)
        .motion(value: model.errorText)
        .motion(value: model.banner)
        .motion(value: model.state?.teams)
        .motion(value: model.confirmation?.id)
        .motion(value: model.isPaused)
        .motion(value: model.state?.agentReview?.running?.id)
        .task { await model.refresh() }
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
                    Text(model.isPaused ? Copy.paused : Copy.running)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
            }
            Spacer()
            RefreshButton { Task { await model.refresh() } }
                .buttonStyle(.borderless)
        }
    }

    /// Each figure opens the window on the page that lists what it counts.
    private func counters(_ state: AgentState) -> some View {
        HStack(spacing: 8) {
            counter(Copy.trackedShort, state.trackedAuthored, tint: .blue, page: .overview)
            counter(Copy.toReviewShort, state.reviewRequested, tint: .teal, page: .reviews)
            counter(
                Copy.needsYouShort, model.badgeCount, tint: model.badgeCount > 0 ? .orange : .secondary,
                page: .messages)
        }
    }

    private func counter(_ title: String, _ value: Int, tint: Color, page: WindowSection) -> some View {
        Button {
            open(.section(page))
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value)")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(tint)
                    .contentTransition(.numericText(value: Double(value)))
                    .pulse(on: value)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, metrics.rowSpacing + 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .hoverLift(cornerRadius: 8)
        .help(Copy.openSection(page.title))
        .accessibilityElement(children: .combine)
        .accessibilityHint(Copy.openSection(page.title))
    }

    @ViewBuilder private var content: some View {
        if let teams = model.state?.teams {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Copy.attentionHeading).font(.subheadline.weight(.semibold))
                    if teams.attention.isEmpty {
                        Label(Copy.attentionEmpty, systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    }
                    ForEach(teams.attention) { row($0).transition(Motion.reveal(motion)) }
                    if teams.attentionHidden > 0 {
                        Text(Copy.moreHidden(teams.attentionHidden)).font(.caption).foregroundStyle(.secondary)
                    }
                    if !teams.recent.isEmpty {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(teams.recent) { row($0).transition(Motion.reveal(motion)) }
                            }
                            .padding(.top, 4)
                        } label: {
                            Text(Copy.recentHeading(teams.recent.count)).font(.subheadline.weight(.semibold))
                        }
                    }
                }
            }
            .frame(maxHeight: 440)
        } else if model.state != nil {
            Label(Copy.teamsDisabled, systemImage: "bubble.left.and.exclamationmark.bubble.right")
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ item: OutboxItem) -> some View {
        OutboxItemRow(model: model, item: item)
    }

    private var footer: some View {
        HStack {
            Button {
                Task { await model.togglePause() }
            } label: {
                Label(
                    model.isPaused ? Copy.resume : Copy.pause,
                    systemImage: model.isPaused ? "play.fill" : "pause.fill")
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
