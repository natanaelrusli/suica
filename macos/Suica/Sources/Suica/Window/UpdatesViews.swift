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

/// A Form section: the running version, a manual check and what it found.
struct UpdatesSection: View {
    let model: UpdatesModel
    @State private var checked = false
    @State private var checking = false

    /// Absent under `swift run`, where there is no bundle version to show.
    private var version: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }

    var body: some View {
        Section {
            if let version { LabeledContent(Copy.currentVersion, value: version) }
            LabeledContent {
                HStack(spacing: 8) {
                    if checking || model.state == .installing { ProgressView().controlSize(.small) }
                    if case .available(let latest) = model.state {
                        Button(Copy.installUpdate) { Task { await model.install() } }
                            .help(Copy.updateTo(latest))
                    }
                    Button(Copy.checkNow) {
                        Task {
                            checking = true
                            await model.checkNow()
                            checking = false
                            checked = true
                        }
                    }
                    .disabled(checking || model.state == .installing)
                }
            } label: {
                result
            }
        } header: {
            Label(Copy.updatesHeading, systemImage: "arrow.down.circle").font(.headline)
        }
    }

    @ViewBuilder private var result: some View {
        switch model.state {
        case .idle: if checked { Text(Copy.upToDate) } else { EmptyView() }
        case .available(let latest): Text(Copy.updateAvailable(latest))
        case .installing: Text(Copy.installing)
        case .failed(let message): Text(message).foregroundStyle(.orange)
        }
    }
}
