import Foundation
import Observation

/// The accent colour of the popover and the window. `system` follows System Settings → Appearance.
public enum AccentTheme: String, CaseIterable, Identifiable, Sendable {
    /// The blue of the app icon's sky.
    case glacier, system, suica, tangerine, watermelon, grape, graphite

    public var id: String { rawValue }

    public var title: String { Copy.title(self) }

    /// sRGB as 0xRRGGBB, or nil for the system accent colour.
    public var hex: Int? {
        switch self {
        case .glacier: 0x1C7FD6
        case .system: nil
        case .suica: 0x2E9E4F
        case .tangerine: 0xE8850C
        case .watermelon: 0xE5484D
        case .grape: 0x8E4EC6
        case .graphite: 0x6B7280
        }
    }
}

/// Light or dark, independent of the system setting.
public enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    public var id: String { rawValue }

    public var title: String { Copy.title(self) }
}

/// How much room rows, cards and tiles take.
public enum Density: String, CaseIterable, Identifiable, Sendable {
    case comfortable, compact
    public var id: String { rawValue }

    public var title: String { Copy.title(self) }
}

/// How much the app animates. Ordered from most to least.
public enum MotionLevel: String, CaseIterable, Identifiable, Comparable, Sendable {
    /// Slides, springs, bounces and hover effects.
    case full
    /// Short fades only, as with the system's Reduce Motion.
    case reduced
    /// Nothing animates.
    case off

    public var id: String { rawValue }

    public var title: String { Copy.title(self) }

    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (lhs: MotionLevel, rhs: MotionLevel) -> Bool { lhs.rank < rhs.rank }

    /// The level the app uses: the system's Reduce Motion caps the choice at `reduced`.
    public func effective(systemReduceMotion: Bool) -> MotionLevel {
        systemReduceMotion ? max(self, .reduced) : self
    }
}

/// What the menu bar icon shows next to the penguin while messages need you.
public enum MenuBarBadge: String, CaseIterable, Identifiable, Sendable {
    case count, dot, hidden
    public var id: String { rawValue }

    public var title: String { Copy.title(self) }

    /// The text beside the icon, or nil for none.
    public func label(for count: Int) -> String? {
        guard count > 0 else { return nil }
        switch self {
        case .count: return "\(count)"
        case .dot: return "●"
        case .hidden: return nil
        }
    }
}

/// The page the window opens on.
public enum StartPage: String, CaseIterable, Identifiable, Sendable {
    case overview, reviews, messages
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview: Copy.overview
        case .reviews: Copy.reviewRequests
        case .messages: Copy.messages
        }
    }
}

/// Where the Appearance choices are kept: the app's user defaults, or an in-memory store in tests
/// (a `UserDefaults` suite would leave a preferences file behind on every test run).
public protocol PreferenceStore: AnyObject {
    func string(forKey key: String) -> String?
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: PreferenceStore {}

/// The app's own look and feel, kept in the app's user defaults. Unlike the agent's config file it
/// applies at once and only to this app.
@MainActor @Observable
public final class AppearanceSettings {
    public var theme: AccentTheme { didSet { store(theme.rawValue, Key.theme) } }
    public var mode: AppearanceMode { didSet { store(mode.rawValue, Key.mode) } }
    public var density: Density { didSet { store(density.rawValue, Key.density) } }
    public var motion: MotionLevel { didSet { store(motion.rawValue, Key.motion) } }
    public var menuBarBadge: MenuBarBadge { didSet { store(menuBarBadge.rawValue, Key.badge) } }
    /// The Tracked / To review / Needs you figures at the top of the popover.
    public var showsPopoverCounters: Bool { didSet { defaults.set(showsPopoverCounters, forKey: Key.counters) } }
    public var startPage: StartPage { didSet { store(startPage.rawValue, Key.start) } }

    @ObservationIgnored private let defaults: any PreferenceStore

    private enum Key {
        static let theme = "appearance.theme"
        static let mode = "appearance.mode"
        static let density = "appearance.density"
        static let motion = "appearance.motion"
        static let badge = "appearance.menuBarBadge"
        static let counters = "appearance.popoverCounters"
        static let start = "appearance.startPage"
        static let all = [theme, mode, density, motion, badge, counters, start]
    }

    /// `defaults` is the app's own (`.standard`) unless a test passes its own domain.
    /// The default of every choice, in one place for `init`, `isDefault` and `reset`.
    private enum Default {
        static let theme = AccentTheme.glacier
        static let mode = AppearanceMode.system
        static let density = Density.comfortable
        static let motion = MotionLevel.full
        static let badge = MenuBarBadge.count
        static let counters = true
        static let start = StartPage.overview
    }

    /// `defaults` is the app's own (`UserDefaults.standard`) unless a test passes its own store.
    public init(defaults: (any PreferenceStore)? = nil) {
        let defaults = defaults ?? UserDefaults.standard
        self.defaults = defaults
        // An unknown stored value (from a newer build, or edited by hand) falls back to the default.
        func read<T: RawRepresentable<String>>(_ key: String, _ fallback: T) -> T {
            guard let raw = defaults.string(forKey: key), let value = T(rawValue: raw) else { return fallback }
            return value
        }
        theme = read(Key.theme, Default.theme)
        mode = read(Key.mode, Default.mode)
        density = read(Key.density, Default.density)
        motion = read(Key.motion, Default.motion)
        menuBarBadge = read(Key.badge, Default.badge)
        showsPopoverCounters = defaults.object(forKey: Key.counters) as? Bool ?? Default.counters
        startPage = read(Key.start, Default.start)
    }

    public var isDefault: Bool {
        theme == Default.theme && mode == Default.mode && density == Default.density && motion == Default.motion
            && menuBarBadge == Default.badge && showsPopoverCounters == Default.counters
            && startPage == Default.start
    }

    /// Every choice back to its default, and the stored values removed.
    public func reset() {
        theme = Default.theme
        mode = Default.mode
        density = Default.density
        motion = Default.motion
        menuBarBadge = Default.badge
        showsPopoverCounters = Default.counters
        startPage = Default.start
        for key in Key.all { defaults.removeObject(forKey: key) }
    }

    private func store(_ value: String, _ key: String) { defaults.set(value, forKey: key) }
}
