import AppKit
import SuicaCore
import SwiftUI

struct MenuView: View {
    let model: MenuModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let state = model.state { counters(state) }
            if let running = model.state?.agentReview?.running {
                ReviewingNow(running: running, queued: model.state?.agentReview?.queued.count ?? 0)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    .transition(Motion.reveal(reduceMotion: reduceMotion))
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
        .padding(14)
        .frame(width: 400)
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
                    Circle()
                        .fill(model.state == nil ? Color.gray : (model.isPaused ? Color.orange : Color.green))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(model.isPaused ? Copy.paused : Copy.running)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(Copy.refresh)
            .accessibilityLabel(Copy.refresh)
        }
    }

    private func counters(_ state: AgentState) -> some View {
        HStack(spacing: 8) {
            counter(Copy.trackedShort, state.trackedAuthored, tint: .blue)
            counter(Copy.toReviewShort, state.reviewRequested, tint: .teal)
            counter(Copy.needsYouShort, model.badgeCount, tint: model.badgeCount > 0 ? .orange : .secondary)
        }
    }

    private func counter(_ title: String, _ value: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
                .contentTransition(.numericText(value: Double(value)))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
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
                    ForEach(teams.attention) { row($0).transition(Motion.reveal(reduceMotion: reduceMotion)) }
                    if teams.attentionHidden > 0 {
                        Text(Copy.moreHidden(teams.attentionHidden)).font(.caption).foregroundStyle(.secondary)
                    }
                    if !teams.recent.isEmpty {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(teams.recent) { row($0).transition(Motion.reveal(reduceMotion: reduceMotion)) }
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
                // Close the popover first: it would otherwise stay open over the window.
                dismiss()
                openWindow(id: "main")
                NSApp.activate()
            } label: {
                Label(Copy.openWindow, systemImage: "macwindow")
            }
            .keyboardShortcut("o")
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
}
