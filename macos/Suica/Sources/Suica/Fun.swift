import AppKit
import SuicaCore
import SwiftUI

// MARK: - Backdrop

/// Appearance → Backdrop: a soft gradient that fades out downwards. Aurora drifts slowly with
/// full motion; every other style, and Aurora at lower motion, stands still.
struct BackdropView: View {
    let backdrop: Backdrop
    var strength: Double = 0.16
    @Environment(\.motionLevel) private var motion

    var body: some View {
        if let hexes = backdrop.colors, hexes.isEmpty {
            Color.clear
        } else {
            let colors = backdrop.colors?.map(Color.init(hex:)) ?? [Color.accentColor]
            let drifting = backdrop.drifts && motion == .full
            TimelineView(.animation(minimumInterval: 1 / 20, paused: !drifting)) { context in
                let phase = drifting ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 24) / 24 : 0
                Rectangle()
                    .fill(
                        AngularGradient(
                            colors: colors + [colors[0]], center: .top, angle: .degrees(phase * 360)))
                    .opacity(colors.count == 1 ? 1 : 0.9)
                    .blur(radius: colors.count == 1 ? 0 : 40)
            }
            .opacity(strength)
            .mask(LinearGradient(colors: [.black, .black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Menu bar icon

/// A watermelon slice for the menu bar: rind, flesh and seeds as cut-outs. A template image, so
/// macOS tints it like the penguin.
enum WatermelonGlyph {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            // The slice: the lower half of a circle, flat side up.
            let slice = NSBezierPath()
            slice.move(to: NSPoint(x: 1, y: 12))
            slice.appendArc(withCenter: NSPoint(x: 9, y: 12), radius: 8, startAngle: 180, endAngle: 360, clockwise: false)
            slice.close()
            // A thin gap between the rind and the flesh, and three seeds.
            let gap = NSBezierPath()
            gap.appendArc(withCenter: NSPoint(x: 9, y: 12), radius: 6.4, startAngle: 180, endAngle: 360, clockwise: false)
            gap.appendArc(withCenter: NSPoint(x: 9, y: 12), radius: 5.5, startAngle: 360, endAngle: 180, clockwise: true)
            gap.close()
            slice.append(gap)
            for (x, y) in [(6.0, 9.0), (9.0, 7.2), (12.0, 9.0)] {
                slice.append(NSBezierPath(ovalIn: NSRect(x: x - 0.8, y: y - 1.1, width: 1.6, height: 2.2)))
            }
            slice.windingRule = .evenOdd
            slice.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Suica"
        return image
    }()
}

/// What Appearance → Menu bar → Icon shows.
struct MenuBarIconView: View {
    let icon: MenuBarIcon
    let emoji: String

    var body: some View {
        switch icon {
        case .penguin: Image(nsImage: PenguinGlyph.image)
        case .watermelon: Image(nsImage: WatermelonGlyph.image)
        case .emoji: Text(emoji)
        }
    }
}

// MARK: - Celebrations

/// Plays a celebration sound once, even when the popover and the window both see the moment.
@MainActor
enum SoundPlayer {
    private static var lastPlayed = Date.distantPast

    static func play(_ effect: SoundEffect) {
        guard let name = effect.systemName, Date.now.timeIntervalSince(lastPlayed) > 0.8 else { return }
        lastPlayed = .now
        NSSound(named: NSSound.Name(name))?.play()
    }
}

/// A burst of confetti from the top, about 1.6 s, drawn in a `Canvas` and never in the way of clicks.
struct ConfettiView: View {
    let start: Date
    let colors: [Color]

    private struct Piece {
        let x: Double, drift: Double, speed: Double, spin: Double, size: Double, delay: Double, color: Int, round: Bool
    }

    private static let duration = 1.6
    private let pieces: [Piece] = (0..<90).map { index in
        var generator = SystemRandomNumberGenerator()
        func random(_ range: ClosedRange<Double>) -> Double { Double.random(in: range, using: &generator) }
        return Piece(
            x: random(0...1), drift: random(-0.25...0.25), speed: random(0.7...1.3), spin: random(-8...8),
            size: random(5...9), delay: random(0...0.35), color: index, round: index % 3 == 0)
    }

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(start)
            Canvas { canvas, size in
                for piece in pieces {
                    let t = max(0, elapsed - piece.delay) / Self.duration
                    guard t > 0, t < 1 else { continue }
                    let x = (piece.x + piece.drift * t) * size.width
                    // Up a little, then down faster: a toss, not a curtain.
                    let y = (-0.1 + piece.speed * (1.25 * t * t - 0.15 * t)) * size.height
                    var copy = canvas
                    copy.opacity = t > 0.75 ? (1 - t) / 0.25 : 1
                    copy.translateBy(x: x, y: y)
                    copy.rotate(by: .radians(piece.spin * t))
                    let rect = CGRect(x: -piece.size / 2, y: -piece.size / 4, width: piece.size, height: piece.size / 2)
                    let shape = piece.round ? Path(ellipseIn: rect.insetBy(dx: piece.size / 6, dy: -piece.size / 6)) : Path(rect)
                    copy.fill(shape, with: .color(colors[piece.color % colors.count]))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Celebrates `trigger` changes (a send, an approval, inbox zero) with confetti and the chosen
/// sound, as Appearance says. Confetti needs full motion.
struct Celebrating: ViewModifier {
    let settings: AppearanceSettings
    let trigger: Int
    @Environment(\.motionLevel) private var motion
    @State private var burst: Date?

    func body(content: Content) -> some View {
        content
            .overlay {
                if let burst {
                    ConfettiView(start: burst, colors: palette)
                        .task(id: burst) {
                            try? await Task.sleep(for: .seconds(2.2))
                            if self.burst == burst { self.burst = nil }
                        }
                }
            }
            .onChange(of: trigger) { _, _ in
                SoundPlayer.play(settings.sound)
                if settings.celebrations && motion == .full { burst = .now }
            }
    }

    private var palette: [Color] {
        let backdrop = settings.backdrop.colors?.map(Color.init(hex:)) ?? []
        return [settings.accent ?? .accentColor, .yellow, .pink, .mint] + backdrop
    }
}

extension View {
    func celebrating(_ settings: AppearanceSettings, trigger: Int) -> some View {
        modifier(Celebrating(settings: settings, trigger: trigger))
    }
}

/// Counts the moments the app celebrates: messages sent, MRs approved, and inbox zero (the badge
/// going to nothing). Each change of `value` is one celebration.
@MainActor @Observable
final class CelebrationCounter {
    private(set) var value = 0
    private var badge: Int?

    func badgeChanged(to count: Int) {
        if let badge, Celebration.onBadgeChange(from: badge, to: count) == .inboxZero { value += 1 }
        badge = count
    }

    /// Asks for one now, as Appearance's Try it does.
    func celebrate() { value += 1 }
}
