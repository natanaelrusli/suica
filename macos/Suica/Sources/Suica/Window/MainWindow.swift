import AppKit
import SuicaCore
import SwiftUI

enum WindowSection: String, CaseIterable, Identifiable {
    case overview, messages, statistics, configuration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: Copy.overview
        case .messages: Copy.messages
        case .statistics: Copy.statistics
        case .configuration: Copy.configuration
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge"
        case .messages: "tray.full"
        case .statistics: "chart.bar"
        case .configuration: "gearshape"
        }
    }
}

/// A coloured box for a message above a section's content.
struct NoticeBox: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.callout)
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct MainWindow: View {
    let window: WindowModel
    let editor: ConfigEditorModel
    @State private var selection: WindowSection? = .overview

    var body: some View {
        NavigationSplitView {
            List(WindowSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
                    .accessibilityLabel(section.title)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 260)
        } detail: {
            switch selection ?? .overview {
            case .overview: OverviewView(window: window, editor: editor)
            case .messages: MessagesView(model: window.menu)
            case .statistics: StatisticsView(window: window)
            case .configuration: ConfigurationView(window: window, editor: editor)
            }
        }
        .navigationTitle("\(Copy.appName) · \((selection ?? .overview).title)")
        .frame(minWidth: 760, minHeight: 480)
        // The Dock icon exists only while the window does.
        .onAppear { NSApp.setActivationPolicy(.regular) }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
        // Cancelled when the window closes.
        .task { await window.runRefreshLoop(every: .seconds(30)) }
    }
}
