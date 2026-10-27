# Plans Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Plans page in the Suica window that lists the plans found in folders the Owner picks, with step progress, an Owner-set status and a note per plan.

**Architecture:** All logic is Swift in `SuicaCore`: a parser (`PlanDocument.parse`), a folder scanner (`PlanScanner.scan`) and an `@Observable` `PlansModel` that keeps folders and marks in a `PreferenceStore` (the app's user defaults). The page in `Sources/Suica/Window` only renders the model. No Node command, config key or contract golden changes.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI/AppKit, Swift Testing (`@Suite`, `@Test`, `#expect`), `swift test` in `macos/Suica`.

**Spec:** `docs/superpowers/specs/2026-10-27-plans-page-design.md` (vocabulary: `CONTEXT.md`).

## Global Constraints

- Branch `feat/no-ticket-plans-page` in a sibling worktree (`git worktree add -b feat/no-ticket-plans-page ../suica-plans-page main`, `node_modules` symlinked from `../suica`, symlink unstaged); commit with `git -C <worktree>`. Never `--no-verify`; no push to `main`.
- English code, comments and copy. All user-visible strings live in `Sources/SuicaCore/Copy.swift` under `// MARK: - Plans`.
- Pure logic goes in `SuicaCore` with tests in `Tests/SuicaCoreTests`; views hold no logic worth testing.
- Test commands: `cd macos/Suica && swift test`; before the last commit also `npm run lint` and `npx prettier --check docs` from the repo root.
- Match the surrounding code: doc comments on public API, `public` on `SuicaCore` API, `@MainActor @Observable` models.

## Review Focus

1. **A `- [ ]` inside a code fence** (plans quote the checkbox template in a fence): not a step. Test in Task 1.
2. **CRLF line endings, or no trailing newline:** the plan parses the same as with LF. Test in Task 1.
3. **One unreadable, non-UTF-8 or huge (over 1 MB) `.md` file** among good ones: skipped, the others listed. Test in Task 2.
4. **A symlink loop, or two picked folders where one holds the other:** each plan listed once, scan terminates. Test in Task 2.
5. **A saved mark whose plan file is gone:** not listed, no crash, and it is back when the file returns. Test in Task 3.

---

### Task 1: Parse a plan file

**Files:**
- Create: `macos/Suica/Sources/SuicaCore/Plans.swift`
- Test: `macos/Suica/Tests/SuicaCoreTests/PlansTests.swift`

**Interfaces:**
- Produces (all `public`, `Sendable`):
  - `enum PlanStatus: String, CaseIterable, Identifiable, Codable { case planned, inProgress, inReview, done, dropped }` with `var id: String` and `var title: String` (from `Copy.planStatus(_:)`, Task 4).
  - `struct PlanTask: Equatable { let title: String; let done: Int; let total: Int }`.
  - `struct PlanDocument: Equatable, Identifiable { let path: String; let title: String; let goal: String?; let spec: String?; let date: String?; let tasks: [PlanTask]; let stepsDone: Int; let stepsTotal: Int }` with `var id: String { path }` and `var derivedStatus: PlanStatus`.
  - `static func PlanDocument.parse(path: String, text: String) -> PlanDocument?`

- [ ] **Step 1: Write the failing tests** in `PlansTests.swift` (`@Suite struct PlansTests`; fixtures are inline multi-line strings):
  - `parseReadsTitleGoalSpecDateAndSteps`: path `/p/plans/2026-10-26-review-lessons.md`, text with `# Review Lessons Implementation Plan`, the line `> **For agentic workers:** ...`, `**Goal:** Findings become lessons.`, ``**Spec:** `docs/superpowers/specs/x-design.md` (vocabulary)``, `### Task 1: Store` with one `- [x]` and one `- [ ]`, `### Task 2: Hook` with two `- [ ]`. Expect `title == "Review Lessons Implementation Plan"`, `goal == "Findings become lessons."`, `spec == "docs/superpowers/specs/x-design.md"`, `date == "2026-10-26"`, `tasks == [PlanTask(title: "Store", done: 1, total: 2), PlanTask(title: "Hook", done: 0, total: 2)]`, `stepsDone == 1`, `stepsTotal == 4`.
  - `parseRejectsAFileThatIsNotAPlan`: `/p/README.md` with `# Notes`, and `/p/plans/TRACKER.md` with `# Tracker`, both `nil`; a `/p/plans/2026-10-01-x.md` with no marker line is accepted (folder `plans` plus date prefix).
  - `parseDoesNotCountCheckboxesInsideACodeFence`: a plan whose Task 1 quotes a fenced block (three backticks) holding `- [ ] **Step 1**` and has one real `- [ ]` after it: `stepsTotal == 1`.
  - `parseHandlesCRLFAndNoTrailingNewline`: the first test's text joined with `\r\n` and trimmed of its last newline gives an equal document (same title, goal, steps).
  - `derivedStatusFollowsTheSteps`: 0 of 3 → `.planned`; 1 of 3 → `.inProgress`; 3 of 3 → `.done`; 0 of 0 → `.planned`.
  - `titleFallsBackToTheFileName`: marker line but no `# ` heading, path `/p/a-plan.md` → title `a-plan`.

- [ ] **Step 2: Run** `cd macos/Suica && swift test --filter PlansTests`. Expected: compile failure (`PlanDocument` not defined).

- [ ] **Step 3: Implement** the types above in `Plans.swift`. Rules: split text on `\r\n`, `\n`, `\r`; the plan marker is `For agentic workers` in the first 12 lines, or (parent directory named `plans` and file name starting with `YYYY-MM-DD-`); title is the first `# ` line, trimmed; goal is the rest of the line after `**Goal:**`; spec is the first backtick span on the line starting `**Spec:**` or `Spec:`; date is the file name's `YYYY-MM-DD` prefix; track fence state by lines whose trimmed text starts with three backticks and ignore every line inside one; a step is a trimmed line starting `- [ ]`, `- [x]` or `- [X]`; a task starts at `### Task N: title` (title without `Task N: `), steps before the first task count only in the totals. `derivedStatus` as in the test.

- [ ] **Step 4: Run** the filter again. Expected: all `PlansTests` pass.

- [ ] **Step 5: Commit**

```bash
git -C ../suica-plans-page add macos/Suica/Sources/SuicaCore/Plans.swift macos/Suica/Tests/SuicaCoreTests/PlansTests.swift docs/superpowers/specs/2026-10-27-plans-page-design.md docs/superpowers/plans/2026-10-27-plans-page.md
git -C ../suica-plans-page commit -m "feat(plans): parse a plan file into steps and tasks"
```

### Task 2: Scan folders for plans

**Files:**
- Modify: `macos/Suica/Sources/SuicaCore/Plans.swift`
- Test: `macos/Suica/Tests/SuicaCoreTests/PlansTests.swift`

**Interfaces:**
- Consumes: `PlanDocument.parse(path:text:)`, `Folders.expand(_:home:)` (`Folders.swift`).
- Produces: `public enum PlanScanner { public static func scan(folders: [String], home: String = NSHomeDirectory()) -> [PlanDocument] }`: newest `date` first (no date last), ties by path; each absolute path once.

- [ ] **Step 1: Write the failing tests** (a helper creates a temp folder tree under `FileManager.default.temporaryDirectory/UUID` and removes it in `defer`):
  - `scanFindsPlansRecursivelyNewestFirst`: `a/docs/superpowers/plans/2026-10-14-one.md` and `a/docs/superpowers/plans/2026-10-26-two.md` (each with the marker line), `a/README.md`, `a/plans/TRACKER.md` → `scan(folders: [root])` titles in order two, one.
  - `scanSkipsHiddenNodeModulesAndBuildFolders`: a plan inside `.claude/worktrees/x/`, `node_modules/y/` and `.build/z/` is not returned.
  - `scanListsAFileOnceWhenFoldersOverlap`: `scan(folders: [root, root + "/a"])` returns each plan once. Also a symlink `a/loop` pointing at `root` does not hang or duplicate.
  - `scanSkipsUnreadableNonUTF8AndHugeFiles`: a plan with bytes `0xFF 0xFE` only, one over 1 MB, and one chmod `000` file, next to a good plan → only the good plan.
  - `scanExpandsATildeAndIgnoresAMissingFolder`: `home` is the temp root, `scan(folders: ["~/a", "/nonexistent"], home: root)` finds the plans of `a`.

- [ ] **Step 2: Run** `swift test --filter PlansTests`. Expected: FAIL, `PlanScanner` not defined.

- [ ] **Step 3: Implement `PlanScanner.scan`** with `FileManager.enumerator(at:includingPropertiesForKeys:options: [.skipsHiddenFiles])` (does not follow symlinks), `skipDescendants()` for directories named `node_modules` or `.build`, only `.md` regular files up to 1 MB, `String(contentsOf:encoding: .utf8)` failures skipped, dedupe by standardized path (`URL.standardizedFileURL.resolvingSymlinksInPath().path`).

- [ ] **Step 4: Run** the filter. Expected: PASS.

- [ ] **Step 5: Commit** `feat(plans): scan folders for plans`.

### Task 3: Marks and the Plans model

**Files:**
- Modify: `macos/Suica/Sources/SuicaCore/Plans.swift`
- Test: `macos/Suica/Tests/SuicaCoreTests/PlansTests.swift`

**Interfaces:**
- Consumes: `PlanScanner.scan`, `PreferenceStore` (`Appearance.swift`), `Folders.adding(_:to:home:)`, `Folders.tidy`.
- Produces (`public`): `struct PlanMark: Equatable, Codable, Sendable { var status: PlanStatus?; var note: String }` and
  `@MainActor @Observable final class PlansModel` with
  - `init(store: any PreferenceStore, home: String = NSHomeDirectory(), scan: @escaping @Sendable ([String]) -> [PlanDocument] = { PlanScanner.scan(folders: $0) })`
  - `private(set) var folders: [String]`, `private(set) var plans: [PlanDocument]`, `private(set) var isScanning: Bool`
  - `var query: String`, `var filter: PlanStatus?`
  - `func refresh() async`, `func addFolders(_ chosen: [String])`, `func removeFolder(_ path: String)`
  - `func status(of plan: PlanDocument) -> PlanStatus` (set status, else derived), `func hasSetStatus(_ plan: PlanDocument) -> Bool`, `func note(for plan: PlanDocument) -> String`
  - `func setStatus(_ status: PlanStatus?, for plan: PlanDocument)` (nil resets), `func setNote(_ note: String, for plan: PlanDocument)` (trimmed; empty removes the note; a mark with no status and no note is removed)
  - `var visible: [PlanDocument]` (filtered by `filter`, then by `query` over title, goal, note and file name, case-insensitive) and `var counts: [PlanStatus: Int]` over all plans, ignoring `filter` and `query`.
  - Storage keys `"plans.folders"` (`[String]` via `set(_:forKey:)`) and `"plans.marks"` (JSON `String` of `[String: PlanMark]`, keyed by `plan.path`).

- [ ] **Step 1: Write the failing tests** with a private in-memory `MemoryStore: PreferenceStore` copied from `AppearanceTests.swift` (it is private there) and a stub scan returning fixed `PlanDocument`s:
  - `refreshListsThePlansOfTheFolders`: after `addFolders(["~/a"])` and `await refresh()`, `plans` equals the stub's list and `isScanning == false`.
  - `addFoldersKeepsEachFolderOnceAndPersists`: adding `["/x/", "/x"]` leaves one folder; a second `PlansModel` on the same store sees it; `removeFolder` removes it.
  - `aSetStatusBeatsTheDerivedOneAndResetBringsItBack`: a plan 0 of 3 is `.planned`; `setStatus(.inReview, …)` → `.inReview`, `hasSetStatus == true`; `setStatus(nil, …)` → `.planned`.
  - `marksSurviveARestartAndAnOrphanComesBack`: set status and note, make a new model on the same store with a scan that omits the plan (not listed, no crash), then one that returns it (status and note present again).
  - `anEmptyNoteWithNoStatusRemovesTheMark`: after `setNote("  ", …)` the stored `plans.marks` JSON decodes to `[:]`.
  - `visibleFiltersByStatusAndSearchesTitleGoalAndNote`: three plans; `filter = .done` leaves the done one; `query = "TIMEOUT"` finds the plan whose note says "timeout"; both together intersect; `counts` is unaffected by either.
  - `corruptStoredMarksAreIgnored`: store holds `"plans.marks" = "not json"` → model starts with no marks.

- [ ] **Step 2: Run** `swift test --filter PlansTests`. Expected: FAIL, `PlansModel` not defined.

- [ ] **Step 3: Implement** `PlanMark` and `PlansModel`. `refresh()` sets `isScanning`, runs `scan` in `Task.detached` with the folders (the closure is `@Sendable`), and assigns `plans` back on the main actor; a refresh with no folders sets `plans = []` without scanning.

- [ ] **Step 4: Run** the filter. Expected: PASS.

- [ ] **Step 5: Commit** `feat(plans): keep plan folders, statuses and notes`.

### Task 4: Copy

**Files:**
- Modify: `macos/Suica/Sources/SuicaCore/Copy.swift` (append `// MARK: - Plans` after the Lessons block)
- Test: `macos/Suica/Tests/SuicaCoreTests/PlansTests.swift`

**Interfaces:**
- Produces on `Copy` (`public static`): `plans = "Plans"`, `searchPlans = "Search plans"`, `func planStatus(_ status: PlanStatus) -> String` (Planned, In progress, In review, Done, Dropped), `func planSteps(done: Int, total: Int) -> String` (`"3 of 12 steps"`, `"1 step"`, `"No steps"`), `plansFolders = "Plan folders"`, `addPlanFolder = "Add folder"`, `noPlanFoldersTitle = "No plan folders yet"`, `noPlanFoldersHint = "Pick a folder that holds your repos or a docs/superpowers/plans folder."`, `noPlansTitle = "No plans found"`, `noPlansHint = "Plans written with the writing-plans skill show here."`, `noPlansMatch = "No plans match."`, `planStatusLabel = "Status"`, `planStatusAuto = "Follows the steps"`, `planNotePrompt = "Where it stands"`, `openPlan = "Open plan"`, `planSpec = "Spec"`, `planTasks = "Tasks"`, `rescanPlans = "Rescan"`.

- [ ] **Step 1: Write the failing test** `copyNamesEveryStatusAndPluralisesSteps`: every `PlanStatus.allCases` has a non-empty distinct `title`; `Copy.planSteps(done: 3, total: 12) == "3 of 12 steps"`, `(0, 1) == "0 of 1 step"`, `(0, 0) == "No steps"`.
- [ ] **Step 2: Run** `swift test --filter PlansTests`. Expected: FAIL (missing members).
- [ ] **Step 3: Add the strings** exactly as listed; `PlanStatus.title` returns `Copy.planStatus(self)`.
- [ ] **Step 4: Run** `swift test` (whole package). Expected: PASS, about 200 tests.
- [ ] **Step 5: Commit** `feat(plans): copy for the Plans page`.

### Task 5: The page, navigation and wiring

**Files:**
- Create: `macos/Suica/Sources/Suica/Window/PlansView.swift`
- Modify: `macos/Suica/Sources/Suica/Navigation.swift` (`WindowSection`, `SidebarNode.groups`), `macos/Suica/Sources/Suica/Window/MainWindow.swift` (property, page switch), `macos/Suica/Sources/Suica/SuicaApp.swift` (state and pass-through)
- Modify: `README.md` (a short "Plans" section), `CONTEXT.md` (term **Plan Mark**)

**Interfaces:**
- Consumes: `PlansModel` (Task 3), `Copy` plans strings (Task 4), `Folders`, `inlineCode`/`DisplayText` helpers already in `Sources/Suica`, `Copy.showInFinder`, `Copy.addFoldersPrompt`.
- Produces: `struct PlansView: View { let model: PlansModel }`; `WindowSection.plans` (title `Copy.plans`, symbol `list.bullet.clipboard`, tint `.teal`, shortcut ⇧⌘P set the way `.lessons` sets ⇧⌘L, listed in Insights right after Lessons); `MainWindow.plans: PlansModel`.

- [ ] **Step 1: Add `case plans`** to `WindowSection` at the end of the enum (so existing ⌘-digit shortcuts keep their index), with title, symbol, tint and the ⇧⌘P branch in `shortcut`; add `SidebarNode(.plans)` after `SidebarNode(.lessons)` in the Insights group.

- [ ] **Step 2: Wire the model.** In `SuicaApp`, `@State private var plans = PlansModel(store: UserDefaults.standard)`; pass `plans: plans` to `MainWindow`; in `MainWindow` add `let plans: PlansModel` and `case .plans: PlansView(model: plans)`.

- [ ] **Step 3: Build `PlansView`**: a list/detail split in the style of `LessonsSplit` (`LessonsView.swift`):
  - Toolbar: `.searchable(text: $model.query, prompt: Copy.searchPlans)`, a Rescan button, an Add folder button that runs an `NSOpenPanel` (directories only, multiple, prompt `Copy.addFoldersPrompt`) and calls `model.addFolders(panel.urls.map(\.path))`; a menu listing `model.folders` with a remove action each.
  - Above the list: one chip per `PlanStatus` showing `model.counts[status]`, toggling `model.filter`.
  - Row: title, date, goal (one line), a `ProgressView(value:total:)` of steps with `Copy.planSteps`, and a status pill (tinted; italic when `!hasSetStatus`).
  - Detail: status `Picker` with a first entry `Copy.planStatusAuto` (calls `setStatus(nil, …)`), the note `TextField` (`Copy.planNotePrompt`, commits on submit and on focus loss), the goal, the spec path, the tasks with their `Copy.planSteps`, and buttons Open plan (`NSWorkspace.shared.open`) and Show in Finder.
  - Empty states: no folders → `Copy.noPlanFoldersTitle`/`Hint` with the Add folder button; folders but no plans → `Copy.noPlansTitle`/`Hint`; filter or search with no result → `Copy.noPlansMatch`.
  - `.task { await model.refresh() }` on appear and after `addFolders`/`removeFolder`.

- [ ] **Step 4: Verify it builds and the package tests pass.** Run `cd macos/Suica && swift build && swift test`. Expected: build succeeds, all tests pass.

- [ ] **Step 5: Look at it.** Render `PlansView` in the scratch `NSHostingView` harness (see the `suica-ui-screenshot-harness` memory) with a model over a temp folder holding this repo's `docs/superpowers/plans`; check list, detail, the three empty states, and light and dark. Install the script that shows the user the page if asked. Expected: ten plans listed newest first, this plan In progress/Planned, no clipped text at a 760 pt window width.

- [ ] **Step 6: Docs and checks.** Add the README section (what is a plan, where folders are kept, how status works, ⇧⌘P) and the `CONTEXT.md` term **Plan Mark** (an Owner-set status and note on a plan, kept in the app, never in the plan file). Run `npm run lint` and `npx prettier --check docs README.md CONTEXT.md` from the repo root. Expected: clean.

- [ ] **Step 7: Commit** `feat(app): a Plans page that tracks plans`.
