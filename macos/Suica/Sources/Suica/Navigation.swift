import AppKit
import SuicaCore
import SwiftUI

enum WindowSection: String, CaseIterable, Identifiable {
    case overview, reviews, messages, statistics, usage, logs, configuration, appearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: Copy.overview
        case .reviews: Copy.reviewRequests
        case .messages: Copy.messages
        case .statistics: Copy.statistics
        case .usage: Copy.tokenUsage
        case .logs: Copy.logs
        case .configuration: Copy.configuration
        case .appearance: Copy.appearance
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge"
        case .reviews: "checklist"
        case .messages: "tray.full"
        case .statistics: "chart.bar"
        case .usage: "gauge.with.dots.needle.33percent"
        case .logs: "doc.text.magnifyingglass"
        case .configuration: "gearshape"
        case .appearance: "paintpalette"
        }
    }

    /// The colour of its sidebar icon.
    var tint: Color {
        switch self {
        case .overview: .blue
        case .reviews: .purple
        case .messages: .orange
        case .statistics: .green
        case .usage: .pink
        case .logs: .brown
        case .configuration: .gray
        case .appearance: .indigo
        }
    }

    init(_ page: StartPage) {
        switch page {
        case .overview: self = .overview
        case .reviews: self = .reviews
        case .messages: self = .messages
        }
    }
}

/// A row of the sidebar: a section, or one category of Configuration under it.
enum SidebarItem: Hashable {
    case section(WindowSection)
    case settings(ConfigCategory)
    /// The Teams message templates, the last row under Configuration.
    case templates

    var section: WindowSection {
        switch self {
        case .section(let section): section
        case .settings, .templates: .configuration
        }
    }

    var category: ConfigCategory? {
        if case .settings(let category) = self { category } else { nil }
    }
}

extension ConfigCategory {
    var symbol: String {
        switch key {
        case "gitlab": "server.rack"
        case "polling": "arrow.triangle.2.circlepath"
        case "notifications": "bell"
        case "teams": "bubble.left.and.bubble.right"
        case "model": "sparkles"
        case "review": "checkmark.bubble"
        default: "internaldrive"
        }
    }

    var tint: Color {
        switch key {
        case "gitlab": .orange
        case "polling": .teal
        case "notifications": .red
        case "teams": .indigo
        case "model": .purple
        case "review": .green
        default: .gray
        }
    }
}

struct SidebarNode: Identifiable {
    let item: SidebarItem
    let title: String
    let symbol: String
    let tint: Color
    var children: [SidebarNode]?

    var id: SidebarItem { item }

    init(_ section: WindowSection, children: [SidebarNode]? = nil) {
        item = .section(section)
        title = section.title
        symbol = section.symbol
        tint = section.tint
        self.children = children
    }

    init(item: SidebarItem, title: String, symbol: String, tint: Color) {
        self.item = item
        self.title = title
        self.symbol = symbol
        self.tint = tint
    }

    /// The sidebar's three groups: what needs you, what happened, and how the agent and the app
    /// are set up. Configuration's categories and the templates are nested under it.
    static let groups: [(title: String, nodes: [SidebarNode])] = [
        (Copy.workGroup, [SidebarNode(.overview), SidebarNode(.reviews), SidebarNode(.messages)]),
        (Copy.insightsGroup, [SidebarNode(.statistics), SidebarNode(.usage), SidebarNode(.logs)]),
        (
            Copy.settingsGroup,
            [
                SidebarNode(
                    .configuration,
                    children: ConfigCategory.known.map {
                        SidebarNode(item: .settings($0), title: $0.title, symbol: $0.symbol, tint: $0.tint)
                    } + [SidebarNode(item: .templates, title: Copy.messageTemplates, symbol: "text.bubble", tint: .blue)]),
                SidebarNode(.appearance),
            ]
        ),
    ]
}

/// Which page the window shows. Shared by the window, the popover and the Go menu, so either of
/// them can open the window on a page.
@MainActor @Observable
final class Navigator {
    /// Nil while the window is closed: it then opens on Appearance → Open the window on.
    var selection: SidebarItem?
}

/// Opens the window on a page and brings the app forward.
struct OpenPageAction {
    let navigator: Navigator
    let openWindow: OpenWindowAction

    @MainActor func callAsFunction(_ item: SidebarItem) {
        navigator.selection = item
        // As Open Suica… does: the window sets the Dock icon up when it appears.
        openWindow(id: "main")
        NSApp.activate()
    }
}

/// The Go menu (⌘1 to ⌘8, one per section) and Settings… (⌘,), which opens Appearance.
struct NavigationCommands: Commands {
    let navigator: Navigator

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            PageButton(navigator: navigator, item: .section(.appearance), title: Copy.settingsMenu)
                .keyboardShortcut(",")
        }
        CommandMenu(Copy.goMenu) {
            ForEach(Array(WindowSection.allCases.enumerated()), id: \.element) { index, section in
                PageButton(navigator: navigator, item: .section(section), title: section.title)
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
            }
        }
    }
}

private struct PageButton: View {
    let navigator: Navigator
    let item: SidebarItem
    let title: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) { OpenPageAction(navigator: navigator, openWindow: openWindow)(item) }
    }
}
