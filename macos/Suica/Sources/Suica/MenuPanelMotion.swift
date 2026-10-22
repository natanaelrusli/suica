import AppKit
import ObjectiveC
import SuicaCore
import SwiftUI

/// Grows the menu bar panel, background and all, out of the menu bar icon when it opens and shrinks
/// it back into the icon when it closes, at the level in effect: `full` grows and shrinks, `reduced`
/// only fades, `off` shows and hides it at once.
///
/// SwiftUI's panel has no animation of its own, and hides itself with `order(.out, …)` at once. So
/// the panel's class gets two hooks (`PanelHooks`): opening (`makeKeyAndOrderFront`) starts the
/// growth, and hiding is held back until the shrink has played. The whole panel is drawn by its
/// frame view's layer, which is what is scaled.
struct MenuPanelMotion: NSViewRepresentable {
    let level: MotionLevel

    func makeNSView(context: Context) -> PanelView { PanelView() }

    func updateNSView(_ view: PanelView, context: Context) { view.level = level }

    final class PanelView: NSView {
        var level: MotionLevel = .full {
            didSet { window?.animationBehavior = Self.behavior(level) }
        }
        /// Counts the animations started, so a finished one only acts while it is the latest.
        private var generation = 0
        /// Set while the panel shrinks: hides it once the shrink is over.
        private var pendingHide: (() -> Void)?

        private static let startScale: CGFloat = 0.1
        private static let shrinkDuration = 0.22

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.animationBehavior = Self.behavior(level)
            PanelHooks.install(on: window, motion: self)
            // The first opening: the panel is made around this view, on screen before its first frame.
            present(window)
        }

        /// Called before the panel is ordered in: a reopening, or one during the shrink.
        func willOpen(_ window: NSWindow) {
            guard window === self.window else { return }
            if pendingHide != nil {
                pendingHide = nil
                present(window)
            } else if !window.isVisible {
                present(window)
            }
        }

        /// Called instead of hiding the panel; false lets it hide at once.
        func willHide(_ window: NSWindow, then hide: @escaping () -> Void) -> Bool {
            guard window === self.window, level == .full, window.isVisible, let layer = frameLayer(window) else {
                return false
            }
            if pendingHide != nil {
                pendingHide = hide
                return true
            }
            pendingHide = hide
            generation += 1
            let mine = generation
            window.hasShadow = false
            let ease = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.9, 0.6)
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = layer.presentation()?.transform ?? CATransform3DIdentity
            shrink.toValue = Self.transform(Self.startScale, toward: iconPoint(window, layer), in: layer)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.presentation()?.opacity ?? 1
            fade.toValue = 0
            for animation in [shrink, fade] {
                animation.duration = Self.shrinkDuration
                animation.timingFunction = ease
                animation.fillMode = .forwards
                animation.isRemovedOnCompletion = false
            }
            layer.removeAllAnimations()
            layer.add(shrink, forKey: "panel.transform")
            layer.add(fade, forKey: "panel.opacity")
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.shrinkDuration))
                guard let self, self.generation == mine, let hide = self.pendingHide else { return }
                self.pendingHide = nil
                hide()
                layer.removeAllAnimations()
                window.hasShadow = true
            }
            return true
        }

        private func present(_ window: NSWindow) {
            generation += 1
            let mine = generation
            switch level {
            case .off:
                frameLayer(window)?.removeAllAnimations()
                window.hasShadow = true
            case .reduced:
                frameLayer(window)?.removeAllAnimations()
                window.alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    window.animator().alphaValue = 1
                }
            case .full:
                guard let layer = frameLayer(window) else { return }
                window.alphaValue = 1
                // The shadow is drawn for the panel's full size: shown again once it is.
                window.hasShadow = false
                let grow = CASpringAnimation(keyPath: "transform")
                grow.fromValue =
                    layer.animation(forKey: "panel.transform") == nil
                    ? Self.transform(Self.startScale, toward: iconPoint(window, layer), in: layer)
                    : layer.presentation()?.transform
                grow.toValue = CATransform3DIdentity
                grow.mass = 1
                grow.stiffness = 260
                grow.damping = 28
                grow.duration = grow.settlingDuration
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = layer.animation(forKey: "panel.opacity") == nil ? 0 : layer.presentation()?.opacity
                fade.toValue = 1
                fade.duration = 0.18
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.removeAllAnimations()
                layer.add(grow, forKey: "panel.transform")
                layer.add(fade, forKey: "panel.opacity")
                let settle = grow.settlingDuration
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(settle))
                    guard self?.generation == mine else { return }
                    window.hasShadow = true
                    window.invalidateShadow()
                }
            }
        }

        /// The frame view's layer, which draws the whole panel. On the first opening AppKit has not
        /// made it yet when this view arrives, so it is asked for.
        private func frameLayer(_ window: NSWindow) -> CALayer? {
            guard let frame = window.contentView?.superview else { return nil }
            if frame.layer == nil { frame.wantsLayer = true }
            return frame.layer
        }

        /// The middle of the menu bar icon, on the panel's top edge, in the layer's coordinates.
        private func iconPoint(_ window: NSWindow, _ layer: CALayer) -> CGPoint {
            let bounds = layer.bounds
            let icon = NSApp.windows.first { $0.className.contains("StatusBarWindow") }?.frame
            let x = icon.map { min(max($0.midX - window.frame.minX, 0), bounds.width) } ?? bounds.midX
            return CGPoint(x: x, y: layer.isGeometryFlipped ? bounds.minY : bounds.maxY)
        }

        /// Scales the layer by `scale` around `point`, wherever its anchor point is.
        private static func transform(_ scale: CGFloat, toward point: CGPoint, in layer: CALayer) -> CATransform3D {
            let anchor = CGPoint(
                x: layer.bounds.minX + layer.bounds.width * layer.anchorPoint.x,
                y: layer.bounds.minY + layer.bounds.height * layer.anchorPoint.y)
            return CATransform3DConcat(
                CATransform3DMakeScale(scale, scale, 1),
                CATransform3DMakeTranslation((point.x - anchor.x) * (1 - scale), (point.y - anchor.y) * (1 - scale), 0))
        }

        private static func behavior(_ level: MotionLevel) -> NSWindow.AnimationBehavior {
            level == .reduced ? .utilityWindow : .none
        }
    }
}

/// Hooks on the panel's own class (not NSWindow): the panel calls into its `MenuPanelMotion` view
/// when it is about to be ordered in or out. AppKit's key-value observing has already given the panel
/// a subclass of its own, so the hooks go on the class it stands for, and only once.
@MainActor private enum PanelHooks {
    static weak var motion: MenuPanelMotion.PanelView?
    private static var hooked: Set<ObjectIdentifier> = []

    static func install(on window: NSWindow, motion view: MenuPanelMotion.PanelView) {
        motion = view
        guard var target = object_getClass(window) else { return }
        while NSStringFromClass(target).hasPrefix("NSKVONotifying_"), let parent = class_getSuperclass(target) {
            target = parent
        }
        guard hooked.insert(ObjectIdentifier(target)).inserted else { return }
        hookOrder(target)
        hookMakeKey(target)
    }

    private static func hookOrder(_ target: AnyClass) {
        let selector = #selector(NSWindow.order(_:relativeTo:))
        typealias Order = @convention(c) (NSWindow, Selector, Int, Int) -> Void
        guard let method = class_getInstanceMethod(target, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Order.self)
        let block: @convention(block) (NSWindow, Int, Int) -> Void = { window, place, other in
            let forward = { original(window, selector, place, other) }
            let held = MainActor.assumeIsolated {
                place == NSWindow.OrderingMode.out.rawValue && motion?.willHide(window, then: forward) == true
            }
            if !held { forward() }
        }
        replace(target, selector, method, imp_implementationWithBlock(block))
    }

    private static func hookMakeKey(_ target: AnyClass) {
        let selector = #selector(NSWindow.makeKeyAndOrderFront(_:))
        typealias MakeKey = @convention(c) (NSWindow, Selector, Any?) -> Void
        guard let method = class_getInstanceMethod(target, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: MakeKey.self)
        let block: @convention(block) (NSWindow, Any?) -> Void = { window, sender in
            MainActor.assumeIsolated { motion?.willOpen(window) }
            original(window, selector, sender)
        }
        replace(target, selector, method, imp_implementationWithBlock(block))
    }

    /// Overrides the method in `target` only: added when it inherits it, replaced when it has its own.
    private static func replace(_ target: AnyClass, _ selector: Selector, _ method: Method, _ imp: IMP) {
        if !class_addMethod(target, selector, imp, method_getTypeEncoding(method)) {
            method_setImplementation(method, imp)
        }
    }
}
