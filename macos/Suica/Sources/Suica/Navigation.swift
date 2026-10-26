import AppKit
import SuicaCore
import SwiftUI

enum WindowSection: String, CaseIterable, Identifiable {
    case overview, reviews, messages, statistics, usage, logs, configuration, appearance
    /// Last, so it takes ⌘9 and the other pages keep their shortcuts; the sidebar lists it under Work.
    case office
    /// After the Office, so it takes ⌘0; the sidebar lists it under Insights.
    case system
    /// Your own MRs. Added after every digit was taken, so it takes ⇧⌘2 beside Merge requests (⌘2);
    /// the sidebar and the Go menu list it right after Merge requests.
    case myMergeRequests

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: Copy.overview
        case .reviews: Copy.mergeRequests
        case .myMergeRequests: Copy.myMergeRequests
        case .messages: Copy.messages
        case .statistics: Copy.statistics
        case .usage: Copy.tokenUsage
        case .logs: Copy.logs
        case .configuration: Copy.configuration
        case .appearance: Copy.appearance
        case .office: Copy.office
        case .system: Copy.systemPage
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge"
        case .reviews: "checklist"
        case .myMergeRequests: "arrow.triangle.pull"
        case .messages: "tray.full"
        case .statistics: "chart.bar"
        case .usage: "gauge.with.dots.needle.33percent"
        case .logs: "doc.text.magnifyingglass"
        case .configuration: "gearshape"
        case .appearance: "paintpalette"
        case .office: "cube.transparent"
        case .system: "cpu"
        }
    }

    /// The colour of its sidebar icon.
    var tint: Color {
        switch self {
        case .overview: .blue
        case .reviews: .purple
        case .myMergeRequests: .blue
        case .messages: .orange
        case .statistics: .green
        case .usage: .pink
        case .logs: .brown
        case .configuration: .gray
        case .appearance: .indigo
        case .office: .cyan
        case .system: .mint
        }
    }

    /// ⌘1 to ⌘9 and ⌘0 in the order of the cases; My MRs takes ⇧⌘2.
    var shortcut: KeyboardShortcut {
        if self == .myMergeRequests { return KeyboardShortcut("2", modifiers: [.command, .shift]) }
        let index = Self.allCases.firstIndex(of: self) ?? 0
        return KeyboardShortcut(KeyEquivalent(Character(String((index + 1) % 10))))
    }

    /// The Go menu's order: My MRs beside Merge requests.
    static let menuOrder: [WindowSection] = allCases.flatMap { section -> [WindowSection] in
        switch section {
        case .reviews: [.reviews, .myMergeRequests]
        case .myMergeRequests: []
        default: [section]
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

/// The pages under Statistics: who you review, who reviews you, and your slowest approvals.
enum StatisticsPage: CaseIterable, Hashable {
    case peopleIReview, peopleWhoReviewMe, slowestApprovals

    var title: String {
        switch self {
        case .peopleIReview: Copy.peopleIReview
        case .peopleWhoReviewMe: Copy.peopleWhoReviewMe
        case .slowestApprovals: Copy.slowestApprovals
        }
    }

    var symbol: String {
        switch self {
        case .peopleIReview: "person.crop.circle.badge.checkmark"
        case .peopleWhoReviewMe: "person.2"
        case .slowestApprovals: "hourglass"
        }
    }

    var tint: Color {
        switch self {
        case .peopleIReview: .teal
        case .peopleWhoReviewMe: .mint
        case .slowestApprovals: .orange
        }
    }
}

/// A row of the sidebar: a section, or one page nested under Statistics or Configuration.
enum SidebarItem: Hashable {
    case section(WindowSection)
    case statistics(StatisticsPage)
    case settings(ConfigCategory)
    /// The Teams message templates, the last row under Configuration.
    case templates

    var section: WindowSection {
        switch self {
        case .section(let section): section
        case .statistics: .statistics
        case .settings, .templates: .configuration
        }
    }

    var category: ConfigCategory? {
        if case .settings(let category) = self { category } else { nil }
    }

    var statisticsPage: StatisticsPage? {
        if case .statistics(let page) = self { page } else { nil }
    }

    /// Configuration's own pages: its categories, the templates and Appearance. The sidebar marks
    /// Configuration for them, and the toolbar offers the way back to its overview.
    var isUnderConfiguration: Bool {
        switch self {
        case .settings, .templates, .section(.appearance): true
        default: false
        }
    }

    /// The nested page's name, shown after the section's in the window title.
    var subtitle: String? {
        switch self {
        case .section: nil
        case .statistics(let page): page.title
        case .settings(let category): category.title
        case .templates: Copy.messageTemplates
        }
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
        case "lessons": "book"
        case "office": "building.2"
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
        case "lessons": .brown
        case "office": .cyan
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
    /// are set up. Statistics' pages are nested under it; Configuration's categories, the
    /// templates and Appearance open from its overview page.
    static let groups: [(title: String, nodes: [SidebarNode])] = [
        (
            Copy.workGroup,
            [
                SidebarNode(.overview), SidebarNode(.reviews), SidebarNode(.myMergeRequests), SidebarNode(.messages),
                SidebarNode(.office),
            ]
        ),
        (
            Copy.insightsGroup,
            [
                SidebarNode(
                    .statistics,
                    children: StatisticsPage.allCases.map {
                        SidebarNode(item: .statistics($0), title: $0.title, symbol: $0.symbol, tint: $0.tint)
                    }),
                SidebarNode(.usage), SidebarNode(.logs), SidebarNode(.system),
            ]
        ),
        (
            Copy.settingsGroup,
            [SidebarNode(.configuration)]
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

/// The Go menu (⌘1 to ⌘9, ⌘0 and ⇧⌘2, one per section) and Settings… (⌘,), which opens Appearance.
struct NavigationCommands: Commands {
    let navigator: Navigator

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            PageButton(navigator: navigator, item: .section(.appearance), title: Copy.settingsMenu)
                .keyboardShortcut(",")
        }
        CommandMenu(Copy.goMenu) {
            ForEach(WindowSection.menuOrder) { section in
                PageButton(navigator: navigator, item: .section(section), title: section.title)
                    .keyboardShortcut(section.shortcut)
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
