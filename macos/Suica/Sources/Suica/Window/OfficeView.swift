import AppKit
import RealityKit
import SuicaCore
import SwiftUI

/// The coding agents running on this Mac, as a small 3D office: a Room per project, a Desk per
/// Session. It watches, and sends the selected agent a message from the Chat Panel; nothing here stops or approves one.
struct OfficeView: View {
    let model: OfficeModel
    /// Where the building style and the environment are kept.
    @Bindable var settings: AppearanceSettings
    @State private var controller = OfficeSceneController()
    /// False while the window is minimized, hidden or covered: nothing is polled then.
    @State private var windowVisible = true
    /// The Owner closed the Chat Panel while a figure stays selected; picking a figure reopens it.
    @State private var panelHidden = false
    /// What the Owner is writing to the selected figure's agent.
    @State private var draft = ""
    /// The message field has focus.
    @State private var composing = false
    /// What the boss is saying, and at which Desk: from a send until 6 seconds after its turn ends.
    @State private var speech: (deskId: String, text: String)?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.motionLevel) private var motion

    var body: some View {
        // The scene runs up under the title bar, which floats over it on a vignette.
        UnderTitleBar { titleBar in
            ZStack {
                ZStack(alignment: .top) {
                    // The sky above the street.
                    Self.sky(settings.officeEnvironment, dark: night)
                    OfficeSceneView(
                        model: model, controller: controller, style: settings.officeStyle,
                        environment: settings.officeEnvironment, night: night, options: sceneOptions,
                        boss: bossOrder)
                    vignette.frame(height: titleBar + 70)
                }
                .clipped()
                if model.loaded && model.sessions.isEmpty { emptyState }
                overlays.padding(.top, titleBar)
            }
        }
        // The Chat Panel is a trailing sidebar beside the scene, not over it: scrolling it never
        // reaches the camera, and the scene keeps every pixel it has left.
        .inspector(isPresented: panelShown) {
            if let session = model.selected {
                OfficeChatPanel(
                    session: session, chat: model.chat, error: model.chatError, draft: $draft,
                    sending: model.sendingTo == session.id, notice: model.sendNotice, send: send,
                    dismissNotice: model.dismissSendNotice, composing: { composing = $0 }
                ) { model.select(nil) }
                .inspectorColumnWidth(min: 320, ideal: 400, max: 560)
            }
        }
        .onChange(of: model.selectedId) { _, id in
            if id != nil { panelHidden = false }
            // A draft belongs to the figure it was written to.
            draft = ""
            model.dismissSendNotice()
        }
        .toolbar {
            Button {
                panelHidden.toggle()
            } label: {
                Label(Copy.officeConversation, systemImage: "sidebar.trailing")
            }
            .help(Copy.officeChatToggleHint)
            .disabled(model.selected == nil)
            Menu {
                Picker(Copy.officeBuildingPicker, selection: $settings.officeStyle) {
                    ForEach(OfficeStyle.allCases) { Text($0.title).tag($0) }
                }
                Picker(Copy.officeEnvironmentPicker, selection: $settings.officeEnvironment) {
                    ForEach(OfficeEnvironment.allCases) { Text($0.title).tag($0) }
                }
                Picker(Copy.officeTimeOfDayPicker, selection: $settings.officeTimeOfDay) {
                    ForEach(OfficeTimeOfDay.allCases) { Text($0.title).tag($0) }
                }
                Picker(Copy.officeBubblesPicker, selection: $settings.officeBubbles) {
                    ForEach(OfficeBubbles.allCases) { Text($0.title).tag($0) }
                }
                Divider()
                Toggle(Copy.officeStreetLifeToggle, isOn: $settings.officeStreetLife)
                Toggle(Copy.officeSlowTurnToggle, isOn: $settings.officeSlowTurn)
                Toggle(Copy.officeBossToggle, isOn: $settings.officeBoss)
            } label: {
                Label(Copy.officeStyleMenu, systemImage: "slider.horizontal.3")
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

    /// Night by the app's mode, or pinned to day or night in the options.
    private var night: Bool { settings.officeTimeOfDay.isNight(darkMode: scheme == .dark) }

    private var sceneOptions: OfficeSceneOptions {
        OfficeSceneOptions(
            bubbles: settings.officeBubbles, streetLife: settings.officeStreetLife, slowTurn: settings.officeSlowTurn)
    }

    /// The boss stands at the selected figure's desk while the Owner writes to it, and speaks what
    /// was sent until a few seconds after the agent's turn ends.
    private var bossOrder: OfficeBossOrder? {
        guard settings.officeBoss, let id = model.selectedId, panelShown.wrappedValue else { return nil }
        if let speech, speech.deskId == id { return OfficeBossOrder(deskId: id, speech: speech.text) }
        let writing = composing || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return writing ? OfficeBossOrder(deskId: id, speech: nil) : nil
    }

    /// Sends the draft to the selected figure's agent; the boss says its first line meanwhile.
    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, model.sendingTo == nil, let id = model.selectedId else { return }
        draft = ""
        let said = OfficeLook.bossLine(text)
        speech = (id, said)
        Task {
            let sent = await model.send(text)
            // Not sent: the words come back so nothing is lost.
            if !sent && draft.isEmpty && model.selectedId == id { draft = text }
            try? await Task.sleep(for: .seconds(6))
            if speech?.deskId == id && speech?.text == said { speech = nil }
        }
    }

    /// Open while a figure is selected and the Owner has not closed it; closing it deselects.
    private var panelShown: Binding<Bool> {
        Binding(
            get: { model.selected != nil && !panelHidden },
            set: { shown in if !shown { model.select(nil) } })
    }

    /// What floats over the scene: the summary, errors and the hint.
    private var overlays: some View {
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

/// The RealityKit view with its camera controls: drag to orbit, right-drag, ⌥-drag or two-finger
/// scroll to pan, the wheel, a pinch or ⌘-scroll to zoom, click a figure to select it.
private struct OfficeSceneView: View {
    let model: OfficeModel
    let controller: OfficeSceneController
    let style: OfficeStyle
    let environment: OfficeEnvironment
    let night: Bool
    let options: OfficeSceneOptions
    let boss: OfficeBossOrder?
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
                    dark: night, animate: motion == .full, options: options, boss: boss)
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
                PointerControl { dx, dy, precise, command in
                    if precise && !command {
                        // Two fingers on a trackpad slide the view.
                        controller.pan(deltaX: dx, deltaY: dy)
                    } else {
                        // The mouse wheel, or ⌘ and two fingers, zooms.
                        controller.zoom(by: Float(OfficeCamera.zoomFactor(scrollDelta: Double(dy), precise: precise)))
                    }
                } onSecondaryDrag: { dx, dy in
                    // The mouse's right or middle button slides the view, as ⌥-drag does.
                    controller.pan(deltaX: dx, deltaY: dy)
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

/// The pointer events SwiftUI's gestures do not see, over the scene: the scroll wheel (two
/// fingers slide the view, the mouse wheel and ⌘-scroll zoom it) and a drag with the mouse's right
/// or middle button (slides the view).
private struct PointerControl: NSViewRepresentable {
    /// Scroll deltas in points, whether the device is precise (a trackpad) and ⌘ is held.
    let onScroll: (Float, Float, Bool, Bool) -> Void
    /// How far the pointer moved since the last call, in points, right and down positive.
    let onSecondaryDrag: (Float, Float) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        view.onSecondaryDrag = onSecondaryDrag
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
        view.onSecondaryDrag = onSecondaryDrag
    }

    final class CatcherView: NSView {
        var onScroll: ((Float, Float, Bool, Bool) -> Void)?
        var onSecondaryDrag: ((Float, Float) -> Void)?
        private var monitor: Any?
        /// Where the pointer was, in the window, while a right or middle button drag runs.
        private var dragPoint: NSPoint?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            dragPoint = nil
            guard newWindow != nil else { return }
            let events: NSEvent.EventTypeMask = [
                .scrollWheel, .rightMouseDown, .rightMouseDragged, .rightMouseUp, .otherMouseDown,
                .otherMouseDragged, .otherMouseUp,
            ]
            monitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
                guard let self, self.window != nil, event.window === self.window else { return event }
                switch event.type {
                case .scrollWheel:
                    return self.scroll(event)
                case .rightMouseDown, .otherMouseDown:
                    // The drag starts over the scene and follows the pointer wherever it goes.
                    guard self.covers(event) else { return event }
                    self.dragPoint = event.locationInWindow
                    return nil
                case .rightMouseDragged, .otherMouseDragged:
                    guard let from = self.dragPoint else { return event }
                    let to = event.locationInWindow
                    // Window coordinates grow upwards; the pan wants screen deltas, down positive.
                    self.onSecondaryDrag?(Float(to.x - from.x), Float(from.y - to.y))
                    self.dragPoint = to
                    return nil
                default:
                    guard self.dragPoint != nil else { return event }
                    self.dragPoint = nil
                    return nil
                }
            }
        }

        private func covers(_ event: NSEvent) -> Bool {
            bounds.contains(convert(event.locationInWindow, from: nil))
        }

        private func scroll(_ event: NSEvent) -> NSEvent? {
            guard covers(event) else { return event }
            // A scroll view of its own under the pointer (the Chat Panel's conversation, a
            // notice) keeps its scroll: only the page's own scroll view, which this catcher
            // shares, hands the wheel to the camera.
            if let hit = window?.contentView?.hitTest(event.locationInWindow),
                let scroller = hit.enclosingScrollView, scroller !== enclosingScrollView
            {
                return event
            }
            onScroll?(
                Float(event.scrollingDeltaX), Float(event.scrollingDeltaY), event.hasPreciseScrollingDeltas,
                event.modifierFlags.contains(.command))
            return nil
        }
    }
}

/// The Chat Panel: one Session's title, project, status and last actions, its conversation as
/// chat bubbles in a trailing sidebar, and a field to write to its agent.
struct OfficeChatPanel: View {
    let session: OfficeSession
    let chat: OfficeChatDocument?
    let error: String?
    @Binding var draft: String
    /// The agent is running the turn a message from here started.
    let sending: Bool
    /// Why the last message was not sent.
    let notice: String?
    let send: () -> Void
    let dismissNotice: () -> Void
    /// Tells the page when the field gains or loses focus, so the boss can walk over.
    let composing: (Bool) -> Void
    let close: () -> Void
    @State private var actionsShown = false
    @FocusState private var fieldFocused: Bool
    @Environment(\.motionLevel) private var motion

    private var agent: OfficeAgent { OfficeAgent(kind: session.agent) }

    private var agentColour: Color { Color(red: agent.colour.red, green: agent.colour.green, blue: agent.colour.blue) }

    private var path: String { (session.cwd as NSString).abbreviatingWithTildeInPath }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(14)
            Divider()
            conversation
            Divider()
            composer.padding(12)
        }
        .onChange(of: fieldFocused) { _, focused in composing(focused) }
        .onDisappear { composing(false) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(session.heading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                // The agent's initial on its colour, as Teams shows a person without a photo.
                Text(String(agent.name.prefix(1)))
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(agentColour.gradient, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.heading).font(.headline).lineLimit(3).textSelection(.enabled)
                    HStack(spacing: 6) {
                        Text(agent.name)
                        StatusPill(status: session.status)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
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
            HStack {
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
                if !actionsShown, let app = session.hostApp, FileManager.default.fileExists(atPath: app) {
                    Spacer()
                    Button(Copy.openAgent) {
                        NSWorkspace.shared.openApplication(
                            at: URL(fileURLWithPath: app), configuration: NSWorkspace.OpenConfiguration())
                    }
                    .controlSize(.small)
                    .help((app as NSString).lastPathComponent)
                }
            }
        }
    }

    /// The messages, newest at the bottom, where the view stays as more arrive.
    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if let chat {
                        if chat.messages.isEmpty {
                            placeholder(Copy.officeNoChat, symbol: "bubble.left.and.bubble.right")
                        } else {
                            Text(Copy.officeMessageCount(chat.messages.count))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.bottom, 8)
                        }
                        ForEach(Array(chat.messages.enumerated()), id: \.offset) { index, message in
                            // A run of messages from one side sits tight; the last one of a run has the time.
                            let next = index + 1 < chat.messages.count ? chat.messages[index + 1] : nil
                            ChatBubble(message: message, agent: agent, endsRun: next?.role != message.role)
                                .padding(.bottom, next?.role != message.role ? 10 : 0)
                        }
                    } else if error == nil {
                        placeholder(Copy.officeChatLoading, symbol: "ellipsis.bubble")
                    }
                    if let error { NoticeBox(text: error, tint: .red) }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(14)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: chat?.messages.count) { _, _ in
                withMotion(.smooth(duration: 0.3), motion) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    /// Only a Session that is not in the middle of a turn takes a message.
    private var busy: Bool { session.status == .working && !sending }

    private var canSend: Bool {
        !sending && !busy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The message field: Return sends, ⌥Return adds a line.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The busy line below already says what a busy notice would.
            if let notice, !(busy && notice == Copy.officeBusyHint) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(notice).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(action: dismissNotice) { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Copy.closeDetails)
                }
                .font(.caption)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(Copy.officeMessagePlaceholder, text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    .focused($fieldFocused)
                    .onSubmit { if canSend { send() } }
                    .accessibilityLabel(Copy.officeMessagePlaceholder)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                .disabled(!canSend)
                .help(Copy.officeSendMessage)
                .accessibilityLabel(Copy.officeSendMessage)
            }
            Group {
                if sending {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(Copy.officeSending)
                    }
                } else if busy {
                    Text(Copy.officeBusyHint)
                } else {
                    Text(Copy.officeSendHint)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func placeholder(_ text: String, symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tertiary)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 30)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        }
    }
}

/// A Session's status as a small tinted pill.
private struct StatusPill: View {
    let status: OfficeStatus

    private var tint: Color {
        switch status {
        case .working: .green
        case .waiting: .orange
        case .idle, .exited: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(Copy.officeStatusName(status.rawValue))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12), in: Capsule())
        .foregroundStyle(status == .working || status == .waiting ? tint : Color.secondary)
    }
}

/// One turn: the Owner's on the right in the accent colour, the agent's on the left as Markdown
/// (code blocks, lists and links as the agent wrote them). The time shows under the last message
/// of a run; every bubble can be copied.
private struct ChatBubble: View {
    let message: OfficeChatMessage
    let agent: OfficeAgent
    let endsRun: Bool

    private var mine: Bool { message.role == .user }

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
            Group {
                if mine {
                    Text(message.text).foregroundStyle(.white)
                } else {
                    MarkdownText(source: message.text)
                }
            }
            .font(.callout)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                mine ? Color.accentColor : Color.primary.opacity(0.08),
                in: UnevenRoundedRectangle(
                    topLeadingRadius: 14, bottomLeadingRadius: mine || !endsRun ? 14 : 4,
                    bottomTrailingRadius: mine && endsRun ? 4 : 14, topTrailingRadius: 14))
            .contextMenu {
                Button(Copy.copyMessage) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                }
            }
            if endsRun {
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
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(.leading, mine ? 36 : 0)
        .padding(.trailing, mine ? 0 : 36)
    }
}
