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

/// The Updates page: the running version, a manual check, what it found, and the way to install.
struct UpdatesView: View {
    let model: UpdatesModel
    @State private var checked = false
    @State private var checking = false
    @Environment(\.metrics) private var metrics

    /// Absent under `swift run`, where there is no bundle version to show.
    private var version: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }

    private var busy: Bool { checking || model.state == .installing }

    var body: some View {
        ScrollView {
            Card(title: Copy.updatesHeading, symbol: WindowSection.updates.symbol) {
                VStack(alignment: .leading, spacing: metrics.gap) {
                    if let version { LabeledContent(Copy.currentVersion, value: version) }
                    HStack(spacing: 8) {
                        if busy { ProgressView().controlSize(.small) }
                        result
                    }
                    .frame(minHeight: 22, alignment: .leading)
                    HStack(spacing: 8) {
                        Button(Copy.checkNow) {
                            Task {
                                checking = true
                                await model.checkNow()
                                checking = false
                                checked = true
                            }
                        }
                        .disabled(busy)
                        if case .available(let latest) = model.state {
                            Button(Copy.installUpdate) { Task { await model.install() } }
                                .buttonStyle(.borderedProminent)
                                .help(Copy.updateTo(latest))
                        }
                        if case .failed = model.state {
                            Button(Copy.retry) { Task { await model.retry() } }
                        }
                    }
                }
            }
            .frame(maxWidth: 560)
            .padding(metrics.gap + 4)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder private var result: some View {
        switch model.state {
        case .idle: if checked { Text(Copy.upToDate) } else { EmptyView() }
        case .available(let latest): Text(Copy.updateAvailable(latest))
        case .installing: Text(Copy.installing)
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}
