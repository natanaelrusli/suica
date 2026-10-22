import AppKit
import SuicaCore
import SwiftUI

/// Fades the menu bar panel in when it opens and out when it closes, at the level in effect.
/// SwiftUI's panel has no animation of its own either way: AppKit's utility-window behaviour fades
/// it out, and the fade in is run here, since no behaviour animates this panel coming in.
struct MenuPanelMotion: NSViewRepresentable {
    let level: MotionLevel

    func makeNSView(context: Context) -> PanelView { PanelView() }

    func updateNSView(_ view: PanelView, context: Context) { view.level = level }

    final class PanelView: NSView {
        var level: MotionLevel = .full {
            didSet { window?.animationBehavior = Self.behavior(level) }
        }
        private var observer: (any NSObjectProtocol)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let newWindow else { return }
            // Reopening makes the panel key just before it is drawn on screen (`isVisible` is already
            // true then, the occlusion state not yet); a panel already on screen is left alone.
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: newWindow, queue: .main
            ) { [weak self, weak newWindow] _ in
                MainActor.assumeIsolated {
                    guard let window = newWindow, !window.occlusionState.contains(.visible) else { return }
                    self?.fadeIn(window)
                }
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.animationBehavior = Self.behavior(level)
            // The first open: the panel is made around this view, on screen before its first frame.
            fadeIn(window)
        }

        private func fadeIn(_ window: NSWindow) {
            guard level != .off else { return }
            window.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = level == .full ? 0.2 : 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            }
        }

        private static func behavior(_ level: MotionLevel) -> NSWindow.AnimationBehavior {
            level == .off ? .none : .utilityWindow
        }
    }
}
