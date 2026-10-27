import Foundation
import Testing

@testable import SuicaCore

private let fence = "```"

private let lessonsPlan = """
    # Review Lessons Implementation Plan

    > **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

    **Goal:** Findings become lessons.

    **Spec:** `docs/superpowers/specs/x-design.md` (vocabulary)

    ### Task 1: Store

    - [x] **Step 1: test**
    - [ ] **Step 2: code**

    ### Task 2: Hook

    - [ ] **Step 1: test**
    - [ ] **Step 2: code**

    """

@Suite struct PlansTests {
    @Test func parseReadsTitleGoalSpecDateAndSteps() throws {
        let plan = try #require(
            PlanDocument.parse(path: "/p/plans/2026-10-26-review-lessons.md", text: lessonsPlan))
        #expect(plan.title == "Review Lessons Implementation Plan")
        #expect(plan.goal == "Findings become lessons.")
        #expect(plan.spec == "docs/superpowers/specs/x-design.md")
        #expect(plan.date == "2026-10-26")
        #expect(
            plan.tasks == [
                PlanTask(title: "Store", done: 1, total: 2), PlanTask(title: "Hook", done: 0, total: 2),
            ])
        #expect(plan.stepsDone == 1)
        #expect(plan.stepsTotal == 4)
    }

    @Test func parseRejectsAFileThatIsNotAPlan() {
        #expect(PlanDocument.parse(path: "/p/README.md", text: "# Notes\n") == nil)
        #expect(PlanDocument.parse(path: "/p/plans/TRACKER.md", text: "# Tracker\n") == nil)
        #expect(PlanDocument.parse(path: "/p/plans/2026-10-01-x.md", text: "# X\n") != nil)
    }

    @Test func parseDoesNotCountCheckboxesInsideACodeFence() throws {
        let text = """
            # P
            > **For agentic workers:** go
            ### Task 1: A
            \(fence)markdown
            - [ ] **Step 1: quoted template**
            \(fence)
            - [ ] **Step 1: real**
            """
        let plan = try #require(PlanDocument.parse(path: "/p/a.md", text: text))
        #expect(plan.stepsTotal == 1)
    }

    @Test func parseHandlesCRLFAndNoTrailingNewline() throws {
        let crlf = lessonsPlan.split(separator: "\n", omittingEmptySubsequences: false).joined(separator: "\r\n")
        let plan = try #require(PlanDocument.parse(path: "/p/plans/2026-10-26-review-lessons.md", text: crlf))
        let lf = try #require(PlanDocument.parse(path: "/p/plans/2026-10-26-review-lessons.md", text: lessonsPlan))
        #expect(plan == lf)
        let bare = try #require(
            PlanDocument.parse(path: "/p/plans/2026-10-26-review-lessons.md", text: String(lessonsPlan.dropLast())))
        #expect(bare == lf)
    }

    @Test func derivedStatusFollowsTheSteps() throws {
        func status(_ steps: String) throws -> PlanStatus {
            try #require(PlanDocument.parse(path: "/p/a.md", text: "# P\n> **For agentic workers:** x\n" + steps))
                .derivedStatus
        }
        #expect(try status("- [ ] a\n- [ ] b\n- [ ] c\n") == .planned)
        #expect(try status("- [x] a\n- [ ] b\n- [ ] c\n") == .inProgress)
        #expect(try status("- [x] a\n- [X] b\n- [x] c\n") == .done)
        #expect(try status("") == .planned)
    }

    @Test func titleFallsBackToTheFileName() throws {
        let plan = try #require(PlanDocument.parse(path: "/p/a-plan.md", text: "> **For agentic workers:** x\n"))
        #expect(plan.title == "a-plan")
    }
}

private let marker = "# T\n> **For agentic workers:** x\n"

/// A temp folder tree: `files` maps a relative path to its text.
private func tree(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).standardizedFileURL
    for (name, text) in files {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    return root
}

@Suite struct PlanScannerTests {
    @Test func scanFindsPlansRecursivelyNewestFirst() throws {
        let root = try tree([
            "a/docs/superpowers/plans/2026-10-14-one.md": marker.replacingOccurrences(of: "# T", with: "# One"),
            "a/docs/superpowers/plans/2026-10-26-two.md": marker.replacingOccurrences(of: "# T", with: "# Two"),
            "a/README.md": "# Readme\n", "a/plans/TRACKER.md": "# Tracker\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(PlanScanner.scan(folders: [root.path]).map(\.title) == ["Two", "One"])
    }

    @Test func scanSkipsHiddenNodeModulesAndBuildFolders() throws {
        let root = try tree([
            ".claude/worktrees/x/a.md": marker, "node_modules/y/b.md": marker, ".build/z/c.md": marker,
            "ok/d.md": marker,
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(PlanScanner.scan(folders: [root.path]).map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["d.md"])
    }

    @Test func scanListsAFileOnceWhenFoldersOverlapAndSurvivesASymlinkLoop() throws {
        let root = try tree(["a/p.md": marker])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("a/loop"), withDestinationURL: root)
        #expect(PlanScanner.scan(folders: [root.path, root.path + "/a"]).count == 1)
    }

    @Test func scanSkipsUnreadableNonUTF8AndHugeFiles() throws {
        let root = try tree(["good.md": marker, "huge.md": marker + String(repeating: "x", count: 1_100_000)])
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0xFF, 0xFE]).write(to: root.appendingPathComponent("bad.md"))
        let locked = root.appendingPathComponent("locked.md")
        try marker.write(to: locked, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        #expect(PlanScanner.scan(folders: [root.path]).map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["good.md"])
    }

    @Test func scanExpandsATildeAndIgnoresAMissingFolder() throws {
        let root = try tree(["a/p.md": marker])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(PlanScanner.scan(folders: ["~/a", "/nonexistent-suica"], home: root.path).count == 1)
    }
}
