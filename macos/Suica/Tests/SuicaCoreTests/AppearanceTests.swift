import Foundation
import Testing

@testable import SuicaCore

/// Preferences in memory, so tests never touch the app's real settings or leave files behind.
private final class MemoryStore: PreferenceStore {
    var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { values[key] as? String }
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
}

@MainActor private func withFreshStore(_ body: (MemoryStore) -> Void) { body(MemoryStore()) }

@MainActor @Test func appearanceStartsFromTheDefaults() {
    withFreshStore { defaults in
        let settings = AppearanceSettings(defaults: defaults)
        #expect(settings.theme == .glacier)
        #expect(settings.mode == .system)
        #expect(settings.density == .comfortable)
        #expect(settings.motion == .full)
        #expect(settings.menuBarBadge == .count)
        #expect(settings.showsPopoverCounters)
        #expect(settings.startPage == .overview)
        #expect(settings.menuBarIcon == .penguin && settings.menuBarEmoji == "🍉")
        #expect(settings.backdrop == .wash && settings.celebrations && settings.sound == .off)
        #expect(settings.officeStyle == .modern && settings.officeEnvironment == .city)
        #expect(settings.isDefault)
    }
}

@MainActor @Test func appearanceChoicesSurviveARestart() {
    withFreshStore { defaults in
        let first = AppearanceSettings(defaults: defaults)
        first.theme = .watermelon
        first.mode = .dark
        first.density = .compact
        first.motion = .off
        first.menuBarBadge = .dot
        first.showsPopoverCounters = false
        first.startPage = .messages
        first.officeStyle = .brick
        first.officeEnvironment = .snow

        let second = AppearanceSettings(defaults: defaults)
        #expect(second.theme == .watermelon)
        #expect(second.mode == .dark)
        #expect(second.density == .compact)
        #expect(second.motion == .off)
        #expect(second.menuBarBadge == .dot)
        #expect(!second.showsPopoverCounters)
        #expect(second.startPage == .messages)
        #expect(second.officeStyle == .brick && second.officeEnvironment == .snow)
        #expect(!second.isDefault)
    }
}

@MainActor @Test func anUnknownStoredValueFallsBackToTheDefault() {
    withFreshStore { defaults in
        defaults.set("neon", forKey: "appearance.theme")
        defaults.set("sideways", forKey: "appearance.motion")
        defaults.set("castle", forKey: "appearance.officeStyle")
        defaults.set("moon", forKey: "appearance.officeEnvironment")
        let settings = AppearanceSettings(defaults: defaults)
        #expect(settings.theme == .glacier)
        #expect(settings.motion == .full)
        #expect(settings.officeStyle == .modern && settings.officeEnvironment == .city)
    }
}

@MainActor @Test func restoringDefaultsResetsEveryChoiceAndForgetsTheStoredOnes() {
    withFreshStore { defaults in
        let settings = AppearanceSettings(defaults: defaults)
        settings.theme = .grape
        settings.showsPopoverCounters = false
        settings.startPage = .reviews
        settings.officeEnvironment = .park
        settings.reset()
        #expect(settings.isDefault)
        #expect(defaults.string(forKey: "appearance.theme") == nil)
        #expect(defaults.string(forKey: "appearance.officeEnvironment") == nil)
        #expect(defaults.object(forKey: "appearance.popoverCounters") == nil)
        #expect(AppearanceSettings(defaults: defaults).isDefault)
    }
}

@Test func reduceMotionCapsTheChosenLevelAtFades() {
    #expect(MotionLevel.full.effective(systemReduceMotion: false) == .full)
    #expect(MotionLevel.full.effective(systemReduceMotion: true) == .reduced)
    #expect(MotionLevel.reduced.effective(systemReduceMotion: true) == .reduced)
    // Off stays off: the system setting never adds motion.
    #expect(MotionLevel.off.effective(systemReduceMotion: true) == .off)
    #expect(MotionLevel.off.effective(systemReduceMotion: false) == .off)
}

@Test func theMenuBarBadgeShowsOnlyWhileSomethingNeedsYou() {
    #expect(MenuBarBadge.count.label(for: 3) == "3")
    #expect(MenuBarBadge.dot.label(for: 3) == "●")
    #expect(MenuBarBadge.hidden.label(for: 3) == nil)
    for badge in MenuBarBadge.allCases { #expect(badge.label(for: 0) == nil) }
}

@Test func everyThemeButSystemAndCustomHasItsOwnColour() {
    #expect(AccentTheme.system.hex == nil && AccentTheme.custom.hex == nil)
    let colours = AccentTheme.allCases.compactMap(\.hex)
    #expect(colours.count == AccentTheme.allCases.count - 2)
    #expect(Set(colours).count == colours.count)
    #expect(AccentTheme.allCases.allSatisfy { !$0.title.isEmpty })
}

@Test func aShortKeyKeepsTheProjectAndNumber() {
    #expect(DisplayText.shortKey("group/sub/project!12") == "project!12")
    #expect(DisplayText.shortKey("project!3") == "project!3")
    #expect(DisplayText.shortKey("a/b\u{202E}c!4") == DisplayText.clean("b\u{202E}c!4", max: 60))
}

@MainActor @Test func theNewChoicesSurviveARestartAndReset() {
    withFreshStore { defaults in
        let first = AppearanceSettings(defaults: defaults)
        first.theme = .custom
        first.customAccent = 0x123456
        first.menuBarIcon = .emoji
        first.menuBarEmoji = "  👩‍💻🐧 "
        first.backdrop = .aurora
        first.celebrations = false
        first.sound = .pop
        #expect(first.menuBarEmoji == "👩‍💻")
        #expect(first.accentHex == 0x123456)

        let second = AppearanceSettings(defaults: defaults)
        #expect(second.theme == .custom && second.customAccent == 0x123456 && second.accentHex == 0x123456)
        #expect(second.menuBarIcon == .emoji && second.menuBarEmoji == "👩‍💻")
        #expect(second.backdrop == .aurora && !second.celebrations && second.sound == .pop)
        second.reset()
        #expect(second.isDefault && AppearanceSettings(defaults: defaults).isDefault)
    }
}

@MainActor @Test func anEmptyEmojiFallsBackToTheWatermelon() {
    withFreshStore { defaults in
        let settings = AppearanceSettings(defaults: defaults)
        settings.menuBarEmoji = "   "
        #expect(settings.menuBarEmoji == "🍉")
    }
}

@MainActor @Test func presetsSetWhatTheyNameAndLeaveTheRest() {
    withFreshStore { defaults in
        let settings = AppearanceSettings(defaults: defaults)
        settings.startPage = .messages
        AppearancePreset.watermelonParty.apply(to: settings)
        #expect(settings.theme == .watermelon && settings.backdrop == .watermelon && settings.menuBarIcon == .watermelon)
        #expect(settings.celebrations && settings.sound == .pop && settings.startPage == .messages)
        AppearancePreset.zen.apply(to: settings)
        #expect(!settings.celebrations && settings.sound == .off && settings.motion == .reduced && settings.backdrop == .plain)
        #expect(AppearancePreset.allCases.allSatisfy { !Copy.title($0).isEmpty && !$0.emblem.isEmpty })
    }
}

@Test func inboxZeroIsTheBadgeGoingToNothing() {
    #expect(Celebration.onBadgeChange(from: 2, to: 0) == .inboxZero)
    #expect(Celebration.onBadgeChange(from: 0, to: 0) == nil)
    #expect(Celebration.onBadgeChange(from: 3, to: 1) == nil)
    #expect(Celebration.onBadgeChange(from: 0, to: 2) == nil)
}

@Test func soundsNameTheSystemSounds() {
    #expect(SoundEffect.off.systemName == nil)
    #expect(SoundEffect.submarine.systemName == "Submarine")
    for sound in SoundEffect.allCases {
        if let name = sound.systemName {
            #expect(FileManager.default.fileExists(atPath: "/System/Library/Sounds/\(name).aiff"), "\(name)")
        }
    }
}

@MainActor @Test func officeOptionsStartFromTheirDefaultsAreKeptAndReset() {
    withFreshStore { defaults in
        let settings = AppearanceSettings(defaults: defaults)
        #expect(settings.officeTimeOfDay == .system && settings.officeBubbles == .all)
        #expect(settings.officeStreetLife && !settings.officeSlowTurn && settings.officeBoss)
        settings.officeTimeOfDay = .night
        settings.officeBubbles = .selected
        settings.officeStreetLife = false
        settings.officeSlowTurn = true
        settings.officeBoss = false
        #expect(!settings.isDefault)
        let again = AppearanceSettings(defaults: defaults)
        #expect(again.officeTimeOfDay == .night && again.officeBubbles == .selected)
        #expect(!again.officeStreetLife && again.officeSlowTurn && !again.officeBoss)
        again.reset()
        #expect(again.isDefault && defaults.values.isEmpty)
    }
}

@MainActor @Test func anUnknownStoredTimeOfDayFallsBackToFollowingTheAppearance() {
    withFreshStore { defaults in
        defaults.set("dusk", forKey: "appearance.officeTimeOfDay")
        defaults.set("some", forKey: "appearance.officeBubbles")
        let settings = AppearanceSettings(defaults: defaults)
        #expect(settings.officeTimeOfDay == .system && settings.officeBubbles == .all)
    }
}

@Test func timeOfDayFollowsTheModeUnlessPinned() {
    #expect(OfficeTimeOfDay.system.isNight(darkMode: true) && !OfficeTimeOfDay.system.isNight(darkMode: false))
    #expect(!OfficeTimeOfDay.day.isNight(darkMode: true) && OfficeTimeOfDay.night.isNight(darkMode: false))
}

@Test func bubblesShowForEveryoneTheSelectedOrNobody() {
    #expect(OfficeBubbles.all.shows(selected: false) && OfficeBubbles.selected.shows(selected: true))
    #expect(!OfficeBubbles.selected.shows(selected: false) && !OfficeBubbles.off.shows(selected: true))
}
