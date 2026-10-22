import Foundation
import Observation

/// The accent colour of the popover and the window. `system` follows System Settings → Appearance.
public enum AccentTheme: String, CaseIterable, Identifiable, Sendable {
    /// The blue of the app icon's sky. `custom` is the colour picked in Appearance.
    case glacier, system, suica, tangerine, watermelon, grape, graphite, custom

    public var id: String { rawValue }

    public var title: String { Copy.title(self) }

    /// sRGB as 0xRRGGBB, or nil for the system accent colour and for `custom`, whose colour
    /// `AppearanceSettings.accentHex` holds.
    public var hex: Int? {
        switch self {
        case .custom: nil
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

/// What sits in the menu bar.
public enum MenuBarIcon: String, CaseIterable, Identifiable, Sendable {
    case penguin, watermelon, emoji
    public var id: String { rawValue }

    public var title: String { Copy.title(self) }
}

/// The soft wash behind the window's pages and the popover header.
public enum Backdrop: String, CaseIterable, Identifiable, Sendable {
    case plain, wash, sunrise, lagoon, watermelon, aurora
    public var id: String { rawValue }

    public var title: String { Copy.title(self) }

    /// Gradient stops as 0xRRGGBB, top to bottom; empty for none, nil for the accent colour.
    public var colors: [Int]? {
        switch self {
        case .plain: []
        case .wash: nil
        case .sunrise: [0xFF9A62, 0xFF6F91, 0xFFC75F]
        case .lagoon: [0x2EC4B6, 0x1C7FD6, 0x9BE7FF]
        case .watermelon: [0xE5484D, 0xFF8FA3, 0x2E9E4F]
        case .aurora: [0x7F5AF0, 0x2CB67D, 0x1C7FD6, 0xE5484D]
        }
    }

    /// Only Aurora moves, and only with full motion.
    public var drifts: Bool { self == .aurora }
}

/// What the Office building is made of: its walls, floors and desks.
public enum OfficeStyle: String, CaseIterable, Identifiable, Sendable {
    /// White plaster, wooden planks and carpet tiles.
    case modern
    /// Red brick, terracotta tiles and a stone hall.
    case brick
    /// Steel frames with tinted glass, concrete floors and a slate hall.
    case glass
    /// Honey logs, dark planks and a woven rug.
    case timber
    public var id: String { rawValue }

    public var title: String { Copy.title(self) }
}

/// What lies outside the Office building.
public enum OfficeEnvironment: String, CaseIterable, Identifiable, Sendable {
    /// A street: road, pavements, lamps, cars, cyclists and walkers.
    case city
    /// A lawn with paths, flower beds, a pond and more trees; no cars.
    case park
    /// The street under snow, with a pale sky.
    case snow
    public var id: String { rawValue }

    public var title: String { Copy.title(self) }
}

/// Whether the Office shows day or night: as the app's light or dark mode, or always one.
public enum OfficeTimeOfDay: String, CaseIterable, Identifiable, Sendable {
    case system, day, night
    public var id: String { rawValue }

    public var title: String { Copy.title(self) }

    /// Night lights the lamps, shows the moon and darkens the sky.
    public func isNight(darkMode: Bool) -> Bool {
        switch self {
        case .system: darkMode
        case .day: false
        case .night: true
        }
    }
}

/// Which figures show their bubble.
public enum OfficeBubbles: String, CaseIterable, Identifiable, Sendable {
    case all, selected, off
    public var id: String { rawValue }

    public var title: String { Copy.title(self) }

    public func shows(selected: Bool) -> Bool {
        switch self {
        case .all: true
        case .selected: selected
        case .off: false
        }
    }
}

/// A system sound for a celebration.
public enum SoundEffect: String, CaseIterable, Identifiable, Sendable {
    case off, pop, glass, purr, hero, tink, submarine
    public var id: String { rawValue }

    public var title: String { Copy.title(self) }

    /// The name of the sound in /System/Library/Sounds, or nil for none.
    public var systemName: String? { self == .off ? nil : rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// A moment the app celebrates.
public enum Celebration: Equatable, Sendable {
    case sent, approved, inboxZero

    /// Inbox zero is the badge going from something to nothing, never staying at nothing.
    public static func onBadgeChange(from old: Int, to new: Int) -> Celebration? {
        old > 0 && new == 0 ? .inboxZero : nil
    }
}

/// Several choices in one click; each can be changed afterwards.
public enum AppearancePreset: String, CaseIterable, Identifiable, Sendable {
    case classic, watermelonParty, midnight, sunrise, zen
    public var id: String { rawValue }

    public var title: String { Copy.title(self) }

    /// A few emoji that say what it is, for its button.
    public var emblem: String {
        switch self {
        case .classic: "🐧"
        case .watermelonParty: "🍉"
        case .midnight: "🌌"
        case .sunrise: "🌅"
        case .zen: "🍵"
        }
    }

    @MainActor public func apply(to settings: AppearanceSettings) {
        switch self {
        case .classic:
            settings.theme = .glacier
            settings.mode = .system
            settings.backdrop = .wash
            settings.menuBarIcon = .penguin
            settings.celebrations = true
            settings.sound = .off
        case .watermelonParty:
            settings.theme = .watermelon
            settings.backdrop = .watermelon
            settings.menuBarIcon = .watermelon
            settings.motion = .full
            settings.celebrations = true
            settings.sound = .pop
        case .midnight:
            settings.theme = .grape
            settings.mode = .dark
            settings.backdrop = .aurora
            settings.celebrations = true
            settings.sound = .purr
        case .sunrise:
            settings.theme = .tangerine
            settings.mode = .light
            settings.backdrop = .sunrise
            settings.celebrations = true
            settings.sound = .glass
        case .zen:
            settings.theme = .graphite
            settings.backdrop = .plain
            settings.density = .compact
            settings.motion = .reduced
            settings.menuBarBadge = .dot
            settings.celebrations = false
            settings.sound = .off
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
    /// The colour of the `custom` theme, as 0xRRGGBB.
    public var customAccent: Int { didSet { defaults.set(customAccent, forKey: Key.customAccent) } }
    public var menuBarIcon: MenuBarIcon { didSet { store(menuBarIcon.rawValue, Key.icon) } }
    /// The menu bar emoji: always one character (one grapheme, so 👩‍💻 stays whole).
    public var menuBarEmoji: String {
        didSet {
            // Assigning inside didSet does not run didSet again, so this stores once.
            let one = Self.oneEmoji(menuBarEmoji)
            if one != menuBarEmoji { menuBarEmoji = one }
            store(one, Key.emoji)
        }
    }
    public var backdrop: Backdrop { didSet { store(backdrop.rawValue, Key.backdrop) } }
    /// Confetti when you send, approve or reach inbox zero.
    public var celebrations: Bool { didSet { defaults.set(celebrations, forKey: Key.celebrations) } }
    public var sound: SoundEffect { didSet { store(sound.rawValue, Key.sound) } }
    /// The Office building's style and what lies outside it.
    public var officeStyle: OfficeStyle { didSet { store(officeStyle.rawValue, Key.officeStyle) } }
    public var officeEnvironment: OfficeEnvironment {
        didSet { store(officeEnvironment.rawValue, Key.officeEnvironment) }
    }
    public var officeTimeOfDay: OfficeTimeOfDay { didSet { store(officeTimeOfDay.rawValue, Key.officeTimeOfDay) } }
    public var officeBubbles: OfficeBubbles { didSet { store(officeBubbles.rawValue, Key.officeBubbles) } }
    /// Walkers, cyclists and cars on the street.
    public var officeStreetLife: Bool { didSet { defaults.set(officeStreetLife, forKey: Key.officeStreetLife) } }
    /// The camera turns slowly round the office while nothing is dragged.
    public var officeSlowTurn: Bool { didSet { defaults.set(officeSlowTurn, forKey: Key.officeSlowTurn) } }
    /// The boss walks to a figure while you write to it.
    public var officeBoss: Bool { didSet { defaults.set(officeBoss, forKey: Key.officeBoss) } }

    @ObservationIgnored private let defaults: any PreferenceStore

    private enum Key {
        static let theme = "appearance.theme"
        static let mode = "appearance.mode"
        static let density = "appearance.density"
        static let motion = "appearance.motion"
        static let badge = "appearance.menuBarBadge"
        static let counters = "appearance.popoverCounters"
        static let start = "appearance.startPage"
        static let customAccent = "appearance.customAccent"
        static let icon = "appearance.menuBarIcon"
        static let emoji = "appearance.menuBarEmoji"
        static let backdrop = "appearance.backdrop"
        static let celebrations = "appearance.celebrations"
        static let sound = "appearance.sound"
        static let officeStyle = "appearance.officeStyle"
        static let officeEnvironment = "appearance.officeEnvironment"
        static let officeTimeOfDay = "appearance.officeTimeOfDay"
        static let officeBubbles = "appearance.officeBubbles"
        static let officeStreetLife = "appearance.officeStreetLife"
        static let officeSlowTurn = "appearance.officeSlowTurn"
        static let officeBoss = "appearance.officeBoss"
        static let all = [
            theme, mode, density, motion, badge, counters, start, customAccent, icon, emoji, backdrop, celebrations,
            sound, officeStyle, officeEnvironment, officeTimeOfDay, officeBubbles, officeStreetLife, officeSlowTurn,
            officeBoss,
        ]
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
        static let customAccent = 0xE5484D
        static let icon = MenuBarIcon.penguin
        static let emoji = "🍉"
        static let backdrop = Backdrop.wash
        static let celebrations = true
        static let sound = SoundEffect.off
        static let officeStyle = OfficeStyle.modern
        static let officeEnvironment = OfficeEnvironment.city
        static let officeTimeOfDay = OfficeTimeOfDay.system
        static let officeBubbles = OfficeBubbles.all
        static let officeStreetLife = true
        static let officeSlowTurn = false
        static let officeBoss = true
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
        customAccent = (defaults.object(forKey: Key.customAccent) as? Int).map { $0 & 0xFFFFFF } ?? Default.customAccent
        menuBarIcon = read(Key.icon, Default.icon)
        menuBarEmoji = Self.oneEmoji(defaults.string(forKey: Key.emoji) ?? Default.emoji)
        backdrop = read(Key.backdrop, Default.backdrop)
        celebrations = defaults.object(forKey: Key.celebrations) as? Bool ?? Default.celebrations
        sound = read(Key.sound, Default.sound)
        officeStyle = read(Key.officeStyle, Default.officeStyle)
        officeEnvironment = read(Key.officeEnvironment, Default.officeEnvironment)
        officeTimeOfDay = read(Key.officeTimeOfDay, Default.officeTimeOfDay)
        officeBubbles = read(Key.officeBubbles, Default.officeBubbles)
        officeStreetLife = defaults.object(forKey: Key.officeStreetLife) as? Bool ?? Default.officeStreetLife
        officeSlowTurn = defaults.object(forKey: Key.officeSlowTurn) as? Bool ?? Default.officeSlowTurn
        officeBoss = defaults.object(forKey: Key.officeBoss) as? Bool ?? Default.officeBoss
    }

    /// The accent colour as 0xRRGGBB, or nil for the system's.
    public var accentHex: Int? { theme == .custom ? customAccent : theme.hex }

    /// The first character of `text`, or the default emoji when there is none.
    static func oneEmoji(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).first.map(String.init) ?? Default.emoji
    }

    public var isDefault: Bool {
        theme == Default.theme && mode == Default.mode && density == Default.density && motion == Default.motion
            && menuBarBadge == Default.badge && showsPopoverCounters == Default.counters
            && startPage == Default.start && customAccent == Default.customAccent && menuBarIcon == Default.icon
            && menuBarEmoji == Default.emoji && backdrop == Default.backdrop && celebrations == Default.celebrations
            && sound == Default.sound && officeStyle == Default.officeStyle
            && officeEnvironment == Default.officeEnvironment && officeTimeOfDay == Default.officeTimeOfDay
            && officeBubbles == Default.officeBubbles && officeStreetLife == Default.officeStreetLife
            && officeSlowTurn == Default.officeSlowTurn && officeBoss == Default.officeBoss
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
        customAccent = Default.customAccent
        menuBarIcon = Default.icon
        menuBarEmoji = Default.emoji
        backdrop = Default.backdrop
        celebrations = Default.celebrations
        sound = Default.sound
        officeStyle = Default.officeStyle
        officeEnvironment = Default.officeEnvironment
        officeTimeOfDay = Default.officeTimeOfDay
        officeBubbles = Default.officeBubbles
        officeStreetLife = Default.officeStreetLife
        officeSlowTurn = Default.officeSlowTurn
        officeBoss = Default.officeBoss
        for key in Key.all { defaults.removeObject(forKey: key) }
    }

    private func store(_ value: String, _ key: String) { defaults.set(value, forKey: key) }
}
