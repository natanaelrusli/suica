import Testing

@testable import SuicaCore

@Test func aDurationIsShownInTheLargestWholeUnit() {
    #expect(DurationUnit.best(for: 120, base: .seconds) == .minutes)
    #expect(DurationUnit.best(for: 90, base: .seconds) == .seconds)
    #expect(DurationUnit.best(for: 7200, base: .seconds) == .hours)
    #expect(DurationUnit.best(for: 24, base: .hours) == .days)
    #expect(DurationUnit.best(for: 10, base: .minutes) == .minutes)
}

@Test func aDurationIsStoredInTheFieldsOwnUnit() {
    #expect(DurationUnit.minutes.converted(2, to: .seconds) == 120)
    #expect(DurationUnit.days.converted(1, to: .hours) == 24)
    #expect(DurationUnit.offered(for: .minutes) == [.minutes, .hours, .days])
    #expect(DurationUnit(fieldUnit: "seconds") == .seconds)
    // Units that are not lengths of time, and days the agent never stores, are not durations.
    #expect(DurationUnit(fieldUnit: "reviews") == nil && DurationUnit(fieldUnit: "days") == nil)
    #expect(DurationUnit(fieldUnit: nil) == nil)
}

@Test func aPastedURLKeepsOnlyItsHost() {
    #expect(ConfigInputs.host(from: "https://repo.example/group/project?x=1") == "repo.example")
    #expect(ConfigInputs.host(from: " repo.example ") == "repo.example")
    #expect(ConfigInputs.host(from: "gitlab.example.com:8443") == "gitlab.example.com:8443")
    #expect(ConfigInputs.host(from: "") == "")
}

@Test func clockTimesRoundTripThroughMinutes() {
    #expect(ConfigInputs.minutes(ofClock: "08:30") == 510)
    #expect(ConfigInputs.minutes(ofClock: "24:00") == nil)
    #expect(ConfigInputs.minutes(ofClock: "8:30") == nil)
    #expect(ConfigInputs.clock(fromMinutes: 510) == "08:30")
    #expect(ConfigInputs.clock(fromMinutes: 1439) == "23:59")
}

@Test func longCategoriesAreSplitIntoSections() {
    #expect(Copy.configSection(["teams", "modes", "nudge"]) == "Send modes")
    #expect(Copy.configSection(["teams", "workingHours", "start"]) == "Working hours")
    #expect(Copy.configSection(["review", "effort"]) == "Skill and model")
    #expect(Copy.configSection(["review", "concurrency"]) == "Limits")
    #expect(Copy.configSection(["gitlab", "hostname"]) == nil)
    #expect(Copy.configSection(["statePath"]) == nil)
}
