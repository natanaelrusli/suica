import AppKit
import RealityKit
import SuicaCore
import SwiftUI

/// The coding agents running on this Mac, as a small 3D office: a Room per project, a Desk per
/// Session. It watches only; nothing here controls an agent.
struct OfficeView: View {
    let model: OfficeModel
    /// Where the building style and the environment are kept.
    @Bindable var settings: AppearanceSettings
    @State private var controller = OfficeSceneController()
    /// False while the window is minimized, hidden or covered: nothing is polled then.
    @State private var windowVisible = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.motionLevel) private var motion

    var body: some View {
        // The scene runs up under the title bar, which floats over it on a vignette.
        UnderTitleBar { titleBar in
            ZStack {
                ZStack(alignment: .top) {
                    // The sky above the street.
                    Self.sky(settings.officeEnvironment, dark: scheme == .dark)
                    OfficeSceneView(
                        model: model, controller: controller, style: settings.officeStyle,
                        environment: settings.officeEnvironment)
                    vignette.frame(height: titleBar + 70)
                }
                .clipped()
                if model.loaded && model.sessions.isEmpty { emptyState }
                overlays.padding(.top, titleBar)
            }
        }
        .toolbar {
            Menu {
                Picker(Copy.officeBuildingPicker, selection: $settings.officeStyle) {
                    ForEach(OfficeStyle.allCases) { Text($0.title).tag($0) }
                }
                Picker(Copy.officeEnvironmentPicker, selection: $settings.officeEnvironment) {
                    ForEach(OfficeEnvironment.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                Label(Copy.officeStyleMenu, systemImage: "paintbrush")
            }
            .help(Copy.officeStyleHint)
            Button {
                controller.resetCamera()
                model.select(nil)
            } label: {
                Label(Copy.resetCamera, systemImage: "scope")
            }
            .help(Copy.resetCamera)
            Button { Task { await model.refresh() } } label: {
                Label(Copy.refresh, systemImage: "arrow.clockwise")
            }
            .help("\(Copy.refresh) (⌘R)")
            .keyboardShortcut("r")
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .background(WindowVisibility { windowVisible = $0 })
        // Polls only while the page is on screen: the scene and the detection stop with it.
        .task(id: windowVisible) {
            guard windowVisible else { return }
            await model.runPollLoop(every: .seconds(2))
        }
        // The conversation is read as soon as a figure is picked; the poll keeps it fresh.
        .task(id: model.selectedId) { await model.loadChat() }
        .accessibilityElement(children: .contain)
    }

    /// The sky behind the scene: pale blue over the city and the park, grey over snow; night blue
    /// in dark mode.
    static func sky(_ environment: OfficeEnvironment, dark: Bool) -> Color {
        switch (environment, dark) {
        case (.snow, false): Color(red: 0.86, green: 0.88, blue: 0.9)
        case (.snow, true): Color(red: 0.1, green: 0.11, blue: 0.15)
        case (.park, false): Color(red: 0.8, green: 0.91, blue: 0.96)
        case (_, false): Color(red: 0.8, green: 0.9, blue: 0.98)
        case (_, true): Color(red: 0.06, green: 0.08, blue: 0.14)
        }
    }

    /// What floats over the scene: the summary, errors, the hint and, on the right, the Chat Panel.
    private var overlays: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                summary
                if let text = model.errorText { NoticeBox(text: text, tint: .red) }
                Spacer()
                if model.selected == nil && !model.sessions.isEmpty {
                    Text(Copy.officeControlsHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .glass(in: Capsule())
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            if let session = model.selected {
                OfficeChatPanel(session: session, chat: model.chat, error: model.chatError) { model.select(nil) }
                    .frame(width: 380)
                    .frame(maxHeight: .infinity)
                    .transition(Motion.slide(from: .trailing, motion))
            }
        }
        .padding(16)
        .motion(value: model.errorText)
        .motion(value: model.selectedId)
    }

    private var summary: some View {
        Text(Copy.officeSummary(sessions: model.sessions.count, rooms: model.rooms.count))
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glass(in: Capsule())
            .opacity(model.sessions.isEmpty ? 0 : 1)
    }

    /// Fades the top of the scene into the window's background, so the title and the toolbar
    /// buttons read over a bright sky or a busy room.
    private var vignette: some View {
        LinearGradient(
            stops: [
                .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.85), location: 0),
                .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.4), location: 0.5),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "building.2").font(.system(size: 34)).foregroundStyle(.secondary)
            Text(Copy.officeEmpty).font(.title3.weight(.medium))
            Text(Copy.officeEmptyHint).font(.callout).foregroundStyle(.secondary)
        }
        .padding(20)
        .glass(in: RoundedRectangle(cornerRadius: 16))
        .allowsHitTesting(false)
    }
}

/// The RealityKit view with its camera controls: drag to orbit, pinch or scroll to zoom, click a
/// figure to select it.
private struct OfficeSceneView: View {
    let model: OfficeModel
    let controller: OfficeSceneController
    let style: OfficeStyle
    let environment: OfficeEnvironment
    @Environment(\.colorScheme) private var scheme
    @Environment(\.motionLevel) private var motion
    @State private var lastDrag = CGSize.zero
    @State private var lastMagnification: CGFloat = 1

    var body: some View {
        let layout = model.layout
        let sessions = model.sessions
        let selected = model.selectedId
        GeometryReader { proxy in
            RealityView { content in
                controller.install(into: &content)
            } update: { _ in
                controller.setAspect(Float(proxy.size.width / max(proxy.size.height, 1)))
                controller.sync(
                    layout: layout, sessions: sessions, selected: selected, style: style, environment: environment,
                    dark: scheme == .dark, animate: motion == .full)
            }
            .gesture(
                SpatialTapGesture().targetedToAnyEntity().onEnded { value in
                    model.select(OfficeSceneController.deskId(of: value.entity))
                }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        let deltaX = Float(value.translation.width - lastDrag.width)
                        let deltaY = Float(value.translation.height - lastDrag.height)
                        // Option-drag slides the view; a plain drag turns it.
                        if NSEvent.modifierFlags.contains(.option) {
                            controller.pan(deltaX: deltaX, deltaY: deltaY)
                        } else {
                            controller.orbit(deltaX: deltaX, deltaY: deltaY)
                        }
                        lastDrag = value.translation
                    }
                    .onEnded { _ in lastDrag = .zero }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        controller.zoom(by: Float(value.magnification / lastMagnification))
                        lastMagnification = value.magnification
                    }
                    .onEnded { _ in lastMagnification = 1 }
            )
            .background(
                ScrollControl { dx, dy, precise, command in
                    if precise && !command {
                        // Two fingers on a trackpad slide the view.
                        controller.pan(deltaX: dx, deltaY: dy)
                    } else {
                        controller.zoom(by: 1 + dy * (precise ? 0.01 : 0.05))
                    }
                })
        }
    }
}

/// Reports whether the view's window can be seen: not minimized, hidden or fully covered.
struct WindowVisibility: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) { view.onChange = onChange }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: (any NSObjectProtocol)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let newWindow else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: newWindow, queue: .main
            ) { [weak self, weak newWindow] _ in
                MainActor.assumeIsolated {
                    guard let window = newWindow else { return }
                    self?.onChange?(window.occlusionState.contains(.visible))
                }
            }
        }
    }
}

/// Scroll over the scene: two fingers slide it, the mouse wheel and ⌘-scroll zoom it.
private struct ScrollControl: NSViewRepresentable {
    /// Scroll deltas in points, whether the device is precise (a trackpad) and ⌘ is held.
    let onScroll: (Float, Float, Bool, Bool) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) { view.onScroll = onScroll }

    final class CatcherView: NSView {
        var onScroll: ((Float, Float, Bool, Bool) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard newWindow != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.window != nil, event.window === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                self.onScroll?(
                    Float(event.scrollingDeltaX), Float(event.scrollingDeltaY), event.hasPreciseScrollingDeltas,
                    event.modifierFlags.contains(.command))
                return nil
            }
        }
    }
}

/// The Chat Panel: one Session's title, project, status and last actions, and its conversation as
/// chat bubbles. It only shows; the Office cannot write to an agent.
struct OfficeChatPanel: View {
    let session: OfficeSession
    let chat: OfficeChatDocument?
    let error: String?
    let close: () -> Void
    @State private var actionsShown = false
    @Environment(\.motionLevel) private var motion

    private var agent: OfficeAgent { OfficeAgent(kind: session.agent) }

    private var path: String { (session.cwd as NSString).abbreviatingWithTildeInPath }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(14)
            Divider()
            conversation
        }
        .glass(in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(session.heading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(Color(red: agent.colour.red, green: agent.colour.green, blue: agent.colour.blue))
                    .frame(width: 12, height: 12)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.heading).font(.headline).lineLimit(2)
                    Text("\(agent.name) · \(Copy.officeStatusName(session.status.rawValue))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let app = session.hostApp, FileManager.default.fileExists(atPath: app) {
                    Button(Copy.openAgent) {
                        NSWorkspace.shared.openApplication(
                            at: URL(fileURLWithPath: app), configuration: NSWorkspace.OpenConfiguration())
                    }
                    .help((app as NSString).lastPathComponent)
                }
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(Copy.closeDetails)
                    .accessibilityLabel(Copy.closeDetails)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                row(Copy.officeProject, path)
                if let started = session.startedAt {
                    row(
                        Copy.officeStarted,
                        Date(timeIntervalSince1970: Double(started) / 1000)
                            .formatted(date: .omitted, time: .shortened))
                }
            }
            .font(.callout)
            DisclosureGroup(isExpanded: $actionsShown) {
                if session.recentActions.isEmpty {
                    Text(Copy.officeNoActions).font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(session.recentActions.reversed().enumerated()), id: \.offset) { _, action in
                            HStack(spacing: 8) {
                                Text(action.text).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(Date(timeIntervalSince1970: Double(action.at) / 1000), style: .relative)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                    .padding(.top, 4)
                }
            } label: {
                Text(Copy.officeLastActions).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .motion(value: actionsShown)
        }
    }

    /// The messages, newest at the bottom, scrolled there whenever one arrives.
    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let chat {
                        if chat.messages.isEmpty {
                            Text(Copy.officeNoChat).font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 20)
                        }
                        ForEach(Array(chat.messages.enumerated()), id: \.offset) { _, message in
                            ChatBubble(message: message, agent: agent)
                        }
                    } else if error == nil {
                        Text(Copy.officeChatLoading).font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 20)
                    }
                    if let error { NoticeBox(text: error, tint: .red) }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(14)
            }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: chat?.messages.count) { _, _ in
                withMotion(.smooth(duration: 0.3), motion) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        }
    }
}

/// One turn: the Owner's on the right in the accent colour, the agent's on the left.
private struct ChatBubble: View {
    let message: OfficeChatMessage
    let agent: OfficeAgent

    private var mine: Bool { message.role == .user }

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
            Text(message.text)
                .font(.callout)
                .textSelection(.enabled)
                .foregroundStyle(mine ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    mine ? Color.accentColor : Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 4) {
                Text(mine ? Copy.officeYou : agent.name)
                if message.at > 0 {
                    Text("·")
                    Text(Date(timeIntervalSince1970: Double(message.at) / 1000), style: .time)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(.leading, mine ? 40 : 0)
        .padding(.trailing, mine ? 0 : 40)
    }
}
