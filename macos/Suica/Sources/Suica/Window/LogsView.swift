import AppKit
import SuicaCore
import SwiftUI

/// The background agent's output and error logs, newest at the bottom, read again while the page
/// is open.
struct LogsView: View {
    let window: WindowModel
    @State private var model = LogsModel()
    @State private var query = ""

    private var folder: String? { window.status?.paths.logs }

    private var shown: [LogEntry] { model.entries.filter { $0.matches(query) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            if let folder {
                if let text = model.errorText { NoticeBox(text: text, tint: .red) }
                if model.truncated { NoticeBox(text: Copy.logTruncated(LogsModel.maxEntries), tint: .secondary) }
                entries(folder: folder)
            } else if window.errorText != nil {
                NoticeBox(text: Copy.logFolderUnknown, tint: .red)
                Spacer()
            } else {
                ProgressView(Copy.loading).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .searchable(text: $query, prompt: Copy.searchLogs)
        // Restarted when the stream or folder changes; cancelled when the page goes away.
        .task(id: "\(folder ?? "")|\(model.stream.rawValue)") {
            guard let folder else { return }
            while !Task.isCancelled {
                model.load(folder: folder)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var toolbar: some View {
        HStack {
            Picker(Copy.logs, selection: $model.stream) {
                Text(Copy.logOutput).tag(LogStream.output)
                Text(Copy.logErrors).tag(LogStream.errors)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            if let folder {
                Button {
                    model.load(folder: folder, force: true)
                } label: {
                    Label(Copy.refresh, systemImage: "arrow.clockwise")
                }
                .help(Copy.refresh)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([model.url(in: folder)])
                } label: {
                    Label(Copy.revealInFinder, systemImage: "folder")
                }
                .help(DisplayText.clean(model.url(in: folder).path, max: 300))
            }
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder private func entries(folder: String) -> some View {
        let shown = shown
        if shown.isEmpty {
            let text =
                model.missing
                ? Copy.logMissing(model.stream.fileName)
                : model.entries.isEmpty ? Copy.logEmpty : Copy.logNoMatches
            Text(text)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shown) { entry in
                            LogRow(entry: entry)
                            Divider()
                        }
                    }
                    .textSelection(.enabled)
                }
                .defaultScrollAnchor(.bottom)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5)))
                // Follow the end of the log, as `tail -f` does.
                .onChange(of: shown.last?.id, initial: true) { _, last in
                    if let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(time)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
            Text(entry.level?.uppercased() ?? "")
                .fontWeight(.semibold)
                .foregroundStyle(tint)
                .frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message)
                if let attributes = entry.attributes {
                    Text(attributes).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.callout, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .id(entry.id)
    }

    /// "20 Oct 10:36:33": the day and the time to the second, on one line.
    private var time: String {
        guard let date = entry.date else { return "" }
        return "\(date.formatted(.dateTime.day().month(.abbreviated))) \(date.formatted(.dateTime.hour().minute().second()))"
    }

    private var tint: Color {
        switch entry.level {
        case "error": .red
        case "warn": .orange
        case "debug": .secondary
        default: .blue
        }
    }
}
