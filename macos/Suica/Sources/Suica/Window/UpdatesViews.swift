import SuicaCore
import SwiftUI

/// The popover footer's update line: the way in when one is available, progress while it installs,
/// and the failure with a retry. Nothing when idle.
struct UpdatesFooterItem: View {
    let model: UpdatesModel

    var body: some View {
        switch model.state {
        case .idle:
            EmptyView()
        case .available(let version):
            Button {
                Task { await model.install() }
            } label: {
                Label(Copy.updateTo(version), systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(Copy.installing).font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let message):
            HStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(Copy.retry) { Task { await model.retry() } }
            }
        }
    }
}

/// The Updates page keeps the running version separate from the next action.
struct UpdatesView: View {
    let model: UpdatesModel
    @State private var checked = false
    @State private var checking = false
    @State private var wide = false
    @Environment(\.metrics) private var metrics

    /// Absent under `swift run`, where there is no bundle version to show.
    private var version: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }

    private var busy: Bool { checking || model.state == .installing }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: metrics.gap) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Copy.updatesHeading)
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text(Copy.updatesSubtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: metrics.gap) {
                        SidebarIcon(symbol: "arrow.triangle.2.circlepath", tint: .accentColor, size: 52)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Suica")
                                .font(.title2.weight(.semibold))
                            if let version {
                                Text("\(Copy.currentVersion) \(version)")
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(metrics.padding + 8)

                    Divider()

                    VStack(alignment: .leading, spacing: metrics.gap) {
                        HStack(alignment: .top, spacing: 12) {
                            statusIcon
                                .frame(width: 24, height: 24)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(statusTitle)
                                    .font(.headline)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(statusDetail)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                        .accessibilityElement(children: .combine)

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) { actions }
                            VStack(alignment: .leading, spacing: 10) { actions }
                        }
                        .controlSize(.large)
                    }
                    .padding(metrics.padding + 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(statusColor.opacity(0.045))
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(.quaternary, lineWidth: 1)
                }

                Label(Copy.updatesAutomaticCheck, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                changelog
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(metrics.gap + 4)
            .tracksWidth(above: 760, $wide)
        }
    }

    private var changelog: some View {
        VStack(alignment: .leading, spacing: metrics.gap) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Copy.updatesChangelog)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(Copy.updatesChangelogDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, metrics.gap)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(minimum: 0), alignment: .top), count: wide ? 2 : 1),
                alignment: .leading,
                spacing: metrics.gap
            ) {
                ForEach(Array(ReleaseNote.recent.prefix(5))) { release in
                    releaseCard(release)
                }
            }
        }
    }

    private func releaseCard(_ release: ReleaseNote) -> some View {
        Card(title: "Suica \(release.version)", symbol: "shippingbox", fillsHeight: true) {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        releaseMetadata(release)
                        Spacer(minLength: 8)
                        releaseLink(release)
                    }
                    .fixedSize(horizontal: true, vertical: false)

                    VStack(alignment: .leading, spacing: 8) {
                        releaseMetadata(release)
                        releaseLink(release)
                    }
                }
                Text(release.title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(release.changes, id: \.self) { change in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                            Text(change)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
        }
    }

    private func releaseMetadata(_ release: ReleaseNote) -> some View {
        HStack(spacing: 8) {
            Text(release.date)
                .font(.caption)
                .foregroundStyle(.secondary)
            if release.version == version {
                Text(Copy.updatesInstalled)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
        }
    }

    private func releaseLink(_ release: ReleaseNote) -> some View {
        Link(destination: release.url) {
            Label(Copy.updatesReleaseNotes, systemImage: "arrow.up.right")
                .font(.caption)
        }
        .help("Suica \(release.version) — \(Copy.updatesReleaseNotes)")
    }

    @ViewBuilder private var statusIcon: some View {
        if busy {
            ProgressView().controlSize(.small)
                .accessibilityLabel(statusTitle)
        } else {
            Image(systemName: statusSymbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)
        }
    }

    private var statusTitle: String {
        if checking { return Copy.updatesChecking }
        switch model.state {
        case .idle: return checked ? Copy.upToDate : Copy.checkNow
        case .available(let latest): return Copy.updateAvailable(latest)
        case .installing: return Copy.installing
        case .failed: return model.failureWasInstall ? Copy.updateInstallFailed : Copy.updateCheckFailed
        }
    }

    private var statusDetail: String {
        if checking { return Copy.updatesCheckingDetail }
        switch model.state {
        case .idle: return checked ? Copy.updatesCurrentDetail : Copy.updatesCheckDetail
        case .available: return Copy.updatesAvailableDetail
        case .installing: return Copy.updatesInstallingDetail
        case .failed(let message): return message
        }
    }

    private var statusColor: Color {
        if checking { return .accentColor }
        switch model.state {
        case .idle: return checked ? .green : .secondary
        case .available, .installing: return .accentColor
        case .failed: return .orange
        }
    }

    private var statusSymbol: String {
        switch model.state {
        case .idle: return checked ? "checkmark.circle.fill" : "arrow.clockwise.circle"
        case .available: return "arrow.down.circle.fill"
        case .installing: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    @ViewBuilder private var actions: some View {
        if case .available(let latest) = model.state {
            Button {
                Task { await model.install() }
            } label: {
                Label(Copy.updateTo(latest), systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy)
        }
        if case .failed = model.state {
            Button(Copy.retry) { Task { await model.retry() } }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
        }
        Button(Copy.checkNow) {
            Task {
                checking = true
                await model.checkNow()
                checking = false
                checked = true
            }
        }
        .disabled(busy)
    }
}
