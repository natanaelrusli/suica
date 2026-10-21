import SuicaCore
import SwiftUI

/// The app's animations in one place, at the level Appearance → Animation and the system's
/// Reduce Motion allow: `full` slides, scales and bounces; `reduced` only fades, briefly;
/// `off` changes everything at once.
enum Motion {
    /// Switching sidebar sections.
    static let page = Animation.smooth(duration: 0.3)
    /// Rows, banners and bars that appear, disappear or change.
    static let content = Animation.snappy(duration: 0.3)
    /// A page switching between one and two columns.
    static let layout = Animation.smooth(duration: 0.35)
    /// A control answering the pointer.
    static let hover = Animation.snappy(duration: 0.18)
    static let reduced = Animation.easeInOut(duration: 0.15)

    static func animation(_ animation: Animation, _ level: MotionLevel) -> Animation? {
        switch level {
        case .full: animation
        case .reduced: reduced
        case .off: nil
        }
    }

    /// A section coming in: fades in while rising a little. The outgoing one fades out quickly,
    /// so the two pages barely overlap. No scale: it resized the page's AppKit views (lists, search
    /// fields, buttons) on every frame, which doubled the cost of the animation on Reviews.
    static func page(_ level: MotionLevel) -> AnyTransition {
        switch level {
        case .full:
            .asymmetric(
                insertion: .opacity.combined(with: .offset(y: 10)),
                removal: .opacity.animation(.easeOut(duration: 0.1)))
        case .reduced: .opacity
        case .off: .identity
        }
    }

    /// A banner or row entering from the edge it belongs to.
    static func slide(from edge: Edge, _ level: MotionLevel) -> AnyTransition {
        switch level {
        case .full: .move(edge: edge).combined(with: .opacity)
        case .reduced: .opacity
        case .off: .identity
        }
    }

    /// A notice dropping into place from just above, and folding away the same way when closed.
    static func notice(_ level: MotionLevel) -> AnyTransition {
        switch level {
        case .full: .opacity.combined(with: .offset(y: -8)).combined(with: .scale(scale: 0.97, anchor: .top))
        case .reduced: .opacity
        case .off: .identity
        }
    }

    /// Something that grows open in place, such as a send confirmation.
    static func reveal(_ level: MotionLevel) -> AnyTransition {
        switch level {
        case .full: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
        case .reduced: .opacity
        case .off: .identity
        }
    }
}

extension EnvironmentValues {
    /// The animation level in effect: Appearance → Animation, capped by Reduce Motion.
    @Entry var motionLevel: MotionLevel = .full
}

/// `.animation(_:value:)` at the level in effect.
struct MotionAnimation<Value: Equatable>: ViewModifier {
    @Environment(\.motionLevel) private var level
    let animation: Animation
    let value: Value

    func body(content: Content) -> some View {
        content.animation(Motion.animation(animation, level), value: value)
    }
}

extension View {
    func motion<Value: Equatable>(_ animation: Animation = Motion.content, value: Value) -> some View {
        modifier(MotionAnimation(animation: animation, value: value))
    }

    /// Lifts the view a little and shades it while the pointer is over it, at full motion only.
    func hoverLift(cornerRadius: CGFloat = 10) -> some View {
        modifier(HoverLift(cornerRadius: cornerRadius))
    }

    /// Comes in after `index` earlier siblings, so a row of tiles fills in one after another.
    func staggeredEntrance(_ index: Int) -> some View {
        modifier(StaggeredEntrance(index: index))
    }

    /// Grows briefly each time `trigger` changes, to draw the eye to a figure that just changed.
    func pulse<Trigger: Equatable>(on trigger: Trigger) -> some View {
        modifier(Pulse(trigger: trigger))
    }
}

/// `withAnimation` at the level in effect.
@MainActor func withMotion<Result>(_ animation: Animation, _ level: MotionLevel, _ body: () throws -> Result) rethrows
    -> Result
{
    try withAnimation(Motion.animation(animation, level), body)
}

private struct HoverLift: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.motionLevel) private var level
    @State private var hovering = false

    func body(content: Content) -> some View {
        let lifted = hovering && level == .full
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.tint.opacity(hovering ? 0.06 : 0))
            )
            .shadow(color: .black.opacity(lifted ? 0.10 : 0), radius: lifted ? 6 : 0, y: lifted ? 2 : 0)
            .scaleEffect(lifted ? 1.01 : 1)
            .onHover { inside in withMotion(Motion.hover, level) { hovering = inside } }
    }
}

/// The entrance starts in `.task`, after the first layout, and its animation is scoped to this
/// view: started from `onAppear` with `withAnimation`, it also animated the window's own first layout.
private struct StaggeredEntrance: ViewModifier {
    let index: Int
    @Environment(\.motionLevel) private var level
    @State private var shown = false

    func body(content: Content) -> some View {
        let base = Motion.animation(.smooth(duration: 0.35), level)
        content
            .opacity(shown || level == .off ? 1 : 0)
            .offset(y: shown || level != .full ? 0 : 8)
            .animation(level == .full ? base?.delay(Double(index) * 0.05) : base, value: shown)
            .task { shown = true }
    }
}

private struct Pulse<Trigger: Equatable>: ViewModifier {
    let trigger: Trigger
    @Environment(\.motionLevel) private var level

    func body(content: Content) -> some View {
        if level == .full {
            content.phaseAnimator([false, true], trigger: trigger) { view, grown in
                view.scaleEffect(grown ? 1.12 : 1)
            } animation: { _ in .snappy(duration: 0.18) }
        } else {
            content
        }
    }
}
