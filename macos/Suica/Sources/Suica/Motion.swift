import SwiftUI

/// The app's animations in one place. With Reduce Motion on, everything becomes a short fade:
/// nothing slides, scales or bounces.
enum Motion {
    /// Switching sidebar sections.
    static let page = Animation.smooth(duration: 0.3)
    /// Rows, banners and bars that appear, disappear or change.
    static let content = Animation.snappy(duration: 0.3)
    /// The sidebar opening or closing.
    static let sidebar = Animation.smooth(duration: 0.35)
    /// A page switching between one and two columns.
    static let layout = Animation.smooth(duration: 0.35)
    static let reduced = Animation.easeInOut(duration: 0.15)

    static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : animation
    }

    /// A section coming in: fades in while rising a little. The outgoing one fades out quickly,
    /// so the two pages barely overlap.
    static func page(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 10)).combined(with: .scale(scale: 0.99)),
            removal: .opacity.animation(.easeOut(duration: 0.1)))
    }

    /// A banner or row entering from the edge it belongs to.
    static func slide(from edge: Edge, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    /// Something that grows open in place, such as a send confirmation.
    static func reveal(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
    }
}

/// `.animation(_:value:)` that turns into a short fade under Reduce Motion.
struct MotionAnimation<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: Value

    func body(content: Content) -> some View {
        content.animation(Motion.animation(animation, reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    func motion<Value: Equatable>(_ animation: Animation = Motion.content, value: Value) -> some View {
        modifier(MotionAnimation(animation: animation, value: value))
    }
}
