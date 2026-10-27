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
        let quoted = "# Readme\nFor agentic workers\n"
        #expect(PlanDocument.parse(path: "/p/README.md", text: quoted) == nil)
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

private final class MemoryStore: PreferenceStore {
    var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { values[key] as? String }
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
}

private func plan(_ name: String, done: Int = 0, total: Int = 3, goal: String? = nil) -> PlanDocument {
    PlanDocument(
        path: "/p/plans/\(name).md", title: name, goal: goal, spec: nil, date: nil,
        tasks: [], stepsDone: done, stepsTotal: total)
}

@MainActor @Suite struct PlansModelTests {
    @Test func refreshListsThePlansOfTheFolders() async {
        let stub = [plan("a")]
        let model = PlansModel(store: MemoryStore(), scan: { _ in stub })
        model.addFolders(["~/a"])
        await model.refresh()
        #expect(model.plans == stub)
        #expect(!model.isScanning)
    }

    @Test func addFoldersKeepsEachFolderOnceAndPersists() {
        let store = MemoryStore()
        let model = PlansModel(store: store, home: "/h", scan: { _ in [] })
        model.addFolders(["/x/", "/x"])
        #expect(model.folders == ["/x"])
        #expect(PlansModel(store: store, home: "/h", scan: { _ in [] }).folders == ["/x"])
        model.removeFolder("/x")
        #expect(model.folders.isEmpty)
    }

    @Test func aSetStatusBeatsTheDerivedOneAndResetBringsItBack() {
        let model = PlansModel(store: MemoryStore(), scan: { _ in [] })
        let p = plan("a")
        #expect(model.status(of: p) == .planned)
        model.setStatus(.inReview, for: p)
        #expect(model.status(of: p) == .inReview)
        #expect(model.hasSetStatus(p))
        model.setStatus(nil, for: p)
        #expect(model.status(of: p) == .planned)
    }

    @Test func marksSurviveARestartAndAnOrphanComesBack() async {
        let store = MemoryStore()
        let p = plan("a")
        let first = PlansModel(store: store, scan: { _ in [p] })
        first.addFolders(["/x"])
        first.setStatus(.dropped, for: p)
        first.setNote("  MR !42 open  ", for: p)
        let gone = PlansModel(store: store, scan: { _ in [] })
        await gone.refresh()
        #expect(gone.plans.isEmpty)
        let back = PlansModel(store: store, scan: { _ in [p] })
        await back.refresh()
        #expect(back.status(of: p) == .dropped)
        #expect(back.note(for: p) == "MR !42 open")
    }

    @Test func anEmptyNoteWithNoStatusRemovesTheMark() throws {
        let store = MemoryStore()
        let model = PlansModel(store: store, scan: { _ in [] })
        let p = plan("a")
        model.setNote("x", for: p)
        model.setNote("  ", for: p)
        let json = try #require(store.string(forKey: "plans.marks"))
        #expect(try JSONDecoder().decode([String: PlanMark].self, from: Data(json.utf8)).isEmpty)
    }

    @Test func visibleFiltersByStatusAndSearchesTitleGoalAndNote() async {
        let list = [plan("one", done: 3), plan("three", goal: "Add HTTP client"), plan("sixsix")]
        let model = PlansModel(store: MemoryStore(), scan: { _ in list })
        model.addFolders(["/x"])
        await model.refresh()
        model.setNote("blocked on timeout", for: list[2])
        model.filter = .done
        #expect(model.visible == [list[0]])
        model.filter = nil
        model.query = "TIMEOUT"
        #expect(model.visible == [list[2]])
        model.query = "http"
        #expect(model.visible == [list[1]])
        model.filter = .planned
        model.query = "one"
        #expect(model.visible.isEmpty)
        #expect(model.counts == [.done: 1, .planned: 2])
    }

    @Test func anOlderSlowScanNeverOverwritesANewerOne() async {
        let a = plan("a"), b = plan("b")
        let model = PlansModel(
            store: MemoryStore(),
            scan: { folders in
                if folders.count == 2 { Thread.sleep(forTimeInterval: 0.3) }
                return folders.count == 2 ? [a, b] : [a]
            })
        model.addFolders(["/a", "/b"])
        let slow = Task { await model.refresh() }
        try? await Task.sleep(for: .milliseconds(50))
        model.removeFolder("/b")
        await model.refresh()
        await slow.value
        #expect(model.plans == [a])
        #expect(!model.isScanning)
    }

    @Test func corruptStoredMarksAreIgnored() {
        let store = MemoryStore()
        store.set("not json", forKey: "plans.marks")
        let model = PlansModel(store: store, scan: { _ in [] })
        #expect(!model.hasSetStatus(plan("a")))
    }
}

@Test func copyNamesEveryStatusAndPluralisesSteps() {
    let titles = PlanStatus.allCases.map(\.title)
    #expect(titles.allSatisfy { !$0.isEmpty } && Set(titles).count == titles.count)
    #expect(Copy.planSteps(done: 3, total: 12) == "3 of 12 steps")
    #expect(Copy.planSteps(done: 0, total: 1) == "0 of 1 step")
    #expect(Copy.planSteps(done: 0, total: 0) == "No steps")
}
