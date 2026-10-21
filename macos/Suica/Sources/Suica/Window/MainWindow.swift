import AppKit
import SuicaCore
import SwiftUI

/// A coloured box for a message above a section's content, with × to close it.
/// The parent animates its appearance with `.motion(value:)`; closing animates by itself.
struct NoticeBox: View {
    let text: String
    let tint: Color
    /// Clears the notice at its source, so it stays closed after the page goes away. Without it,
    /// × hides the box here until its text changes.
    var onClose: (() -> Void)?
    /// False for a failure that is the whole page, where closing would leave it blank.
    var closable = true
    @State private var closed: String?
    @Environment(\.motionLevel) private var motion

    var body: some View {
        if closed != text {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if closable { closeButton }
            }
            .padding(8)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            .transition(Motion.notice(motion))
        }
    }

    private var closeButton: some View {
        Button {
            withMotion(Motion.content, motion) {
                closed = text
                onClose?()
            }
        } label: {
            Image(systemName: "xmark")
                .font(.caption.weight(.semibold))
                .padding(2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(Copy.closeNotice)
        .accessibilityLabel(Copy.closeNotice)
    }
}

/// A titled, rounded panel that groups one part of a section.
struct Card<Content: View>: View {
    let title: String
    let symbol: String
    /// A link in the heading's corner to the page with the rest, as "Statistics →".
    var link: CardLink?
    @ViewBuilder let content: Content
    @Environment(\.metrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.gap * 0.6) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let link {
                    Spacer(minLength: 8)
                    Button(link.title, action: link.action)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            content
        }
        .padding(metrics.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5)))
    }
}

struct CardLink {
    let title: String
    let action: () -> Void
}

/// A small figure with a coloured icon, as at the top of Overview and Statistics. With an action it
/// is a button that opens the page behind the figure.
struct StatTile<Accessory: View>: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color
    var caption: String?
    var action: (() -> Void)?
    @ViewBuilder var accessory: Accessory
    @Environment(\.metrics) private var metrics

    var body: some View {
        if let action {
            Button(action: action) { tile(linked: true) }
                .buttonStyle(.plain)
                .hoverLift(cornerRadius: 12)
        } else {
            tile(linked: false)
        }
    }

    private func tile(linked: Bool) -> some View {
        VStack(alignment: .leading, spacing: metrics.rowSpacing + 1) {
            HStack(spacing: 6) {
                SidebarIcon(symbol: symbol, tint: tint, size: 22)
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                if linked {
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            HStack(alignment: .lastTextBaseline) {
                Text(value)
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                    .pulse(on: value)
                Spacer(minLength: 4)
                accessory
            }
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(metrics.padding - 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5)))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(linked ? .isButton : [])
    }
}

extension StatTile where Accessory == EmptyView {
    init(
        title: String, value: String, symbol: String, tint: Color, caption: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.init(title: title, value: value, symbol: symbol, tint: tint, caption: caption, action: action) {
            EmptyView()
        }
    }
}

extension View {
    /// Keeps `isWide` in step with this view's width, animating the switch, so a page can change
    /// between one and two columns without jumping while the sidebar opens or closes.
    func tracksWidth(above threshold: CGFloat, _ isWide: Binding<Bool>) -> some View {
        modifier(TracksWidth(threshold: threshold, isWide: isWide))
    }
}

/// The first width is taken as it is: animated, it played the switch from one column to two each
/// time the page opened, on top of the page's own entrance.
private struct TracksWidth: ViewModifier {
    let threshold: CGFloat
    @Binding var isWide: Bool
    @State private var measured = false
    @Environment(\.motionLevel) private var motion

    func body(content: Content) -> some View {
        content.onGeometryChange(for: Bool.self) { $0.size.width > threshold } action: { wide in
            if measured {
                withMotion(Motion.layout, motion) { isWide = wide }
            } else {
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { isWide = wide }
                measured = true
            }
        }
    }
}

struct MainWindow: View {
    let window: WindowModel
    let editor: ConfigEditorModel
    let reviews: ReviewsModel
    let fixes: FixesModel
    let templates: TemplateEditorModel
    let office: OfficeModel
    let settings: AppearanceSettings
    @Bindable var navigator: Navigator
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var statisticsOpen = false
    /// Bumped for a row each time it is picked, so only its icon bounces.
    @State private var picks: [SidebarItem: Int] = [:]
    @Environment(\.motionLevel) private var motion

    private var current: SidebarItem { navigator.selection ?? .section(WindowSection(settings.startPage)) }

    private var title: String {
        let base = "\(Copy.appName) · \(current.section.title)"
        return current.subtitle.map { "\(base) · \($0)" } ?? base
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
        } detail: {
            // The sidebar floats over this column and AppKit reports its width as a leading safe
            // area, changed frame by frame while the sidebar opens or closes. Scrolling pages
            // picked that change up only at the end, so they slid over and then jumped to their new
            // width. Handing the width to the page as its own padding on every frame makes it
            // resize and reflow along with the sidebar. The GeometryReader keeps the safe area, so
            // its size is the column's whatever the page asks for and cannot feed back.
            GeometryReader { proxy in
                // A new identity per section, so the old page fades out while the new one comes in.
                ZStack {
                    page(current)
                        .id(current)
                        .transition(Motion.page(motion))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaPadding(.leading, proxy.safeAreaInsets.leading)
                .ignoresSafeArea(.container, edges: .leading)
            }
            .toolbar {
                // Configuration's pages have no sidebar row of their own: the way back is here.
                if current.isUnderConfiguration {
                    ToolbarItem(placement: .navigation) {
                        Button { navigator.selection = .section(.configuration) } label: {
                            Label(Copy.backToConfiguration, systemImage: "chevron.backward")
                        }
                        .help(Copy.backToConfiguration)
                    }
                }
            }
            .background(alignment: .top) {
                BackdropView(backdrop: settings.backdrop, strength: settings.backdrop == .wash ? 0.1 : 0.2)
                    .frame(height: 220)
                    .ignoresSafeArea()
            }
            .motion(Motion.page, value: current)
        }
        .navigationTitle(title)
        .frame(minWidth: 760, minHeight: 480)
        // The Dock icon exists only while the window does.
        .onAppear {
            // Opened from the Dock or Open Suica…: the start page. From the popover or Go menu: theirs.
            if navigator.selection == nil { navigator.selection = current }
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        .onDisappear {
            navigator.selection = nil
            NSApp.setActivationPolicy(.accessory)
        }
        // A `suica://` link: also runs for one that opened this window.
        .onChange(of: window.pendingLink, initial: true) { _, _ in
            guard let link = window.takePendingLink() else { return }
            navigator.selection = .section(.messages)
            Task { await window.show(link) }
        }
        // Cancelled when the window closes.
        .task { await window.runRefreshLoop(every: .seconds(30)) }
    }

    /// The row the sidebar marks: Configuration for its own pages, which have no row.
    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(
            get: { navigator.selection.map { $0.isUnderConfiguration ? .section(.configuration) : $0 } },
            set: { navigator.selection = $0 })
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            ForEach(SidebarNode.groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.nodes) { node in
                        sidebarRow(node)
                            .tag(node.item)
                            // The row is already marked on Configuration's own pages, so picking it
                            // changes no selection: the tap itself goes back to the overview.
                            .simultaneousGesture(
                                TapGesture().onEnded { navigator.selection = node.item },
                                isEnabled: node.item == .section(.configuration))
                        // The sidebar list slid the rows below while it drew new rows at their
                        // final place, so they overlapped (an OutlineGroup's expanding did the
                        // same). The rows are added without that, and each fades in on its own.
                        if let children = node.children, statisticsOpen {
                            ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                                sidebarRow(child)
                                    .padding(.leading, 14)
                                    .staggeredEntrance(index)
                                    .tag(child.item)
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: navigator.selection, initial: true) { _, picked in
            if let picked { picks[picked, default: 0] += 1 }
            // A Statistics page opened from elsewhere shows where it sits.
            if picked?.statisticsPage != nil { statisticsOpen = true }
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
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
    }

    private func sidebarRow(_ node: SidebarNode) -> some View {
        Label {
            HStack(spacing: 4) {
                Text(node.title)
                if node.children != nil {
                    Spacer(minLength: 0)
                    Button {
                        statisticsOpen.toggle()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(statisticsOpen ? 90 : 0))
                            .motion(value: statisticsOpen)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(statisticsOpen ? Copy.collapse : Copy.expand)
                    .accessibilityLabel(statisticsOpen ? Copy.collapse : Copy.expand)
                }
            }
        } icon: {
            SidebarIcon(symbol: node.symbol, tint: node.tint)
                .symbolEffect(.bounce, value: motion == .full ? picks[node.item, default: 0] : 0)
        }
        .badge(badge(for: node.item))
        .accessibilityLabel(node.title)
    }

    /// The number of things on a page that wait for you: shown beside its row, as in Mail.
    private func badge(for item: SidebarItem) -> Int {
        switch item {
        case .section(.reviews): window.menu.state?.reviewRequested ?? 0
        case .section(.messages): window.menu.badgeCount
        default: 0
        }
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
        case .overview: OverviewView(window: window, editor: editor, reviews: reviews, navigator: navigator)
        case .reviews: ReviewsView(model: reviews, fixes: fixes)
        case .messages: MessagesView(window: window)
        case .statistics:
            if let page = item.statisticsPage {
                StatisticsPageView(window: window, page: page)
            } else {
                StatisticsView(window: window)
            }
        case .usage: UsageView(window: window)
        case .logs: LogsView(window: window)
        case .configuration: ConfigurationView(window: window, editor: editor, navigator: navigator, category: item.category)
        case .appearance: AppearanceView(settings: settings)
        case .office: OfficeView(model: office)
        }
    }
}
