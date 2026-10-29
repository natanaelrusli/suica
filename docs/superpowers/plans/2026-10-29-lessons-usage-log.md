# Lessons Usage Log Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Log every time the Claude Code hook or the `suica-lessons` MCP server hands Lessons to a Coding Agent, and show per project what it got and the estimated tokens, through `suica lessons usage --json` and a Usage view on the app's Lessons page.

**Architecture:** A new `src/lessons/usage.ts` owns the entry type, a day-split JSONL file log under `<stateDir>/lessons-usage/` (append, prune, read; every failure swallowed, like `fileSeenStore`) and a pure aggregator. The hook and the MCP server get a `usage: UsageLog` dependency and append one entry per non-empty answer. The CLI aggregates the last 30 days with Lesson titles from the read-only reader; the Swift app decodes it into a third Lessons view.

**Tech Stack:** Node 24 TypeScript (no build step, `node:fs`), vitest; Swift 6 / SwiftUI with swift-testing.

**Spec:** `docs/superpowers/specs/2026-10-29-lessons-usage-log-design.md`

## Global Constraints

- Work in the worktree `/Users/anb-0826009/project/suica-lessons-usage` on branch `feat/no-ticket-lessons-usage` (already created, `node_modules` symlinked; leave the symlink unstaged). Commit with `git -C /Users/anb-0826009/project/suica-lessons-usage …`, never on `main`.
- The hook must never throw, block or slow a Read/Edit: a log failure is swallowed and the Lessons are still answered.
- Never open the state database read-write from the hook or the MCP server; the log is files only.
- Log folder `<stateDir>/lessons-usage/`, mode `0o700`; day files `YYYY-MM-DD.jsonl` (UTC day of `at`), mode `0o600`.
- Retention fixed at 30 days (`USAGE_DAYS = 30`), no config row.
- Tokens are `Math.ceil(text.length / 4)` of the exact text handed over, and are called "estimated" in the document's README text and the app copy.
- A line holds ids, counts and paths only, never Lesson text or finding text.
- Nothing is logged for an empty hook answer or an MCP reply of `No lessons apply here.` / a failure.
- Keep README, `contracts/lessons.v1.json` and the Swift decoders in the same change (repo convention). All text in English.
- Tests: `npx vitest run <file>`; full `npm test`; lint `npm run lint`; Swift `cd macos/Suica && swift test`. A CLI-spawning test that times out under a full parallel run is a known flake: rerun before blaming the change.

## Review Focus

1. A session started in a scope folder that is not inside any repo → the entry has `project: null` and the report groups it under its scope folder, not dropped and not mixed with a repo. (Task 2 test, Task 4 test.)
2. A day file with a truncated or hand-edited line → that line is skipped, every other entry is still read. (Task 1 test.)
3. The state folder cannot be written (a file sits where the log folder should be) → the hook still answers with its Lessons and nothing throws. (Task 2 test.)
4. MCP `get_lesson` for an archived or other-scope Lesson, or any reply equal to `No lessons apply here.` → no entry. (Task 3 test.)
5. A `session_id` that fails `SESSION_ID` (e.g. `"../x"`) → the entry is still logged, without `sessionId`, and the report does not count it as a session. (Task 2 test.)

---

### Task 1: Usage log store

**Files:**
- Create: `src/lessons/usage.ts`
- Test: `test/lesson-usage.test.ts`

**Interfaces:**
- Produces (exported from `src/lessons/usage.ts`):
  ```ts
  export type UsageSource = "session" | "read" | "edit" | "mcp";
  export interface UsageEntry {
    readonly at: number;
    readonly project: string | null;
    readonly scope: string;
    readonly source: UsageSource;
    readonly tool?: string;       // mcp only
    readonly sessionId?: string;  // hook only, when it matches SESSION_ID
    readonly file?: string;       // repo-relative
    readonly lessonIds: readonly number[];
    readonly tokens: number;
  }
  export interface UsageLog { append(entry: UsageEntry): void }
  export const USAGE_DAYS = 30;
  export function estimateTokens(text: string): number;
  export function fileUsageLog(dir: string, now: number): UsageLog;
  export function readUsage(dir: string, since: number): UsageEntry[];
  ```
- `usage.ts` does not import `hook.ts`; it writes the entry it is given (the hook decides whether `sessionId` is set, with its existing `SESSION_ID`).

- [ ] **Step 1: Write the failing tests** in `test/lesson-usage.test.ts` (temp dir per test via `mkdtempSync(join(tmpdir(), "suica-usage-"))`, removed in `afterEach`):
  - `estimateTokens`: `estimateTokens("") === 0`, `estimateTokens("abcd") === 1`, `estimateTokens("abcde") === 2`.
  - `appends one line per entry to the UTC day file`: append two entries with `at = Date.UTC(2026, 9, 29, 23, 30)` and `Date.UTC(2026, 9, 30, 0, 30)` into `join(tmp, "lessons-usage")`; expect files `2026-10-29.jsonl` and `2026-10-30.jsonl`, each one line; `statSync(file).mode & 0o777 === 0o600`, folder `0o700`; `readUsage(dir, 0)` deep-equals both entries, oldest first.
  - `skips malformed lines`: write a file with a valid line, `{"at":1,` and `null` and a line missing `lessonIds`; `readUsage` returns only the valid entry.
  - `drops entries before since`: entries at `NOW - 31 * DAY` and `NOW - DAY` in the same file; `readUsage(dir, NOW - 30 * DAY)` returns only the second.
  - `prunes day files older than USAGE_DAYS on open`: create `2026-09-01.jsonl` and `2026-10-28.jsonl` and an unrelated `notes.txt`; `fileUsageLog(dir, Date.UTC(2026, 9, 29))` removes only `2026-09-01.jsonl` (prune by the date in the name, not mtime).
  - `never throws`: `writeFileSync(join(tmp, "lessons-usage"), "")` (a file where the folder goes); `fileUsageLog(...)` and `.append(entry)` do not throw; `readUsage` on it returns `[]`; `readUsage` on a missing folder returns `[]`.

- [ ] **Step 2: Run to verify they fail**

  Run: `npx vitest run test/lesson-usage.test.ts`
  Expected: FAIL, cannot resolve `../src/lessons/usage.ts`.

- [ ] **Step 3: Implement `src/lessons/usage.ts`.** `fileUsageLog` prunes on open (names matching `/^\d{4}-\d{2}-\d{2}\.jsonl$/` whose day is before `now - USAGE_DAYS * 86_400_000`), then `append` does `mkdirSync(dir, { recursive: true, mode: 0o700 })` and `appendFileSync(path, JSON.stringify(entry) + "\n", { mode: 0o600 })` inside try/catch. `readUsage` validates each parsed line field by field (types as in `UsageEntry`, `source` one of the four, `lessonIds` all integers) and drops anything else; only reads files whose day is not before `since`'s day, then filters by `at >= since`; sorts by `at`. Header comment in the style of `hook.ts`: why files and not the database.

- [ ] **Step 4: Run to verify they pass**

  Run: `npx vitest run test/lesson-usage.test.ts`
  Expected: PASS.

- [ ] **Step 5: Commit**

  ```bash
  git -C /Users/anb-0826009/project/suica-lessons-usage add src/lessons/usage.ts test/lesson-usage.test.ts docs/superpowers
  git -C /Users/anb-0826009/project/suica-lessons-usage commit -m "feat(lessons): a file log of lessons handed to agents"
  ```

---

### Task 2: The hook logs what it hands over

**Files:**
- Modify: `src/lessons/hook.ts` (`HookDeps`, `Target`, `target()`, `answer()`)
- Modify: `src/lessons-hook.ts` (wire `fileUsageLog`)
- Test: `test/lesson-hook.test.ts`

**Interfaces:**
- Consumes: `UsageLog`, `UsageEntry`, `estimateTokens` from Task 1.
- Produces: `HookDeps` gains `readonly usage: UsageLog`. `Target` gains `readonly repo?: ScopedRepo` (set for a session start inside a repo, always set for a file event).

- [ ] **Step 1: Write the failing tests.** Add `function memoryUsage(): UsageLog & { readonly entries: UsageEntry[] }` beside `memorySeen()` and give `deps()` a default `usage: memoryUsage()`. New tests in the existing `describe`:
  - `logs a session start with its project, lessons and tokens`: `const usage = memoryUsage(); const out = answerHook(start(repo), deps({ usage }));` expect `usage.entries` to equal `[{ at: NOW, project: "g/app", scope, source: "session", sessionId: "s1", lessonIds: [go, ts, fresh] (in the order shown), tokens: estimateTokens(JSON.parse(out).hookSpecificOutput.additionalContext) }]`.
  - `logs a read and an edit with the repo-relative file`: `read(join(repo, "src/a.go"))` → `source: "read", file: "src/a.go", lessonIds: [go]`; a `PreToolUse` `Edit` on `src/b.ts` → `source: "edit", file: "src/b.ts"`.
  - `logs nothing when nothing is shown`: the same read twice in one session → one entry; a read of a file outside any repo → none.
  - Review Focus 1: `a session outside any repo logs project null`: `mkdirSync(join(scope, "notes"))`, `start(join(scope, "notes"))` → one entry with `project: null, scope`.
  - Review Focus 5: `a session id that is not a file name is logged without it`: `start(repo, { session_id: "../x" })` → entry has no `sessionId` key.
  - Review Focus 3: `still answers when the log cannot be written`: `writeFileSync(join(dir, "lessons-usage"), "")`, `deps({ usage: fileUsageLog(join(dir, "lessons-usage"), NOW) })`; `answerHook(start(repo), …)` still contains `SESSION_INTRO`. Also `deps({ usage: { append: () => { throw new Error("x"); } } })` still answers.

- [ ] **Step 2: Run to verify they fail**

  Run: `npx vitest run test/lesson-hook.test.ts`
  Expected: the new tests FAIL (no entries); the old ones still pass.

- [ ] **Step 3: Implement.** In `target()` keep `found.repo` for a session start and `repo` for a file event. In `answer()`, after the `seen.add` try block and once the `additionalContext` string is built, append in its own try/catch: `source` is `"session"` for no file, `"read"` for `PostToolUse`, `"edit"` for `PreToolUse`; `sessionId` only when `SESSION_ID.test(parsed.session_id)`; `tokens: estimateTokens(additionalContext)`. In `src/lessons-hook.ts` pass `usage: fileUsageLog(join(stateDir, "lessons-usage"), now)`.

- [ ] **Step 4: Run to verify they pass**

  Run: `npx vitest run test/lesson-hook.test.ts test/lesson-usage.test.ts`
  Expected: PASS.

- [ ] **Step 5: Commit**

  ```bash
  git -C /Users/anb-0826009/project/suica-lessons-usage add src/lessons/hook.ts src/lessons-hook.ts test/lesson-hook.test.ts
  git -C /Users/anb-0826009/project/suica-lessons-usage commit -m "feat(lessons): log the lessons the hook hands to a session"
  ```

---

### Task 3: The MCP server logs its answers

**Files:**
- Modify: `src/lessons/mcp-server.ts` (`LessonsServerDeps`, `runTool`)
- Modify: `src/cli.ts` (`lessonsMcp()`, around line 870)
- Test: `test/lesson-mcp.test.ts`

**Interfaces:**
- Consumes: Task 1's `UsageLog`, `fileUsageLog`, `estimateTokens`.
- Produces: `LessonsServerDeps` gains `readonly usage: UsageLog`.

- [ ] **Step 1: Write the failing tests.** `deps()` gets `usage` from a module-level `let usage = memoryUsage()` reset in `beforeEach` (same helper shape as Task 2; copy it, it is four lines). Tests:
  - `logs lessons_for_path on a file`: call `lessons_for_path` with `join(repoA, "src/a.go")` → one entry `{ at: NOW, project: "g/app", scope: scopeA, source: "mcp", tool: "lessons_for_path", file: "src/a.go", lessonIds: [the ids in the reply], tokens: estimateTokens(replyText) }` and no `sessionId`.
  - `logs a folder and a search without a file`: `lessons_for_path` on `repoA` and `search_lessons` → entries without `file`.
  - `logs get_lesson with its one id`.
  - Review Focus 4: `logs nothing for a reply without lessons`: `get_lesson` with scopeB's lesson id from a scopeA path, `get_lesson` of an archived lesson, `search_lessons` with no hit, and a call while `enabled = false` → `usage.entries` stays `[]`.

- [ ] **Step 2: Run to verify they fail**

  Run: `npx vitest run test/lesson-mcp.test.ts`
  Expected: new tests FAIL.

- [ ] **Step 3: Implement.** In `runTool`, have each branch return the shown `RankedLesson[]` (or the single lesson's id) with its body, and append one entry only when at least one Lesson is in the reply, in a try/catch so a log failure never turns into `FAILED`. `file` is `relative(found.repo.dir, path)` only when `isFile(path)` and `found.repo` exists. In `cli.ts` `lessonsMcp()` pass `usage: fileUsageLog(join(dirname(statePath), "lessons-usage"), Date.now())` using the same `statePath` the reader uses.

- [ ] **Step 4: Run to verify they pass**

  Run: `npx vitest run test/lesson-mcp.test.ts test/mcp.test.ts`
  Expected: PASS.

- [ ] **Step 5: Commit**

  ```bash
  git -C /Users/anb-0826009/project/suica-lessons-usage add src/lessons/mcp-server.ts src/cli.ts test/lesson-mcp.test.ts
  git -C /Users/anb-0826009/project/suica-lessons-usage commit -m "feat(lessons): log the lessons the MCP server answers with"
  ```

---

### Task 4: `suica lessons usage --json`

**Files:**
- Modify: `src/lessons/usage.ts` (add the aggregator and JSON types)
- Modify: `src/cli.ts` (command, `USAGE` string)
- Modify: `contracts/lessons.v1.json` (add `usage`)
- Modify: `README.md` (command list near line 217, Lessons section near line 270)
- Test: `test/lesson-usage.test.ts`, `test/lesson-cli.test.ts`

**Interfaces:**
- Consumes: Task 1's `UsageEntry`, `readUsage`, `USAGE_DAYS`; `LessonReader.lesson(id)` for titles.
- Produces (the document the app decodes):
  ```ts
  export interface UsageTotalsJson { readonly deliveries: number; readonly sessions: number; readonly tokens: number; readonly lessons: number }
  export interface UsageLessonJson { readonly id: number; readonly title: string | null; readonly times: number }
  export interface UsageProjectJson extends UsageTotalsJson {
    readonly project: string | null;
    readonly scope: string;
    readonly bySource: { readonly session: number; readonly read: number; readonly edit: number; readonly mcp: number };
    readonly lastAt: number;
    readonly topLessons: readonly UsageLessonJson[]; // at most 20, times desc then id asc
  }
  export interface LessonUsageJson {
    readonly version: 1;
    readonly generatedAt: number;
    readonly days: number;               // USAGE_DAYS
    readonly totals: UsageTotalsJson;
    readonly projects: readonly UsageProjectJson[]; // tokens desc, then project/scope asc
    readonly recent: readonly UsageEntry[];         // newest first, at most 100
  }
  export function buildLessonUsage(entries: readonly UsageEntry[], titleOf: (id: number) => string | undefined, now: number): LessonUsageJson;
  ```
  `sessions` counts distinct `sessionId`s (entries without one add none); `lessons` counts distinct ids. A row's key is `project` when set, else `scope` with `project: null`. `titleOf` returns undefined for a missing Lesson → `title: null`.

- [ ] **Step 1: Write the failing tests.**
  - In `test/lesson-usage.test.ts`, `buildLessonUsage` over a fixed list: two `g/app` entries in session `s1` (ids `[1,2]`, 40 tokens; `[1]`, 10 tokens, `read`), one `g/app` `mcp` entry (ids `[1]`, 5 tokens), one `null`-project entry in scope `/s` (ids `[3]`, 20 tokens), `titleOf` knowing 1 and 2 only. Expect `totals = { deliveries: 4, sessions: 1, tokens: 75, lessons: 3 }`; `projects[0]` is `g/app` with `tokens: 55, sessions: 1, bySource: { session: 1, read: 1, edit: 0, mcp: 1 }, topLessons: [{ id: 1, title: "…", times: 3 }, { id: 2, …, times: 1 }]`; `projects[1]` is `{ project: null, scope: "/s", …, topLessons: [{ id: 3, title: null, times: 1 }] }` (Review Focus 1); `recent[0]` is the newest entry; 101 entries yield `recent.length === 100`; an empty list yields zero totals and `[]`.
  - In `test/lesson-cli.test.ts`, extend `"lessons list and show match the golden"`'s sibling: `"lessons usage matches the golden"` builds from a fixed entry list and the seeded store's reader and `toEqual(golden.usage)`.

- [ ] **Step 2: Run to verify they fail**

  Run: `npx vitest run test/lesson-usage.test.ts test/lesson-cli.test.ts`
  Expected: FAIL (`buildLessonUsage` not exported; `golden.usage` undefined).

- [ ] **Step 3: Implement** `buildLessonUsage`; add the `usage` key to `contracts/lessons.v1.json` from the test's output (regenerate once, read it, commit it). In `cli.ts` add `lessonsUsageCommand(): number` beside `listLessonsCommand` — reads `readUsage(join(dirname(statePath), "lessons-usage"), now - USAGE_DAYS * 86_400_000)`, opens `openLessonsReadOnly` for titles (no reader → every title `null`), prints the document, exits 0; it runs whether or not lessons are enabled. Dispatch: `if (argv[1] === "usage" && json && flags.length === 1)`. Add `lessons usage --json` to `USAGE`. README: a line under the lessons commands (`suica lessons usage --json  # per project, the Lessons handed to Coding Agents in the last 30 days and their estimated tokens`) and one sentence in the Lessons section naming the log folder, the 30 days, and that tokens are characters / 4.

- [ ] **Step 4: Run to verify they pass**

  Run: `npx vitest run test/lesson-usage.test.ts test/lesson-cli.test.ts && npm run lint`
  Expected: PASS, lint clean.

- [ ] **Step 5: Commit**

  ```bash
  git -C /Users/anb-0826009/project/suica-lessons-usage add src/lessons/usage.ts src/cli.ts contracts/lessons.v1.json README.md test/lesson-usage.test.ts test/lesson-cli.test.ts
  git -C /Users/anb-0826009/project/suica-lessons-usage commit -m "feat(lessons): suica lessons usage prints the usage per project"
  ```

---

### Task 5: Usage view on the app's Lessons page

**Files:**
- Modify: `macos/Suica/Sources/SuicaCore/Lessons.swift` (decoders, `LessonsClient`, `LessonsModel`)
- Modify: `macos/Suica/Sources/SuicaCore/AgentClient.swift` (`CLIAgentClient: LessonsClient`)
- Modify: `macos/Suica/Sources/Suica/SuicaApp.swift` (`UnconfiguredClient: LessonsClient`)
- Modify: `macos/Suica/Sources/SuicaCore/Copy.swift` (near `lessonsAsGraph`, line ~1596)
- Create: `macos/Suica/Sources/Suica/Window/LessonsUsageView.swift`
- Modify: `macos/Suica/Sources/Suica/Window/LessonsView.swift` (`LessonsSplit`)
- Test: `macos/Suica/Tests/SuicaCoreTests/LessonsTests.swift` (`FakeLessonsClient` too)

**Interfaces:**
- Consumes: the `usage` document from Task 4 (`contracts/lessons.v1.json` key `usage`).
- Produces (names chosen not to collide with the existing `UsageDocument`/`TokenTotals` in `Dashboard.swift`):
  - `public struct LessonUsageDocument: Codable, Equatable, Sendable` with `version, generatedAt: Int, days: Int, totals: LessonUsageTotals, projects: [LessonUsageProject], recent: [LessonUsageEntry]`.
  - `LessonUsageTotals { deliveries, sessions, tokens, lessons: Int }`; `LessonUsageProject: Identifiable` (`id` = `project ?? scope`) with the JSON fields plus `bySource: LessonUsageSources { session, read, edit, mcp: Int }` and `topLessons: [LessonUsageLesson { id: Int, title: String?, times: Int }]`; `LessonUsageEntry { at: Int, project: String?, scope, source: String, tool: String?, sessionId: String?, file: String?, lessonIds: [Int], tokens: Int }`.
  - `LessonsClient.lessonsUsage() async throws(AgentError) -> LessonUsageDocument` (CLI: `document(LessonUsageDocument.self, ["lessons", "usage", "--json"])`).
  - `LessonsModel`: `public private(set) var usage: LessonUsageDocument?`, `public private(set) var usageError: String?`, `public func refreshUsage() async` (same latest-wins guard pattern as `refresh()`), `public func recent(for project: LessonUsageProject) -> [LessonUsageEntry]` (entries of `recent` whose `project ?? scope` equals `project.id`).
  - `Copy`: `lessonsAsUsage = "Usage"`, `lessonsUsageEmpty = "No agent has been handed Lessons in the last 30 days."`, `lessonsUsageTokens = "Estimated tokens"` and a footnote `lessonsUsageEstimate = "Estimated at four characters a token."`.

- [ ] **Step 1: Write the failing tests** in `LessonsTests.swift`:
  - `@Test func usageContractDecodes()`: `JSONDecoder().decode(LessonUsageDocument.self, from: lessonsContract("usage"))`; `#expect(document.projects.first?.project == <golden's first project>)`, a `null`-project row decodes with `project == nil`, `topLessons` with a `null` title decodes.
  - `@Test func cliAsksForUsage()`: the existing CLI-runner fake pattern (see `output(...)` helper) answers the golden; `lessonsUsage()` sends `["lessons", "usage", "--json"]`.
  - `@Test func modelRefreshesUsageAndGroupsRecent()`: `FakeLessonsClient` gets `var usage: LessonUsageDocument` and `func lessonsUsage()` appending `"usage"` to `calls`; after `await model.refreshUsage()`, `model.usage == fake.usage` and `model.recent(for: row)` returns only that row's entries; a throwing fake sets `usageError` and keeps the previous `usage`.

- [ ] **Step 2: Run to verify they fail**

  Run: `cd macos/Suica && swift test --filter LessonsTests`
  Expected: build FAILS (`LessonUsageDocument` not found).

- [ ] **Step 3: Implement the core types, client and model** per the Interfaces block; add the method to `UnconfiguredClient` (`throw AgentError.launchFailed`).

- [ ] **Step 4: Run to verify they pass**

  Run: `cd macos/Suica && swift test --filter LessonsTests`
  Expected: PASS.

- [ ] **Step 5: Build the view.** In `LessonsSplit` replace `@State private var showsGraph = false` with `@State private var mode: LessonsMode = .list` (`private enum LessonsMode: Hashable { case list, graph, usage }`); the segmented picker gets a third `Label(Copy.lessonsAsUsage, systemImage: "chart.bar.xaxis").tag(LessonsMode.usage)`; `.usage` shows `LessonsUsageView(model: model)` full width with no detail pane, and `.task(id: mode)` calls `model.refreshUsage()` when it becomes `.usage`. `LessonsUsageView`: a `List` of `model.usage?.projects` (project or scope folder name, deliveries, sessions, `Copy.lessonsUsageTokens` value, last used relative date), selection showing below or beside it that project's `topLessons` (title or `#id`, times) and `model.recent(for:)` (time, source with tool, file, Lesson ids, tokens); empty state `Copy.lessonsUsageEmpty`; `usageError` in the same style the page shows `errorText`; footnote `Copy.lessonsUsageEstimate`. Follow the existing page's fonts and paddings; no new styling primitives.

- [ ] **Step 6: Verify the build and look at it.** Run `cd macos/Suica && swift build && swift test`; expected: build succeeds, all tests pass. Render `LessonsUsageView` with the golden document through the scratch `NSHostingView` harness (see memory note on the UI screenshot harness) and check the list, a selected project and the empty state in light and dark.

- [ ] **Step 7: Commit**

  ```bash
  git -C /Users/anb-0826009/project/suica-lessons-usage add macos/Suica
  git -C /Users/anb-0826009/project/suica-lessons-usage commit -m "feat(app): a Usage view of the lessons handed to agents"
  ```

---

### Task 6: Tracker and full check

**Files:**
- Modify: `docs/superpowers/plans/TRACKER.md` (add P12 row: this plan, its spec, branch `feat/no-ticket-lessons-usage`, status)

- [ ] **Step 1: Run everything.** `npm test && npm run lint && (cd macos/Suica && swift test)`; expected: all pass (rerun a CLI-spawning test that times out once before blaming the change).
- [ ] **Step 2: Try it on real data.** With the CLI from this worktree, run `echo '{"hook_event_name":"SessionStart","session_id":"t1","cwd":"<a repo under lessons.scopes>"}' | node src/lessons-hook.ts`, then `node src/cli.ts lessons usage --json`; expected (needs `lessons.enabled` and at least one Lesson in that scope): one `session` entry for that repo with tokens > 0. This writes to `lessons-usage/` next to the real state database; delete that line from today's file afterwards if unwanted.
- [ ] **Step 3: Update TRACKER.md and commit**

  ```bash
  git -C /Users/anb-0826009/project/suica-lessons-usage add docs/superpowers/plans/TRACKER.md
  git -C /Users/anb-0826009/project/suica-lessons-usage commit -m "docs: track the lessons usage log plan"
  ```
