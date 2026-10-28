import AppKit
import SuicaCore
import SwiftUI

/// The Lessons as a graph: clusters by main Topic, a dot per Lesson sized by weight, lines
/// between Lessons that share a Topic. Drag to pan, pinch or ⌘-scroll to zoom, click a dot to
/// select the Lesson; the rest of the page shows it.
struct LessonsGraphView: View {
    let lessons: [LessonSummary]
    @Binding var selection: Int?

    @State private var graph = LessonGraph(lessons: [])
    @State private var hovered: Int?
    @State private var scale = 1.0
    @State private var offset = CGSize.zero
    @State private var size = CGSize.zero
    /// The view when a drag or pinch began.
    @State private var gestureStart: (scale: Double, offset: CGSize)?

    private static let zoomRange = 0.15...6.0
    private static let showAllLabelsFrom = 1.8

    var body: some View {
        Canvas { context, size in draw(&context, size) }
            .onGeometryChange(for: CGSize.self, of: \.size) { newSize in
                let first = size == .zero
                size = newSize
                if first { fit() }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { drag in
                        let start = gestureStart ?? (scale, offset)
                        gestureStart = start
                        offset = CGSize(
                            width: start.offset.width + drag.translation.width,
                            height: start.offset.height + drag.translation.height)
                    }
                    .onEnded { _ in gestureStart = nil }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { pinch in
                        let start = gestureStart ?? (scale, offset)
                        gestureStart = start
                        zoom(to: start.scale * pinch.magnification, around: pinch.startLocation, from: start)
                    }
                    .onEnded { _ in gestureStart = nil }
            )
            .simultaneousGesture(
                SpatialTapGesture().onEnded { tap in
                    let hit = node(at: tap.location)
                    selection = hit == selection ? nil : hit
                }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hovered = node(at: point)
                case .ended: hovered = nil
                }
            }
            .background(ScrollZoomCatcher { point, delta, zooming in
                if zooming {
                    zoom(to: scale * exp(Double(-delta.height) / 200), around: point, from: (scale, offset))
                } else {
                    offset = CGSize(width: offset.width + delta.width, height: offset.height + delta.height)
                }
            })
            .accessibilityChildren {
                ForEach(graph.nodes) { node in
                    Button(Copy.lessonNodeLabel(title: node.title, count: node.count)) { selection = node.id }
                }
            }
            .overlay(alignment: .topTrailing) { controls }
            .overlay {
                if lessons.isEmpty { Text(Copy.noLessonsMatch).foregroundStyle(.secondary) }
            }
            .task(id: lessons.map(\.id)) {
                graph = LessonGraph(lessons: lessons)
                fit()
            }
            .clipped()
    }

    private var controls: some View {
        HStack(spacing: 0) {
            Button { zoomStep(1 / 1.3) } label: { Image(systemName: "minus").frame(width: 26, height: 22) }
                .help(Copy.zoomOut)
            Button { fit() } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass").frame(width: 26, height: 22) }
                .help(Copy.fitGraph)
            Button { zoomStep(1.3) } label: { Image(systemName: "plus").frame(width: 26, height: 22) }
                .help(Copy.zoomIn)
        }
        .buttonStyle(.borderless)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.5)))
        .padding(10)
    }

    // MARK: View transform

    private func toScreen(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: x * scale + offset.width, y: y * scale + offset.height)
    }

    private func toWorld(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.width) / scale, y: (point.y - offset.height) / scale)
    }

    /// Scales and centres the graph in the view.
    private func fit() {
        let box = graph.bounds
        guard !box.isNull, size.width > 0, size.height > 0 else { return }
        let margin = 24.0
        let fitted = min((size.width - 2 * margin) / box.width, (size.height - 2 * margin) / box.height)
        withAnimation(.snappy(duration: 0.25)) {
            scale = min(max(fitted, Self.zoomRange.lowerBound), 1.5)
            offset = CGSize(
                width: size.width / 2 - box.midX * scale, height: size.height / 2 - box.midY * scale)
        }
    }

    /// Keeps the world point under `anchor` where it is while the scale changes.
    private func zoom(to target: Double, around anchor: CGPoint, from start: (scale: Double, offset: CGSize)) {
        let next = min(max(target, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        let ratio = next / start.scale
        scale = next
        offset = CGSize(
            width: anchor.x - (anchor.x - start.offset.width) * ratio,
            height: anchor.y - (anchor.y - start.offset.height) * ratio)
    }

    private func zoomStep(_ factor: Double) {
        withAnimation(.snappy(duration: 0.2)) {
            zoom(to: scale * factor, around: CGPoint(x: size.width / 2, y: size.height / 2), from: (scale, offset))
        }
    }

    private func radius(_ node: LessonGraph.Node) -> Double { max((6 + 9 * node.relativeWeight) * scale, 2.5) }

    private func node(at point: CGPoint) -> Int? {
        // A little slack around small dots; the nearest wins.
        let world = toWorld(point)
        var best: (id: Int, distance: Double)?
        for node in graph.nodes {
            let distance = hypot(node.x - world.x, node.y - world.y) * scale
            if distance <= radius(node) + 4, distance < (best?.distance ?? .infinity) { best = (node.id, distance) }
        }
        return best?.id
    }

    // MARK: Drawing

    private func color(_ cluster: Int, opacity: Double = 1) -> Color {
        guard graph.clusters[cluster].topic != nil else { return Color.gray.opacity(opacity) }
        let hue = (0.58 + 0.618 * Double(cluster)).truncatingRemainder(dividingBy: 1)
        return Color(hue: hue, saturation: 0.55, brightness: 0.85, opacity: opacity)
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        let focus = hovered ?? selection
        let near = focus.map { graph.neighbours(of: $0).union([$0]) }
        let byId = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        let view = CGRect(origin: .zero, size: size).insetBy(dx: -60, dy: -60)

        for (index, cluster) in graph.clusters.enumerated() {
            let center = toScreen(cluster.x, cluster.y)
            let r = cluster.radius * scale
            let zone = CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
            guard zone.insetBy(dx: -40, dy: -40).intersects(view) else { continue }
            context.fill(Path(ellipseIn: zone), with: .color(color(index, opacity: 0.1)))
            context.stroke(Path(ellipseIn: zone), with: .color(color(index, opacity: 0.35)), lineWidth: 1)
            let title = Text("\(DisplayText.clean(cluster.topic ?? Copy.noTopic, max: 40)) · \(cluster.count)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            context.draw(title, at: CGPoint(x: center.x, y: zone.minY - 12), anchor: .center)
        }

        // Lines between clusters always, faint; inside a cluster only for the focused Lesson.
        for edge in graph.edges {
            guard let a = byId[edge.a], let b = byId[edge.b] else { continue }
            let touches = focus.map { edge.a == $0 || edge.b == $0 } ?? false
            guard touches || a.cluster != b.cluster else { continue }
            var path = Path()
            path.move(to: toScreen(a.x, a.y))
            path.addLine(to: toScreen(b.x, b.y))
            let style: Color = touches ? color(a.cluster) : Color.secondary.opacity(focus == nil ? 0.22 : 0.07)
            context.stroke(path, with: .color(style), lineWidth: (touches ? 1.8 : 0.8) + 0.5 * Double(edge.shared - 1))
        }

        var labels: [(CGPoint, String, Bool, Bool)] = []
        for node in graph.nodes {
            let center = toScreen(node.x, node.y)
            guard view.contains(center) else { continue }
            let r = radius(node)
            let chosen = node.id == selection
            let faded = near.map { !$0.contains(node.id) } ?? false
            let dot = CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
            context.fill(Path(ellipseIn: dot), with: .color(color(node.cluster, opacity: faded ? 0.25 : 1)))
            context.stroke(Path(ellipseIn: dot), with: .color(.primary.opacity(faded ? 0.1 : 0.35)), lineWidth: 0.8)
            if chosen {
                context.stroke(Path(ellipseIn: dot.insetBy(dx: -4, dy: -4)), with: .color(.accentColor), lineWidth: 2)
            }
            if chosen || node.id == hovered || node.rank == 0
                || scale >= Self.showAllLabelsFrom
            {
                labels.append((CGPoint(x: center.x, y: center.y + r + 9), node.title, faded && node.rank != 0, node.id == hovered || chosen))
            }
        }
        // Labels last, so no dot or line covers one.
        for (point, title, faded, emphasised) in labels {
            let text = Text(DisplayText.clean(title, max: emphasised ? 80 : 28))
                .font(.caption.weight(emphasised ? .semibold : .regular))
                .foregroundStyle(faded ? .tertiary : .primary)
            context.draw(text, at: point, anchor: .center)
        }
    }
}

/// Reports scroll-wheel and trackpad scrolling over its view: ⌘ or ⌃ held means zoom, else pan.
/// Takes no clicks; the view behind it keeps them.
private struct ScrollZoomCatcher: NSViewRepresentable {
    let onScroll: (_ location: CGPoint, _ delta: CGSize, _ zooming: Bool) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) { view.onScroll = onScroll }

    final class CatcherView: NSView {
        var onScroll: ((CGPoint, CGSize, Bool) -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            // Removed when the view leaves its window, which comes before it is released.
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === window else { return event }
                let point = convert(event.locationInWindow, from: nil)
                guard bounds.contains(point) else { return event }
                let zooming = !event.modifierFlags.isDisjoint(with: [.command, .control])
                onScroll?(point, CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY), zooming)
                return nil
            }
        }

    }
}
