import Foundation
import Testing

@testable import SuicaCore

@Test func claudeSkillImportAndDisablePreserveFilesAndRejectDuplicates() async throws {
    let files = FileManager.default
    let fixture = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? files.removeItem(at: fixture) }
    let config = fixture.appendingPathComponent("claude", isDirectory: true)
    let source = fixture.appendingPathComponent("sample-skill", isDirectory: true)
    try files.createDirectory(at: source, withIntermediateDirectories: true)
    let instructions = "---\nname: sample-skill\n---\nExample instructions.\n"
    try instructions.write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    try Data([1, 2]).write(to: source.appendingPathComponent("reference.txt"))

    let library = ClaudeSkillLibrary(configDirectory: config)
    #expect(try await library.list().isEmpty)
    let installed = try await library.importSkill(from: source)
    let personal = try #require(try await library.list().first)
    #expect(personal.id == installed && personal.source == .personal)
    #expect(try await library.preview(personal) == instructions)

    let disabled = try await library.toggle(personal)
    #expect(!files.fileExists(atPath: installed.path))
    #expect(try Data(contentsOf: disabled.appendingPathComponent("reference.txt")) == Data([1, 2]))
    await #expect(throws: ClaudeSkillLibrary.Failure.nameInUse) {
        try await library.importSkill(from: source)
    }

    let disabledSkill = try #require(try await library.list().first)
    #expect(disabledSkill.id == disabled && disabledSkill.source == .disabled)
    #expect(try await library.toggle(disabledSkill) == installed)
    #expect(try await library.list().map(\.source) == [.personal])
}

@Test func togglingLinkedClaudeSkillMovesOnlyTheLink() async throws {
    let files = FileManager.default
    let fixture = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? files.removeItem(at: fixture) }
    let config = fixture.appendingPathComponent("claude", isDirectory: true)
    let personal = config.appendingPathComponent("skills", isDirectory: true)
    let shared = fixture.appendingPathComponent("shared", isDirectory: true)
    try files.createDirectory(at: personal, withIntermediateDirectories: true)
    try files.createDirectory(at: shared, withIntermediateDirectories: true)
    let skillFile = shared.appendingPathComponent("SKILL.md")
    try "Shared".write(to: skillFile, atomically: true, encoding: .utf8)
    try files.createSymbolicLink(atPath: personal.appendingPathComponent("linked").path, withDestinationPath: "../../shared")

    let library = ClaudeSkillLibrary(configDirectory: config)
    let skill = try #require(try await library.list().first)
    let disabled = try await library.toggle(skill)
    #expect(try files.destinationOfSymbolicLink(atPath: disabled.path) == "../../shared")
    #expect(try String(contentsOf: skillFile, encoding: .utf8) == "Shared")
    let disabledSkill = try #require(try await library.list().first)
    #expect(try await library.preview(disabledSkill) == "Shared")
}
