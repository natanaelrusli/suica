import AppKit
import SuicaCore
import SwiftUI

extension Color {
    /// An sRGB colour from 0xRRGGBB.
    init(hex: Int) {
        self.init(
            .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }

    /// 0xRRGGBB in sRGB, or nil when the colour cannot be read as sRGB.
    var hex: Int? {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let channel = { (value: CGFloat) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return channel(rgb.redComponent) << 16 | channel(rgb.greenComponent) << 8 | channel(rgb.blueComponent)
    }
}

extension AccentTheme {
    /// The accent colour, or nil to keep the system's (and for `custom`, see `AppearanceSettings.accent`).
    var color: Color? { hex.map(Color.init(hex:)) }

    /// The swatch in Appearance: the system's accent for `system`.
    var swatch: Color { color ?? .accentColor }
}

extension AppearanceSettings {
    /// The accent colour in use, or nil for the system's.
    var accent: Color? { accentHex.map(Color.init(hex:)) }
}

extension AppearanceMode {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Spacing that follows Appearance → Density.
struct Metrics: Equatable {
    /// Inside cards, tiles and rows.
    let padding: CGFloat
    /// Between cards on a page, and the page's margin.
    let gap: CGFloat
    /// Between the lines inside a row.
    let rowSpacing: CGFloat

    static let comfortable = Metrics(padding: 14, gap: 16, rowSpacing: 5)
    static let compact = Metrics(padding: 9, gap: 10, rowSpacing: 3)

    static func of(_ density: Density) -> Metrics { density == .compact ? .compact : .comfortable }
}

extension EnvironmentValues {
    @Entry var metrics: Metrics = .comfortable
}

/// Applies the Appearance choices to a scene's content: accent colour, light or dark, density and
/// the animation level (capped by the system's Reduce Motion).
struct AppearanceRoot: ViewModifier {
    let settings: AppearanceSettings
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    func body(content: Content) -> some View {
        content
            .tint(settings.accent)
            .preferredColorScheme(settings.mode.colorScheme)
            .environment(\.metrics, Metrics.of(settings.density))
            .environment(\.motionLevel, settings.motion.effective(systemReduceMotion: systemReduceMotion))
    }
}

extension View {
    func appearance(_ settings: AppearanceSettings) -> some View { modifier(AppearanceRoot(settings: settings)) }
}

/// A white symbol on a coloured rounded square, as in System Settings' sidebar.
struct SidebarIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.26))
            .accessibilityHidden(true)
    }
}

/// A status light: a ring breathes out of it while `active` and motion is full.
///
/// Drawn from the clock, not with `withAnimation`: a repeating animation started in `onAppear` also
/// animates whatever else is being laid out in that pass, which in the menu bar popover is the whole
/// panel opening, so its content slid about every time it opened.
struct StatusDot: View {
    let color: Color
    var active = false
    @Environment(\.motionLevel) private var level

    private static let period = 1.8

    var body: some View {
        let breathing = active && level == .full
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !breathing)) { context in
            let phase = breathing
                ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period
                : 0
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .background {
                    Circle()
                        .fill(color.opacity(0.45))
                        .scaleEffect(1 + 1.4 * phase)
                        .opacity(breathing ? 0.8 * (1 - phase) : 0)
                }
        }
        .accessibilityHidden(true)
    }
}

/// A refresh button whose arrow makes one turn when pressed (full motion only). The turn is
/// animated on the arrow alone, so it never animates anything else on screen.
struct RefreshButton: View {
    let action: () -> Void
    @Environment(\.motionLevel) private var level
    @State private var turns = 0

    var body: some View {
        Button {
            if level == .full { turns += 1 }
            action()
        } label: {
            Image(systemName: "arrow.clockwise")
                .rotationEffect(.degrees(Double(turns) * 360))
                .animation(.smooth(duration: 0.7), value: turns)
        }
        .help(Copy.refresh)
        .accessibilityLabel(Copy.refresh)
    }
}

extension View {
    /// Liquid Glass on macOS 26 and the regular material before it, for what floats over a page
    /// (the Office's overlays, a banner preview). The cards that make up a page stay opaque.
    @ViewBuilder func glass<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }
}
