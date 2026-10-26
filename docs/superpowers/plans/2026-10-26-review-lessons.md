# Review Lessons Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn every review finding into a scoped, deduplicated Lesson that reaches the Owner's Coding Agent at session start and on file reads, reminds the Owner of repeats, and exports as a markdown vault.

**Architecture:** Occurrences are collected from Agent Reviews and Finding Threads into new SQLite tables; a background learner (a tool-less model run, like the approval judge) groups them into Lessons per Lesson Scope. Read-only consumers sit on top: a fast standalone hook script for Claude Code, a hand-rolled stdio MCP server, a vault exporter, and new JSON contracts for the app.

**Tech Stack:** Node 24 TypeScript (`node:sqlite`, `node:path` `matchesGlob`, zod, vitest), SwiftUI app with SuicaCore decoders (`swift test`).

**Spec:** `docs/superpowers/specs/2026-10-26-review-lessons-design.md`

## Global Constraints

- No new npm dependency: the MCP server is hand-rolled JSON-RPC over stdio (`initialize`, `tools/list`, `tools/call`, `ping`; notifications ignored).
- `lessons.enabled` defaults to `false`; `lessons.perFile` and `lessons.perSession` default to `5`.
- No model call, no network, no write to the database on the hook path; the hook opens the database read-only, must answer in well under a second, and on any problem prints nothing and exits 0. It never answers `deny` or `ask`.
- A Lesson never reaches a repo, prompt or export outside its Lesson Scope.
- Finding text reaches the learning prompt fenced as data (closing tag defused, as `buildJudgePrompt` does); what reaches the agent is model-written Lesson text, capped (title ≤ 80 chars, rule ≤ 600 chars).
- Nothing changes `~/.claude/settings.json` or registers an MCP server without the Owner's confirmation (`--yes` on the CLI, a confirm dialog in the app).
- Vault notes carry no author names; Suica never deletes a vault file it did not write.
- Token use is recorded with purpose `lessons`.
- `README.md`, `CONTEXT.md` (Lesson, Occurrence, Lesson Scope, Topic, as worded in the spec), `contracts/*.v1.json` and their Swift decoders change in this branch.
- Branch `feat/no-ticket-review-lessons`; commit with `git -C ../suica-review-lessons …`; tests run with `npx vitest run <file>` and `cd macos/Suica && swift test`; lint with `npx eslint src test`.

## Review Focus

1. A file in a repo with no `origin`, a non-GitLab `origin`, or outside every scope → the hook prints nothing and exits 0 (Task 8).
2. Hook on a fresh install (no database yet) or while the daemon holds a write lock → prints nothing within the time limit, exits 0 (Task 8).
3. Finding text containing `</finding>` or "ignore previous instructions" → stays inside the fence in the learn prompt (Task 5).
4. `~/.claude/settings.json` that is missing → created; that is not valid JSON → install refuses and leaves it byte-for-byte unchanged (Task 10).
5. A model answer naming a Lesson id that does not exist or belongs to another scope → the batch is rejected and retried later; nothing is attached (Task 5).

---

### Task 1: Severity on each finding

**Files:**
- Modify: `src/inline-review.ts` (`Finding`, `extractFindings`)
- Test: `test/inline-review.test.ts`

**Interfaces:**
- Produces: `Finding.severity: string` — the capitalised severity subheading the finding sits under (`"Blocker" | "Major" | "Minor" | "Nit"` or another word), `""` when under none. Same rules as `severityOf` in `countFindings`.

- [ ] **Step 1: Write the failing test** `extractFindings gives each finding its severity subheading`: a body with `## Findings`, `### Blocker` item `` `a.ts:4` ``, `**Minor**` item `` `b.ts:9` `` and an item before any subheading → severities `["Blocker", "Minor", ""]`.
- [ ] **Step 2: Run** `npx vitest run test/inline-review.test.ts` — Expected: FAIL (`severity` undefined).
- [ ] **Step 3: Implement** by tracking the current severity in `extractFindings` the way `countFindings` does (share the subheading detection, don't duplicate it).
- [ ] **Step 4: Run** the same command — Expected: PASS, and the rest of the file still passes.
- [ ] **Step 5: Commit** `feat(lessons): give each review finding its severity`.

### Task 2: Lesson tables and store

**Files:**
- Create: `src/lesson-store.ts`
- Modify: `src/store.ts` (schema 20, `Store.lessons`, `TokenPurpose` gains `"lessons"`)
- Test: `test/lesson-store.test.ts`, `test/store.test.ts` (migration from 19)

**Interfaces:**
- Produces (all in `src/lesson-store.ts`):
```ts
export type OccurrenceSource = "review" | "thread";
export type Outcome = "open" | "fixed" | "not-fixed" | "partly-fixed" | "changed" | "replied" | "resolved";
export interface NewOccurrence {
  readonly sourceKey: string;            // "review:<id>:<findingNumber>" | "thread:<mrKey>:<discussionId>"
  readonly source: OccurrenceSource;
  readonly mrKey: string; readonly mrTitle: string; readonly mrUrl: string;
  readonly path: string | null; readonly line: number | null;
  readonly severity: string; readonly title: string; readonly text: string;   // title: first line, ≤ 120 chars
  readonly outcome: Outcome; readonly at: number;
}
export interface OccurrenceRow extends NewOccurrence { readonly id: number; readonly lessonId: number | null; readonly failures: number; readonly retryAt: number | null; }
export interface LessonRow {
  readonly id: number; readonly scope: string; readonly title: string; readonly rule: string;
  readonly topics: readonly string[]; readonly globs: readonly string[];
  readonly archived: boolean; readonly createdAt: number; readonly updatedAt: number;
}
export interface LessonStore {
  addOccurrences(rows: readonly NewOccurrence[]): number;                 // inserted count; existing sourceKey ignored
  setOutcome(sourceKey: string, outcome: Outcome, at: number): void;
  findOccurrenceByLocation(mrKey: string, path: string, title: string): OccurrenceRow | undefined;
  pendingOccurrences(now: number, limit: number): OccurrenceRow[];       // lessonId null, retryAt null or ≤ now, oldest first
  countPending(): number;
  failBatch(ids: readonly number[], retryAt: number): void;              // failures + 1
  createLesson(fields: Omit<LessonRow, "id" | "archived" | "createdAt" | "updatedAt">, at: number): number;
  attach(occurrenceIds: readonly number[], lessonId: number, at: number): void;
  lessons(scope: string, includeArchived?: boolean): LessonRow[];
  lesson(id: number): LessonRow | undefined;
  occurrences(lessonId: number): OccurrenceRow[];
  occurrenceBySource(sourceKey: string): OccurrenceRow | undefined;
  setScope(lessonId: number, scope: string, at: number): void;
  link(a: number, b: number): void;                                      // undirected, idempotent
  links(lessonId: number): number[];
  archive(id: number, at: number): void;
  merge(keepId: number, goneId: number, at: number): void;               // moves occurrences and links, deletes goneId
  meta(key: string): string | undefined; setMeta(key: string, value: string): void;   // shares store meta table
}
export function createLessonStore(db: DatabaseSync): LessonStore;
export function openLessonsReadOnly(statePath: string): LessonReader | undefined;   // undefined when the file is missing or cannot be opened
export type LessonReader = Pick<LessonStore, "lessons" | "lesson" | "occurrences" | "links"> & { close(): void };
```
- Tables (schema 20): `lesson(id, scope, title, rule, topics JSON, globs JSON, archived, created_at, updated_at)`, `lesson_occurrence(id, source_key UNIQUE, source, mr_key, mr_title, mr_url, repo_path TEXT NULL, path, line, severity, title, text, outcome, lesson_id NULL, failures, retry_at, at, updated_at)` with indexes on `lesson_id` and `(lesson_id IS NULL, retry_at)`, `lesson_link(a, b, PRIMARY KEY(a,b))` with `a < b`.

- [ ] **Step 1: Write the failing tests** in `test/lesson-store.test.ts` on `openStore(":memory:")`: `addOccurrences ignores a source key it already has` (insert twice → second returns 0); `pendingOccurrences skips attached and not-yet-due rows`; `merge moves occurrences and links and deletes the other lesson`; `link is undirected` (`link(3,1)` then `links(1)` → `[3]`); `openLessonsReadOnly returns undefined for a missing file`; `openLessonsReadOnly refuses writes` (an `INSERT` through its handle throws). In `test/store.test.ts`: `a schema 19 database upgrades to 20 with the lesson tables`.
- [ ] **Step 2: Run** `npx vitest run test/lesson-store.test.ts test/store.test.ts` — Expected: FAIL.
- [ ] **Step 3: Implement** `createLessonStore` in the style of `createFixStore` (rows through `sql-row.ts` helpers); add `SCHEMA_V20`, bump `SCHEMA_VERSION` to 20, expose `lessons: createLessonStore(db)` on `Store`. `openLessonsReadOnly` opens `new DatabaseSync(path, { readOnly: true, timeout: 200 })` and never runs `initSchema`.
- [ ] **Step 4: Run** the same command — Expected: PASS.
- [ ] **Step 5: Commit** `feat(lessons): store lessons and their occurrences`.

### Task 3: `lessons` config

**Files:**
- Modify: `src/config.ts`, `src/config-fields.ts`
- Test: `test/config.test.ts`, `test/config-fields.test.ts`

**Interfaces:**
- Produces: `config.lessons: { enabled: boolean; scopes: string[]; vaultPath?: string; perFile: number; perSession: number }`; `scopes` and `vaultPath` are `~`-expanded by `loadConfig` like `glabPath`. `perFile`/`perSession`: int 1–20, default 5. `scopes`: at most 20 entries.

- [ ] **Step 1: Write the failing tests** `lessons defaults to off with 5 per file and per session`; `lessons.scopes expands ~`; `lessons.perFile above 20 is rejected`; and in config-fields, the four fields appear in a new "Lessons" section (match how existing sections are asserted).
- [ ] **Step 2: Run** `npx vitest run test/config.test.ts test/config-fields.test.ts` — Expected: FAIL.
- [ ] **Step 3: Implement** the strict zod block and the field descriptors (the list editor kind the config already uses for string lists; a path field for `vaultPath`).
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `feat(lessons): add the lessons settings`.

### Task 4: Lesson Scopes and repo mapping

**Files:**
- Create: `src/lessons/scopes.ts`
- Test: `test/lesson-scopes.test.ts`

**Interfaces:**
- Produces:
```ts
export interface ScopedRepo { readonly scope: string; readonly dir: string; readonly project: string; }  // project: "group/sub/project"
export interface ScopeMap { readonly repos: readonly ScopedRepo[]; }
export function scanScopes(scopes: readonly string[], hostname: string, fs?: ScopeFs): ScopeMap;
export function scopeForProject(map: ScopeMap, project: string): ScopedRepo | undefined;
export function repoForPath(map: ScopeMap, absolutePath: string): ScopedRepo | undefined;   // deepest repo dir containing the path
export function projectOfMrKey(key: string): string;   // "g/p!7" → "g/p"
export function parseOrigin(url: string, hostname: string): string | undefined;   // ssh and https forms, ".git" stripped; other host → undefined
export interface ScopeFs { /* readdir/stat/readFile seam for tests */ }
```
- Rules: a scope folder that is itself a repo is one repo; otherwise walk below it (max depth 4), stopping at each repo (a dir with `.git` file or folder) and skipping `node_modules`, `.claude/worktrees` and hidden dirs; read `origin` from `.git/config` text (no `git` process); worktree `.git` files are followed to the main repo's config. A repo under two scopes takes the deeper scope. Symlinks are not followed.

- [ ] **Step 1: Write the failing tests** with a temp folder: `a parent scope finds every repo below it`; `a scope that is a repo is one repo`; `node_modules and nested worktrees are skipped`; `a repo under two scopes belongs to the deeper one`; `parseOrigin reads ssh and https remotes of the configured host` (`git@repo.madhani.one:g/p.git`, `https://repo.madhani.one/g/sub/p.git` → `g/p`, `g/sub/p`; `git@github.com:x/y.git` → undefined); `repoForPath picks the deepest repo containing the file`.
- [ ] **Step 2: Run** `npx vitest run test/lesson-scopes.test.ts` — Expected: FAIL.
- [ ] **Step 3: Implement** with `node:fs` sync calls behind `ScopeFs`.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `feat(lessons): map repos to lesson scopes`.

### Task 5: Collecting occurrences and learning Lessons

**Files:**
- Create: `src/lessons/collect.ts`, `src/lessons/learn.ts`
- Modify: `src/agent-review.ts` (extract a shared tool-less run from `runJudge`), `src/runtime.ts`, `src/daemon.ts` (tick the learner after each poll)
- Test: `test/lesson-collect.test.ts`, `test/lesson-learn.test.ts`

**Interfaces:**
- Consumes: Task 1 `Finding.severity`, Task 2 `LessonStore`, Task 3 `config.lessons`, Task 4 `scanScopes`/`scopeForProject`/`projectOfMrKey`, `findingThreads` (`src/agent-fix.ts`), `fetchFixDetail` (`src/reviews.ts`).
- Produces:
```ts
// collect.ts
export function occurrencesFromReview(row: AgentReviewRow): { add: NewOccurrence[]; outcomes: { mrKey: string; path: string; title: string; outcome: Outcome }[] };
export function occurrencesFromThreads(mr: { key: string; title: string; url: string }, threads: readonly FixThread[], at: number): NewOccurrence[];
export function threadOutcome(thread: FixThread): Outcome;   // action changed → "changed", reply → "replied", else "open"
export function collectReviews(store: Store, now: number): number;   // rows with status ready|posted and id > meta "lessons.reviewCursor", oldest first; advances the cursor
// learn.ts
export const learnAnswerSchema: z.ZodType<{ findings: { occurrence: number; lesson: number | null; title?: string; rule?: string; topics?: string[]; globs?: string[]; related?: number[] }[] }>;
export function buildLearnPrompt(scope: string, batch: readonly OccurrenceRow[], candidates: readonly LessonRow[]): string;
export function candidatesFor(store: LessonStore, scope: string, batch: readonly OccurrenceRow[], limit?: number): LessonRow[];   // same scope, unarchived, sharing a word ≥ 4 letters with a finding title or a topic; limit 30
export function applyAnswer(store: LessonStore, scope: string, batch: readonly OccurrenceRow[], answer: unknown, at: number): "applied" | "invalid";
export interface LessonLearner { tick(): Promise<void>; }
export function createLessonLearner(deps: LearnerDeps): LessonLearner;
// agent-review.ts
export async function runToolless(deps: Pick<ReviewDeps, "store" | "config" | "exec" | "signal" | "now" | "detectClis">, prompt: string, purpose: TokenPurpose, timeoutMinutes: number): Promise<string>;   // review.model, effort low, no tools; runJudge now calls it
```
- Rules:
  - Review occurrences: every `extractFindings` item of a review's own findings; `sourceKey` `review:<id>:<number>`; `## Previous review` lines (`<severity> `path:line` title — fixed|not fixed|partly fixed`) become outcomes matched by `findOccurrenceByLocation(mrKey, path, title)` with the title compared case-insensitively after trimming. Unmatched verdicts are ignored.
  - Thread occurrences: on each poll, for each of the Owner's open MRs whose notes changed since the previous poll (detect it the way `queueAutomaticFixes` does with `previous.seenNotes`), fetch the detail and call `findingThreads(detail, me, "manual")`; a thread already stored gets only `setOutcome`. Thread title is the first note's first line.
  - `repo_path` is filled from the scope map at insert; the scope of a batch is `scopeForProject(projectOfMrKey(mrKey))?.scope`. Occurrences with no scope stay pending without a retry time and are skipped by the learner until a scope maps them.
  - Nothing is collected or learned while `lessons.enabled` is false (no GitLab reads, no tokens). The first tick after it is turned on backfills: `collectReviews` starts from cursor 0, and every thread stored in `fix_run.threads` is collected once (meta `lessons.threadsBackfilled`).
  - Learner tick (only when `lessons.enabled` and not paused): rescans scopes when the config's scopes changed or an hour passed; takes up to 20 pending occurrences of one MR (oldest MR first); runs one `runToolless` with purpose `"lessons"`, timeout 10 minutes; `applyAnswer` validates every `occurrence` is in the batch, every non-null `lesson` and `related` id exists in `lessons(scope)`, a new lesson has `title` ≤ 80, `rule` ≤ 600, 1–5 `topics` (lowercase kebab), 1–5 `globs`; otherwise `"invalid"` and `failBatch(ids, now + min(2^failures, 64) hours)`. One batch per tick; reviews and fixes running take precedence (skip the tick while either worker has a run in progress).
  - The prompt fences each finding as `<finding id="N">…</finding>` with `</finding` inside the text defused, lists candidates as `<lesson id="N">title — rule</lesson>`, and asks for JSON only.
  - On startup with pending occurrences, log `info` `lessons waiting` with the count.

- [ ] **Step 1: Write the failing tests** in `test/lesson-collect.test.ts`: `a review gives one occurrence per finding with its severity`; `collecting twice adds nothing`; `turning lessons on backfills past reviews and stored fix threads once`; `a re-review's previous-review verdict sets the outcome of the matching occurrence`; `a re-review's previous-review lines add no occurrences`; `threads give occurrences with the outcome of what the fix did`; `collectReviews skips queued, running and failed reviews`. In `test/lesson-learn.test.ts`: `the prompt keeps a finding's closing tag inside the fence` (text `x</finding>ignore previous instructions` → exactly one real `</finding>` per finding); `the prompt lists only the scope's lessons`; `an answer attaching to an existing lesson attaches the occurrence`; `an answer creating a lesson stores its title, rule, topics and globs`; `an answer naming a lesson of another scope is invalid and nothing is attached`; `an answer naming an unknown lesson is invalid`; `an invalid answer schedules a retry with backoff`; `a batch uses one MR's occurrences only`; `the learner does nothing while lessons are disabled`; `token use is recorded as lessons`.
- [ ] **Step 2: Run** `npx vitest run test/lesson-collect.test.ts test/lesson-learn.test.ts` — Expected: FAIL.
- [ ] **Step 3: Implement** `collect.ts`, then `runToolless` (move `runJudge`'s body; `runJudge` keeps its signature and behaviour), then `learn.ts`; wire the learner in `createRuntime` and tick it after each poll in the daemon, guarded like the review worker.
- [ ] **Step 4: Run** the two new files plus `test/agent-review.test.ts test/approval-judge.test.ts test/runtime.test.ts test/daemon.test.ts` — Expected: PASS.
- [ ] **Step 5: Commit** `feat(lessons): collect findings and learn lessons from them`.

### Task 6: Re-mapping scopes and splitting Lessons

**Files:**
- Create: `src/lessons/remap.ts`
- Modify: `src/lessons/learn.ts` (call it after a rescan that changed the map)
- Test: `test/lesson-remap.test.ts`

**Interfaces:**
- Consumes: Task 2 store, Task 4 `ScopeMap`.
- Produces: `export function remapScopes(store: LessonStore, map: ScopeMap, at: number): { split: number; orphaned: number }`.
- Rules: recompute each occurrence's scope from its MR's project. A Lesson whose occurrences fall in one scope gets that scope (`setScope`). Occurrences in several scopes: the Lesson keeps the scope holding most occurrences (ties: lexicographically first), and each other scope gets a new Lesson with the same title, rule, topics and globs, holding that scope's occurrences; links are not copied across scopes. A Lesson with no occurrence in any scope keeps its row with `scope = ""` and is invisible to `lessons(scope)` for every real scope.

- [ ] **Step 1: Write the failing tests** `a lesson whose repos move to a deeper scope moves with them`; `a lesson spread over two scopes splits into one per scope`; `a lesson whose scope was removed reaches no scope`; `links do not cross scopes after a split`.
- [ ] **Step 2: Run** `npx vitest run test/lesson-remap.test.ts` — Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `feat(lessons): keep lessons in step with their scopes`.

### Task 7: Weight and matching

**Files:**
- Create: `src/lessons/match.ts`
- Test: `test/lesson-match.test.ts`

**Interfaces:**
- Produces:
```ts
export function weight(occurrences: readonly Pick<OccurrenceRow, "severity" | "at">[], now: number): number;
export interface RankedLesson { readonly lesson: LessonRow; readonly weight: number; readonly count: number; readonly repos: readonly string[]; readonly last: { readonly mrKey: string; readonly at: number }; }
export function rankLessons(reader: Pick<LessonStore, "lessons" | "occurrences">, scope: string, now: number): RankedLesson[];   // unarchived, heaviest first
export function lessonsForFile(ranked: readonly RankedLesson[], relativePath: string, limit: number): RankedLesson[];   // path.matchesGlob on any glob
export function renderLessons(lessons: readonly RankedLesson[]): string;   // "- <title>: <rule> (flagged N times, last in <repo> !iid)" per line
```
- Weight (_builder's formula, pinned here_): sum over occurrences of severity factor (Blocker 4, Major 3, Minor 1.5, Nit 1, other 1) × `0.5 ^ (ageDays / 90)`.

- [ ] **Step 1: Write the failing tests** `a Blocker weighs more than a Nit of the same age`; `a recent occurrence weighs more than an old one`; `archived lessons are not ranked`; `lessonsForFile matches language and folder globs` (`**/*.go` matches `cmd/api/main.go`; `**/handlers/**` matches `internal/handlers/user.go`; neither matches `README.md`); `lessonsForFile keeps the heaviest up to the limit`; `renderLessons names the count and the last MR`.
- [ ] **Step 2: Run** `npx vitest run test/lesson-match.test.ts` — Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `feat(lessons): rank lessons and match them to files`.

### Task 8: The Claude Code hook

**Files:**
- Create: `src/lessons-hook.ts` (standalone entry; imports only `node:*`, `lesson-store.ts`, `lessons/scopes.ts`, `lessons/match.ts` and the config loader), `src/lessons/hook.ts` (pure logic)
- Test: `test/lesson-hook.test.ts`

**Interfaces:**
- Consumes: Tasks 2, 3, 4, 7.
- Produces:
```ts
export interface HookInput { readonly hook_event_name: "SessionStart" | "PostToolUse" | "PreToolUse"; readonly session_id: string; readonly cwd: string; readonly tool_name?: string; readonly tool_input?: { readonly file_path?: string }; }
export function answerHook(input: unknown, deps: HookDeps): string;   // "" or JSON {"hookSpecificOutput":{"hookEventName":…,"additionalContext":…}}
export interface HookDeps { readonly config: Config["lessons"]; readonly hostname: string; readonly reader: LessonReader | undefined; readonly seen: SeenStore; readonly now: number; readonly scan: () => ScopeMap; }
export interface SeenStore { get(sessionId: string): ReadonlySet<number>; add(sessionId: string, ids: readonly number[]): void; }
export function fileSeenStore(dir: string, now: number): SeenStore;   // <dir>/<sessionId>.json; files older than 24 h removed on open; session ids not matching /^[\w-]{1,100}$/ are ignored
```
- Rules: `SessionStart` → `repoForPath(cwd)`'s scope, top `perSession` by weight, prefixed by one line: "Lessons from past code reviews in this folder. More come per file as you read; ask the `suica-lessons` MCP server for others." `PostToolUse` with `tool_name` `Read`, and `PreToolUse` with `Write`/`Edit`/`MultiEdit` → `lessonsForFile(…, perFile)` on the path relative to the repo dir. Lessons in `seen` for the session are dropped before the limit; the shown ids are added. Disabled, unparseable input, no repo, no scope, no reader, no match → `""`. The entry wraps everything in try/catch, writes the answer to stdout, exits 0. The scope scan result is cached in `<stateDir>/lesson-scopes.json` by the learner (Task 5 writes it after each rescan) so the hook reads that file instead of walking folders; `scan` falls back to `scanScopes` only when the file is missing.

- [ ] **Step 1: Write the failing tests** `SessionStart in a scope gives the heaviest lessons with the intro line`; `Read of a matching file gives its lessons`; `Edit of a new file gives its lessons`; `a lesson already shown in the session is not shown again`; `a file outside every scope gives nothing`; `a repo without a GitLab origin gives nothing`; `no database gives nothing`; `disabled lessons give nothing`; `garbage on stdin gives nothing`; `the answer never contains a permission decision`; `an odd session id is not used as a file name`; and an integration test `the hook script answers within 1 second on a seeded database while another connection holds a write transaction` spawning `node src/lessons-hook.ts` (give it a 20 s vitest timeout per the repo's note on spawned CLIs).
- [ ] **Step 2: Run** `npx vitest run test/lesson-hook.test.ts` — Expected: FAIL.
- [ ] **Step 3: Implement** `hook.ts`, `lessons-hook.ts`, and the learner's `lesson-scopes.json` write.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `feat(lessons): hand lessons to Claude Code at session start and on reads`.

### Task 9: The lessons MCP server

**Files:**
- Create: `src/lessons/mcp-server.ts`
- Modify: `src/cli.ts` (`suica lessons mcp`)
- Test: `test/lesson-mcp.test.ts` (drive it with `openMcpSession` from `src/teams/mcp.ts`)

**Interfaces:**
- Consumes: Tasks 2, 4, 7.
- Produces: `export function serveLessons(input: Readable, output: Writable, deps: LessonsServerDeps): Promise<void>` speaking newline-delimited JSON-RPC 2.0, protocol version echoed from `initialize`, server name `suica-lessons`. Tools:
  - `lessons_for_path { path: string }` → `renderLessons(lessonsForFile(…, perFile))` for a file, or the scope's top `perSession` for a folder.
  - `search_lessons { path: string; query: string; topic?: string }` → lessons of `path`'s scope whose title or rule contains every query word (case-insensitive), optionally with the topic, heaviest first, at most 10.
  - `get_lesson { path: string; id: number }` → the lesson and its occurrences (repo, MR link, file:line, severity, outcome, text capped at 500 chars), only if it is in `path`'s scope.
  - A path outside every scope → a text result "No lessons apply here."; bad arguments → JSON-RPC error `-32602`.

- [ ] **Step 1: Write the failing tests** `initialize then tools/list names the three tools`; `lessons_for_path on a file returns its lessons`; `search_lessons stays in the path's scope`; `get_lesson of another scope's lesson is not returned`; `an unknown method is a -32601 error`; `bad arguments are a -32602 error`.
- [ ] **Step 2: Run** `npx vitest run test/lesson-mcp.test.ts` — Expected: FAIL.
- [ ] **Step 3: Implement**, opening the database with `openLessonsReadOnly` per call.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `feat(lessons): serve lessons to any coding agent over MCP`.

### Task 10: Installing the hook and the server

**Files:**
- Create: `src/lessons/install.ts`
- Modify: `src/cli.ts` (`suica lessons install [--yes] [--json]`, `suica lessons uninstall [--json]`, `suica lessons status --json`)
- Test: `test/lesson-install.test.ts`

**Interfaces:**
- Produces:
```ts
export interface InstallPlan { readonly settingsPath: string; readonly hooks: readonly { event: string; matcher: string }[]; readonly mcp: readonly ("claude" | "codex")[]; }
export function planInstall(home: string, clis: readonly DetectedCli[]): InstallPlan;
export function installHooks(settingsText: string | undefined, command: string): string;   // throws InvalidSettings on non-JSON; keeps every other key and hook
export function uninstallHooks(settingsText: string, command: string): string;            // removes only entries whose command is ours
export function lessonsStatus(home: string): { hook: boolean; mcp: { claude: boolean; codex: boolean } };
```
- Hook entries: `SessionStart` (no matcher), `PostToolUse` matcher `Read`, `PreToolUse` matcher `Write|Edit|MultiEdit`, each `{ "type": "command", "command": "<node> <install>/src/lessons-hook.ts", "timeout": 5 }`. MCP: `claude mcp add --scope user suica-lessons -- <node> <install>/src/cli.ts lessons mcp`, and `codex mcp add suica-lessons -- …` when Codex is installed, through `Exec` with a timeout; uninstall runs the matching `remove`. Without `--yes`, `install` prints the plan and exits 1 without changing anything. The file is written atomically (temp file + rename) keeping its mode.

- [ ] **Step 1: Write the failing tests** `install adds three hook entries and keeps existing hooks and keys`; `install twice leaves one set of entries`; `install into a missing settings file creates it`; `install refuses settings that are not JSON and leaves them unchanged`; `uninstall removes only Suica's entries`; `install without --yes changes nothing and prints the plan`; `install registers the MCP server with claude, and with codex only when installed`.
- [ ] **Step 2: Run** `npx vitest run test/lesson-install.test.ts` — Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `feat(lessons): install the lessons hook and MCP server on request`.

### Task 11: Vault export

**Files:**
- Create: `src/lessons/vault.ts`
- Modify: `src/lessons/learn.ts` (export after a batch that changed something, when `vaultPath` is set), `src/cli.ts` (`suica lessons export [--json]`)
- Test: `test/lesson-vault.test.ts`

**Interfaces:**
- Produces: `export function exportVault(reader: LessonReader & Pick<LessonStore, "lessons">, scopes: readonly string[], dir: string, now: number): { written: number; removed: number }`; `export function slug(title: string, id: number): string` (lowercase ASCII words joined by `-`, ≤ 60 chars, `-<id>` suffix so slugs never collide).
- Layout: `Lessons/<slug>.md`, `Topics/<topic>.md`, `Repos/<project with / as ->.md`, `index.md`, `.suica-vault.json` (manifest of written paths). Lesson note: YAML front matter `id, scope, topics, weight (2 decimals), first_seen, last_seen` (ISO dates), `# <title>`, the rule, `## Related` with `[[…]]` links, `## Occurrences` lines `- [[Repos/…]] [!iid](url) \`path:line\` <severity>, <outcome>: <text ≤ 300 chars>`. No author names anywhere. Archived and scope-less Lessons are left out. Files in the manifest but no longer produced are removed; files not in the manifest are never touched.

- [ ] **Step 1: Write the failing tests** `each lesson gets a note linked to its topics and repos`; `index ranks lessons by weight`; `archived lessons are left out`; `a file the vault did not write is kept`; `a lesson that disappeared has its note removed`; `no note names an author` (seed occurrences from threads with author names in the text and assert the Person names are absent from the front matter and occurrence prefix); `slugs of equal titles differ`.
- [ ] **Step 2: Run** `npx vitest run test/lesson-vault.test.ts` — Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `feat(lessons): export lessons as a markdown vault`.

### Task 12: Lessons contracts and CLI for the app

**Files:**
- Create: `contracts/lessons.v1.json`
- Modify: `src/cli.ts` (`suica lessons list --json`, `suica lessons show <id> --json`, `suica lessons archive <id> --json`, `suica lessons merge <keep> <gone> --json`), `src/reviews.ts` (`AgentReviewJson.repeats`), the fix list JSON (`threads[].repeat`), `contracts/reviews.v1.json`, `CONTEXT.md`, `README.md`
- Test: `test/lesson-cli.test.ts`, `test/reviews.test.ts`

**Interfaces:**
- Produces:
  - `lessons.v1.json`: `{ version: 1, enabled, scopes: [{ path, repos: number, lessons: [{ id, title, rule, topics, weight, count, repos: string[], lastSeen }] }], pending: number }`; `show`: `{ version: 1, lesson: {…, related: [{id,title}], occurrences: [{ mrKey, mrTitle, mrUrl, path, line, severity, outcome, text, at }] } }`.
  - `AgentReviewJson.repeats: { finding: string; lessonId: number; title: string; before: number; repos: string[] }[]` — for each finding of that review whose occurrence is attached to a Lesson with other occurrences; `before` counts the others. Fix thread JSON gains `repeat: { lessonId, title, before, repos } | null` the same way.
  - `merge` refuses Lessons of different scopes (`bad-request`).
  - `archive` and `merge` re-export the vault when `vaultPath` is set.

- [ ] **Step 1: Write the failing tests** `lessons list matches the golden`; `lessons show lists occurrences newest first`; `merge of two scopes is a bad request`; `archive hides a lesson from list`; `a review finding that repeats a lesson carries the repeat` (golden updated); `a finding of a lone lesson carries no repeat`.
- [ ] **Step 2: Run** `npx vitest run test/lesson-cli.test.ts test/reviews.test.ts` — Expected: FAIL.
- [ ] **Step 3: Implement**; update the goldens, `CONTEXT.md` (the four terms, as the spec words them) and `README.md` (a "Lessons" section: what it does, the settings, `suica lessons install --yes`, the MCP line for other agents, the vault). Run every README command you document.
- [ ] **Step 4: Run** `npm run check` — Expected: typecheck, lint, format and all tests pass (rerun a spawned-CLI timeout once before blaming the change).
- [ ] **Step 5: Commit** `feat(lessons): list lessons and mark repeated findings for the app`.

### Task 13: The app

**Files:**
- Create: `macos/Suica/Sources/SuicaCore/Lessons.swift`, `macos/Suica/Sources/Suica/Window/LessonsView.swift`
- Modify: `SuicaCore/Reviews.swift`, `SuicaCore/Fixes.swift` (decode `repeats`/`repeat`), `SuicaCore/AgentClient.swift` (list, show, archive, merge, status, install, uninstall), `SuicaCore/WindowModel.swift` + `Window/MainWindow.swift` (a Lessons page in the sidebar), `Window/ReviewsView.swift` and `Window/YourMRViews.swift` (repeat marker), `Window/ConfigurationView.swift` (Lessons section with an "Agent hook and MCP server" toggle that shows the install plan in a confirm dialog before calling `install --yes`)
- Test: `macos/Suica/Tests/SuicaCoreTests/LessonsTests.swift`, `ReviewsTests.swift`, `FixesTests.swift`

**Interfaces:**
- Consumes: Task 12 contracts, Task 10 CLI.
- Produces: `LessonListDocument`, `LessonDetailDocument`, `ReviewRepeat`; marker copy "Flagged N times before, in `a`, `b`" linking to the Lesson; Lessons view lists by weight with Topic and repo filters and search (reuse `Search.swift`), detail shows rule, related and occurrences with MR links, and Merge into… / Archive actions.

- [ ] **Step 1: Write the failing tests** `lessons.v1.json decodes`; `reviews.v1.json repeats decode`; `the repeat marker text names the count and repos`; `filtering by topic and repo keeps matching lessons`.
- [ ] **Step 2: Run** `cd macos/Suica && swift test` — Expected: FAIL.
- [ ] **Step 3: Implement** the decoders and model, then the views following `ReviewsView`/`ReviewPicker` patterns.
- [ ] **Step 4: Run** `swift test` — Expected: PASS. Then render the Lessons view and an MR detail with a repeat marker through the screenshot harness (see memory `suica-ui-screenshot-harness`) and look at both.
- [ ] **Step 5: Commit** `feat(lessons): show lessons and repeated findings in the app`.

### Task 14: End-to-end check on real data

- [ ] **Step 1:** Back up the live database into the scratchpad with `sqlite3 .backup`, point a copied config's `statePath` at it with `lessons.enabled: true` and `scopes: ["~/repo.madhani.one"]`, and run `node src/cli.ts once` until `lessons list --json` shows lessons (pending count falls).
- [ ] **Step 2:** Pipe a sample `SessionStart` and a `PostToolUse` `Read` JSON for a real file under `~/repo.madhani.one` into `node src/lessons-hook.ts` with that config; Expected: lessons text, under 1 s (`time`).
- [ ] **Step 3:** `suica lessons export` into a scratch folder and open it to check links resolve.
- [ ] **Step 4:** Report the results honestly, including anything not verified; do not run `install --yes` against the Owner's real `~/.claude/settings.json` without asking.
