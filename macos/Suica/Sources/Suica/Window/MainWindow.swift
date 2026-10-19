import AppKit
import SuicaCore
import SwiftUI

enum WindowSection: String, CaseIterable, Identifiable {
    case overview, reviews, messages, statistics, usage, configuration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: Copy.overview
        case .reviews: Copy.reviewRequests
        case .messages: Copy.messages
        case .statistics: Copy.statistics
        case .usage: Copy.tokenUsage
        case .configuration: Copy.configuration
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge"
        case .reviews: "checklist"
        case .messages: "tray.full"
        case .statistics: "chart.bar"
        case .usage: "gauge.with.dots.needle.33percent"
        case .configuration: "gearshape"
        }
    }
}

/// A coloured box for a message above a section's content.
/// The parent animates its appearance with `.motion(value:)`.
struct NoticeBox: View {
    let text: String
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text)
            .font(.callout)
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            .transition(Motion.reveal(reduceMotion: reduceMotion))
    }
}

/// A titled, rounded panel that groups one part of a section.
struct Card<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5)))
    }
}

/// A small figure with a coloured icon, as at the top of Overview and Statistics.
struct StatTile<Accessory: View>: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color
    var caption: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(alignment: .lastTextBaseline) {
                Text(value)
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                Spacer(minLength: 4)
                accessory
            }
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5)))
        .accessibilityElement(children: .combine)
    }
}

extension StatTile where Accessory == EmptyView {
    init(title: String, value: String, symbol: String, tint: Color, caption: String? = nil) {
        self.init(title: title, value: value, symbol: symbol, tint: tint, caption: caption) { EmptyView() }
    }
}

extension View {
    /// Keeps `isWide` in step with this view's width, animating the switch, so a page can change
    /// between one and two columns without jumping while the sidebar opens or closes.
    func tracksWidth(above threshold: CGFloat, _ isWide: Binding<Bool>) -> some View {
        onGeometryChange(for: Bool.self) { $0.size.width > threshold } action: { wide in
            withAnimation(Motion.layout) { isWide.wrappedValue = wide }
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

private struct SidebarNode: Identifiable {
    let item: SidebarItem
    let title: String
    let symbol: String
    var children: [SidebarNode]?

    var id: SidebarItem { item }

    /// Every section, with Configuration's categories nested under it.
    static let all: [SidebarNode] = WindowSection.allCases.map { section in
        SidebarNode(
            item: .section(section), title: section.title, symbol: section.symbol,
            children: section == .configuration
                ? ConfigCategory.known.map {
                    SidebarNode(item: .settings($0), title: $0.title, symbol: $0.symbol)
                } + [SidebarNode(item: .templates, title: Copy.messageTemplates, symbol: "text.bubble")]
                : nil)
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
}

struct MainWindow: View {
    let window: WindowModel
    let editor: ConfigEditorModel
    let reviews: ReviewsModel
    let templates: TemplateEditorModel
    @State private var selection: SidebarItem? = .section(.overview)
    @State private var columns: NavigationSplitViewVisibility = .all
    /// Bumped for a row each time it is picked, so only its icon bounces.
    @State private var picks: [SidebarItem: Int] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var current: SidebarItem { selection ?? .section(.overview) }

    private var title: String {
        let base = "\(Copy.appName) · \(current.section.title)"
        if current == .templates { return "\(base) · \(Copy.messageTemplates)" }
        return current.category.map { "\(base) · \($0.title)" } ?? base
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(SidebarNode.all, children: \.children, selection: $selection) { node in
                Label {
                    Text(node.title)
                } icon: {
                    Image(systemName: node.symbol)
                        .symbolEffect(.bounce, value: reduceMotion ? 0 : picks[node.item, default: 0])
                }
                .accessibilityLabel(node.title)
            }
            .onChange(of: selection) { _, picked in
                if let picked { picks[picked, default: 0] += 1 }
            }
            .safeAreaInset(edge: .top) {
                // Fixed width, so the header slides away with the sidebar instead of squeezing.
                HStack(spacing: 8) {
                    AppIconView(size: 28)
                    Text(Copy.appName).font(.title3.weight(.semibold)).fixedSize()
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 260)
        } detail: {
            // A new identity per section, so the old page fades out while the new one comes in.
            ZStack {
                page(current)
                    .id(current)
                    .transition(Motion.page(reduceMotion: reduceMotion))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .motion(Motion.page, value: current)
        }
        // The detail column follows the sidebar with the same curve, so pages resize smoothly
        // rather than snapping to their new width at the end.
        .motion(Motion.sidebar, value: columns)
        .navigationTitle(title)
        .frame(minWidth: 760, minHeight: 480)
        // The Dock icon exists only while the window does.
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
        // A `suica://` link: also runs for one that opened this window.
        .onChange(of: window.pendingLink, initial: true) { _, _ in
            guard let link = window.takePendingLink() else { return }
            selection = .section(.messages)
            Task { await window.show(link) }
        }
        // Cancelled when the window closes.
        .task { await window.runRefreshLoop(every: .seconds(30)) }
    }

    @ViewBuilder private func page(_ item: SidebarItem) -> some View {
        if item == .templates {
            TemplatesView(model: templates, window: window)
        } else {
            sectionPage(item)
        }
    }

    @ViewBuilder private func sectionPage(_ item: SidebarItem) -> some View {
        switch item.section {
        case .overview: OverviewView(window: window, editor: editor)
        case .reviews: ReviewsView(model: reviews)
        case .messages: MessagesView(window: window)
        case .statistics: StatisticsView(window: window)
        case .usage: UsageView(window: window)
        case .configuration: ConfigurationView(window: window, editor: editor, category: item.category)
        }
    }
}
