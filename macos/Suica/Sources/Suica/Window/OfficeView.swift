import AppKit
import RealityKit
import SuicaCore
import SwiftUI

/// The coding agents running on this Mac, as a small 3D office: a Room per project, a Desk per
/// Session. It watches only; nothing here controls an agent.
struct OfficeView: View {
    let model: OfficeModel
    @State private var controller = OfficeSceneController()
    /// False while the window is minimized, hidden or covered: nothing is polled then.
    @State private var windowVisible = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.motionLevel) private var motion

    var body: some View {
        ZStack {
            (scheme == .dark ? Color(white: 0.11) : Color(white: 0.96))
            OfficeSceneView(model: model, controller: controller)
            if model.loaded && model.sessions.isEmpty { emptyState }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    summary
                    Spacer()
                    Button {
                        controller.resetCamera()
                        model.select(nil)
                    } label: {
                        Label(Copy.resetCamera, systemImage: "scope")
                    }
                    .help(Copy.resetCamera)
                }
                if let text = model.errorText { NoticeBox(text: text, tint: .red) }
                Spacer()
                if model.selected == nil && !model.sessions.isEmpty {
                    Text(Copy.officeControlsHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if let session = model.selected {
                    OfficeDetailCard(session: session) { model.select(nil) }
                        .frame(maxWidth: 420)
                        .transition(Motion.slide(from: .bottom, motion))
                }
            }
            .padding(16)
            .motion(value: model.errorText)
            .motion(value: model.selectedId)
        }
        .clipped()
        .background(WindowVisibility { windowVisible = $0 })
        // Polls only while the page is on screen: the scene and the detection stop with it.
        .task(id: windowVisible) {
            guard windowVisible else { return }
            await model.runPollLoop(every: .seconds(2))
        }
        .accessibilityElement(children: .contain)
    }

    private var summary: some View {
        Text(Copy.officeSummary(sessions: model.sessions.count, rooms: model.rooms.count))
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .opacity(model.sessions.isEmpty ? 0 : 1)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "building.2").font(.system(size: 34)).foregroundStyle(.secondary)
            Text(Copy.officeEmpty).font(.title3.weight(.medium))
            Text(Copy.officeEmptyHint).font(.callout).foregroundStyle(.secondary)
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .allowsHitTesting(false)
    }
}

/// The RealityKit view with its camera controls: drag to orbit, pinch or scroll to zoom, click a
/// figure to select it.
private struct OfficeSceneView: View {
    let model: OfficeModel
    let controller: OfficeSceneController
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
                    layout: layout, sessions: sessions, selected: selected, dark: scheme == .dark,
                    animate: motion == .full)
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
private struct WindowVisibility: NSViewRepresentable {
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
            ) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                let visible = window.occlusionState.contains(.visible)
                MainActor.assumeIsolated { self?.onChange?(visible) }
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

/// What one agent is doing: its type, project, status and last actions.
private struct OfficeDetailCard: View {
    let session: OfficeSession
    let close: () -> Void

    private var agent: OfficeAgent { OfficeAgent(kind: session.agent) }

    private var path: String { (session.cwd as NSString).abbreviatingWithTildeInPath }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(Color(red: agent.colour.red, green: agent.colour.green, blue: agent.colour.blue))
                    .frame(width: 12, height: 12)
                Text(agent.name).font(.headline)
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
                row(Copy.officeStatus, Copy.officeStatusName(session.status.rawValue))
                if let started = session.startedAt {
                    row(
                        Copy.officeStarted,
                        Date(timeIntervalSince1970: Double(started) / 1000)
                            .formatted(date: .omitted, time: .shortened))
                }
            }
            .font(.callout)
            Text(Copy.officeLastActions).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        }
    }
}
