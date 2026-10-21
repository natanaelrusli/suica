# Agent Fix, comments and merging — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Watch the Owner's MRs and answer Reviewer threads with a confirmed Agent Fix. Also let the Owner comment on and merge their own MRs from Suica.

**Architecture:**
- **Agent (TypeScript, Node 24, `node:sqlite`).**
  - A new `fix_run` table, behind `src/fix-store.ts`.
  - Finding Thread detection and queueing (`src/agent-fix.ts`), run by the poll.
  - A one-slot worker that clones, runs the model CLI with edit tools and keeps the checkout (`src/fix-runner.ts`).
  - Confirm, push and replies (`src/fix-confirm.ts`).
  - Comment and merge calls (`src/mr-actions.ts`).
  - CLI verbs `fix …`, `mr comment` and `mr merge`.
- **macOS app (SwiftUI).** A "Your MRs" group on the Reviews page. It opens the same detail view, which gains a Fix tab, a comment box and a Merge sheet.

**Tech Stack:** TypeScript (zod, vitest), glab CLI, git, SwiftUI with SwiftPM tests.

**Spec:** `docs/superpowers/specs/2026-10-21-agent-fix-comment-merge-design.md`

## Global Constraints

- Nothing reaches GitLab (commit, push, reply) before the Owner confirms. Never force push, never `--no-verify`.
- Only one fix runs at a time, and each MR has at most one open fix (queued, running or ready).
- Watching stops once every Reviewer is `APPROVED` (with at least one Reviewer). Everyone other than the Owner counts as a thread author, bots included.
- Config: `fix.auto` true, `fix.effort` medium, `fix.timeoutMinutes` 20, `fix.maxPerDay` 10, optional `fix.model` (same regex as `review.model`).
- Diff cap: 500 KB (`500_000` chars), else the fix fails with "the change is too large to show".
- Checkouts live in `join(dirname(statePath), "fixes", String(id), "repo")`.
- Logs: structured events only. Never log bodies, replies or diffs.
- Lint with `npx eslint src test`. Test with `npx vitest run` and `cd macos/Suica && swift test`.
- Alert defaults follow the existing Indonesian texts in `src/alerts.ts`. Code, comments, docs and commits are in English.
- Commit in the worktree with `git -C /Users/anb-0826009/project/suica-mr-fixes …`.

## Review Focus

1. **A Reviewer pushes to the branch while a fix is ready.** Confirm must refuse, without committing, and say so.
2. **The model returns no JSON, broken JSON, or thread ids that aren't in the fix.** The fix must fail, or ignore the unknown id. It must never post to an id it was not given.
3. **The agent restarts while a fix is running.** The row goes back to queued, and the stale checkout folder is deleted.
4. **A reply post fails halfway.** The push stays done, and "Post missing replies" sends only the unsent ones.
5. **Merge on a sha the Owner didn't see** (a newer push). GitLab's 409 maps to `sha-mismatch` and nothing merges.

Each has a test in the owning task, as named there.

---

### Task 1: `fix.*` config

**Files:**
- Modify: `src/config.ts`, `src/config-fields.ts`, `contracts/config.v1.json` (regenerate golden), `test/config.test.ts`, `test/config-fields.test.ts`
- Swift: `macos/Suica/Sources/SuicaCore/ConfigEditorModel.swift` or `Copy.swift`, only where categories are listed by name (add "Fixes" after "Agent Review")

**Interfaces:**
- Produces: `Config["fix"]: { auto: boolean; model?: string; effort: ReviewEffort; timeoutMinutes: number; maxPerDay: number }`

- [ ] **Step 1:** Test `fix defaults`. `parseConfig("gitlab: {hostname: h}\n").fix` equals `{ auto: true, effort: "medium", timeoutMinutes: 20, maxPerDay: 10 }`. `fix: {model: "-x"}` is refused.
- [ ] **Step 2:** Run `npx vitest run test/config.test.ts`. Expected: FAIL (`fix` undefined).
- [ ] **Step 3:** Add the `fix` object, strict, with `.default({})`, after `review` in `configSchema`. Add one `CONFIG_FIELDS` entry per key, with labels "Watch my MRs", "Fix model", "Fix effort", "Fix timeout" and "Automatic fixes per day". Update the golden the way `config-show.test.ts` documents.
- [ ] **Step 4:** Run `npx vitest run test/config*.test.ts` and `swift test`. Expected: PASS.
- [ ] **Step 5:** Commit `feat: fix.* config for Agent Fix`.

### Task 2: Comment and merge (agent side)

**Files:**
- Create: `src/mr-actions.ts`, `test/mr-actions.test.ts`
- Modify: `src/gitlab.ts` (add `glabPut`), `src/reviews.ts` (detail query and fields), `contracts/mr-detail.v1.json`, `src/cli.ts`

**Interfaces:**
- Produces:
  - `type PutRunner = (path: string, fields: Readonly<Record<string,string>>) => Promise<unknown>` and `glabPut(config, exec)`, the same as `glabPost` with `-X PUT`.
  - `commentOnMergeRequest(post: PostRunner, key: string, body: string): Promise<"posted" | "bad-key" | "empty" | "failed">`
  - `interface MergeOptions { squash: boolean; removeSourceBranch: boolean; message: string; whenPipelineSucceeds: boolean }`
  - `mergeMergeRequest(put: PutRunner, key: string, sha: string, options: MergeOptions): Promise<"merged" | "scheduled" | "not-mergeable" | "sha-mismatch" | "bad-key" | "failed">`
  - `MrDetailJson` gains `detailedMergeStatus: string | null`, `squashReadOnly: boolean`, `removeSourceBranch: boolean`, `defaultMergeCommitMessage: string | null` and `defaultSquashCommitMessage: string | null`.

- [ ] **Step 1:** Tests in `test/mr-actions.test.ts`, with fake runners that record calls:
  - `comment posts body to notes`: path `projects/g%2Fp/merge_requests/7/notes`, fields `{ body }`.
  - A blank body gives `empty`, with no call. A bad key gives `bad-key`.
  - `merge sends sha and options`: fields `sha`, `squash: "true"`, `should_remove_source_branch: "true"`, and `squash_commit_message` (for squash) or `merge_commit_message` (otherwise). `merge_when_pipeline_succeeds: "true"` only when asked.
  - The reply `{state: "merged"}` gives `merged`. `{state: "opened", merge_when_pipeline_succeeds: true}` gives `scheduled`.
  - A `FetchFailure` with `httpStatus` 405 or 406 gives `not-mergeable`, 409 gives `sha-mismatch`, and anything else gives `failed`. **(Review Focus 5)**
  - In `test/gitlab.test.ts`: `glabPut` passes `-X PUT` and `-f name=value`.
- [ ] **Step 2:** Run `npx vitest run test/mr-actions.test.ts test/gitlab.test.ts`. Expected: FAIL (module missing).
- [ ] **Step 3:** Implement the module. Add `detailedMergeStatus squashReadOnly forceRemoveSourceBranch defaultMergeCommitMessage defaultSquashCommitMessage` to `MR_DETAIL_QUERY` (`squashReadOnly` is a project field: query `project { squashReadOnly }` beside `mergeRequest`). Parse them nullable with zod, map them in, and update the golden and its test.
  - CLI: `suica mr comment <key> --json` reads stdin. `suica mr merge <key> <sha> --json [--squash] [--remove-source-branch] [--when-pipeline-succeeds]` reads the message from stdin. Both print `actionJson(outcome)`. Exit 0 for posted, merged or scheduled, else 1. Add both to `USAGE`.
  - Log `mr comment posted` / `mr merge` with `mr_key` and `outcome`.
- [ ] **Step 4:** Run `npx vitest run` and `npx eslint src test`. Expected: PASS, clean.
- [ ] **Step 5:** Commit `feat: comment on and merge an MR from the CLI`.

### Task 3: Fix store

**Files:**
- Create: `src/fix-store.ts`, `test/fix-store.test.ts`
- Modify: `src/store.ts` (schema 14, `Store.fixes`)

**Interfaces:**
- Produces, in `src/fix-store.ts`:
  ```ts
  export const FIX_STATUSES = ["queued","running","ready","confirming","pushed","push-failed","discarded","failed","skipped","cancelled"] as const;
  export type FixStatus = (typeof FIX_STATUSES)[number];
  export interface FixThread { id: string; noteId: string; author: Person; filePath: string|null; line: number|null;
    notes: { author: Person; body: string; createdAt: string }[];
    action: "changed"|"reply"|null; reply: string; post: boolean; posted: boolean }
  export interface FixRow { id: number; mrKey: string; mrTitle: string|null; trigger: "auto"|"manual"; status: FixStatus;
    threads: FixThread[]; note: string; baseSha: string|null; commitMessage: string; diff: string|null; pushedSha: string|null;
    cli: string|null; model: string|null; detail: string; activity: ActivityLine[]; createdAt: number; updatedAt: number; startedAt: number|null }
  export type FixFields = Partial<Pick<FixRow,"mrTitle"|"threads"|"baseSha"|"commitMessage"|"diff"|"pushedSha"|"cli"|"model"|"detail"|"startedAt">>;
  export interface FixStore {
    /** Adds threads to the MR's queued fix, or inserts a new queued row; undefined when a running/ready/confirming fix exists. */
    queue(mrKey: string, trigger: "auto"|"manual", threads: FixThread[], now: number, mrTitle?: string, note?: string): number | undefined;
    get(id: number): FixRow | undefined;
    nextQueued(): FixRow | undefined;
    open(mrKey: string): FixRow | undefined;              // queued|running|ready|confirming
    list(since: number): FixRow[];                         // open ones plus those updated since, newest first
    latestByMr(): Map<string, FixRow>;
    transition(id: number, from: readonly FixStatus[], to: FixStatus, fields: FixFields, now: number): boolean;
    appendActivity(id: number, at: number, text: string): void;
    countAuto(since: number): number;
    requeue(id: number, now: number): boolean;            // running → queued
    /** Newest note id each thread was handled at. */
    handledNotes(mrKey: string): Map<string, string>;
    markHandled(mrKey: string, threads: readonly { id: string; noteId: string }[]): void;
    interruptedRunning(): FixRow[];                        // rows in running (for startup requeue)
  }
  export function createFixStore(db: DatabaseSync): FixStore;
  ```
- Schema 14 (in `store.ts` `initSchema`):
  - `fix_run(id INTEGER PRIMARY KEY AUTOINCREMENT, mr_key, trigger, status, mr_title, threads TEXT NOT NULL, note TEXT NOT NULL DEFAULT '', base_sha, commit_message TEXT NOT NULL DEFAULT '', diff, pushed_sha, cli, model, detail TEXT NOT NULL DEFAULT '', activity TEXT NOT NULL DEFAULT '[]', created_at, updated_at, started_at)`
  - `fix_thread(mr_key, discussion_id, note_id, PRIMARY KEY (mr_key, discussion_id))`
  - Retention: done rows deleted after 90 days, in `queue`, like `agent_review`.

- [ ] **Step 1:** Tests:
  - `queue merges into a queued fix`: the same id, threads unioned by id, with the newest noteId kept.
  - `queue refuses while ready`
  - `transition is guarded`
  - `requeue clears startedAt and activity`
  - `handled notes round-trip`
  - `countAuto counts auto rows created since`
  - `a schema 13 database upgrades`: open a file made by today's `openStore`, set `user_version = 13`, reopen, and `fixes.list(0)` is `[]`.
- [ ] **Step 2:** Run `npx vitest run test/fix-store.test.ts`. Expected: FAIL.
- [ ] **Step 3:** Implement. `Store` gains `readonly fixes: FixStore`, built with `createFixStore(db)` inside `openStore`.
- [ ] **Step 4:** Run `npx vitest run`. Expected: PASS (the existing store tests too).
- [ ] **Step 5:** Commit `feat: store for Agent Fix runs`.

### Task 4: Finding Threads and automatic queueing

**Files:**
- Create: `src/agent-fix.ts`, `test/agent-fix.test.ts`
- Modify: `src/poller.ts` (an optional `queueFixes` hook run after `queueReviews`), `src/runtime.ts`

**Interfaces:**
- Consumes: `FixStore` (Task 3), `fetchMrDetail` / `MrDetailJson` / `DiscussionJson` (src/reviews.ts), and `Snapshot`.
- Produces:
  - `isApprovedByAll(mr: MergeRequest): boolean`
  - `findingThreads(detail: MrDetailJson, me: string, handled: ReadonlyMap<string,string> | "manual"): FixThread[]` returns threads that are resolvable, unresolved, have a newest non-system note by someone other than `me`, and are not handled at that note id. `"manual"` skips the handled check.
  - `queueAutomaticFixes(deps: { store: Store; config: Pick<Config,"fix">; log: Logger; now: () => number; detail: (key: string) => Promise<MrDetailJson> }, snapshot: Snapshot, previousSeenNotes: ReadonlySet<string>): Promise<void>`
  - `queueManualFix(deps, key: string, me: string): Promise<"queued" | "added" | "busy" | "nothing-to-fix" | "bad-key">`
  - `PollDeps.queueFixes?: (snapshot: Snapshot, previous: PreviousState) => Promise<void>`

**Behaviour of `queueAutomaticFixes`:**
1. Do nothing when `!config.fix.auto`.
2. For each MR in `snapshot.authored`:
   - If `isApprovedByAll`, cancel its queued fix with detail "The MR was approved." and skip it.
   - Otherwise, fetch the detail only when one of these holds: the MR has a note that is not system, not by me, and not in `previousSeenNotes`; or it has no `fix_thread` rows and no fix row yet (first run); or its latest fix ended since the last poll (threads that waited).
3. Queue `findingThreads` when there are any. Wait when the daily cap is reached (`countAuto(now − 24h) >= maxPerDay`): don't queue, and log `agent fix daily cap reached`.
4. Keys in fix rows that are open but no longer in `snapshot.authored`: queued and running become `cancelled` ("The MR is no longer open."). Ready becomes `discarded` with the same detail.
5. A detail fetch failure is logged (`agent fix detail failed`, `reason` = error name) and skipped. It never throws to the poll.

- [ ] **Step 1:** Tests:
  - `findingThreads`: a new Reviewer thread counts. A thread whose newest note is mine does not. A Reviewer reply after my reply counts. Resolved and non-resolvable threads don't count. A thread handled at its newest note doesn't count, but does with `"manual"`. A bot author counts.
  - `isApprovedByAll`: no Reviewers gives false, all `APPROVED` gives true, one revoked gives false.
  - `queueAutomaticFixes`:
    - queues on a new Reviewer note;
    - skips fetching when no note is new and the MR was seen before;
    - cancels a queued fix when the MR is approved;
    - leaves a ready fix alone when approved;
    - discards a ready fix when the MR left the snapshot;
    - stops at the daily cap;
    - does nothing with `fix.auto` false.
  - `queueManualFix` returns `nothing-to-fix` with no threads, and `busy` while ready.
- [ ] **Step 2:** Run `npx vitest run test/agent-fix.test.ts`. Expected: FAIL.
- [ ] **Step 3:** Implement. Wire it in `runtime.ts`: `queueFixes: (s, prev) => queueAutomaticFixes({…, detail: (k) => fetchMrDetail(run, rest, k)}, s, prev.seenNotes)`. In `poller.ts`, call it after `queueReviews` only when `previous.baselineDone`. It is wrapped like `queueReviews` (log `agent fix not queued` with the error name).
- [ ] **Step 4:** Run `npx vitest run`. Expected: PASS.
- [ ] **Step 5:** Commit `feat: watch the Owner's MRs for Finding Threads`.

### Task 5: Fix run and worker

**Files:**
- Create: `src/fix-runner.ts`, `test/fix-runner.test.ts`
- Modify:
  - `src/agent-review.ts`: export `checkout` as `cloneSourceBranch(deps: Pick<ReviewDeps,"rest"|"exec"|"signal">, detail: MrDetailJson, repoDir: string): Promise<string>`. Keep the behaviour.
  - `src/review-runner.ts`: `buildInvocation` gains a final `mode: "review" | "fix" = "review"`. For fix, claude tools are `Read Glob Grep Edit Write` and codex uses `--sandbox workspace-write`.
  - `src/store.ts`: `TokenPurpose` gains `"fix"`.
  - `src/alerts.ts`: `alert.fix-ready` [`mr.title`, `fix.threads`], `alert.fix-failed` [`mr.title`, `fix.reason`], `alert.fix-pushed` [`mr.title`]. Plus `contracts/templates.v1.json` and Swift `Copy` names and help.
  - `src/runtime.ts`, `src/main.ts`

**Interfaces:**
- Produces:
  - `fixDir(statePath: string, id: number): string`
  - `buildFixPrompt(cli, detail: MrDetailJson, threads: FixThread[], note: string): string`
  - `parseFixAnswer(body: string, threads: readonly FixThread[]): { commitMessage: string; threads: FixThread[] } | undefined`: the last fenced ```json block, checked with zod. Unknown ids are dropped, missing threads get `action: "reply"` with `reply: ""`, and `post` is true when the reply is non-empty.
  - `runAgentFix(deps: FixDeps, row: FixRow): Promise<void>`, which never throws.
  - `createFixWorker(deps: FixDeps): ReviewWorker`, with one slot.
  - `cleanFixDirs(store, statePath): number`
  - `interface FixDeps extends Omit<ReviewDeps,"store"|"config"> { store: Store; config: Config; statePath: string }`

**Run steps:**
1. Transition queued → running.
2. Resolve the CLI. Gemini is refused, as for reviews.
3. Fetch the detail. Clone into `fixDir/repo` and record `baseSha`.
4. Write `mr.md` (reuse `renderMrFile`), `threads.md` and `notes.md`.
5. Run the CLI with `mode "fix"`, `config.fix.model` / `effort` and the `timeoutMinutes` timeout. Activity lines go to the store. Tokens are recorded with purpose `fix`.
6. Parse the answer, then run `git add -A` and `git diff --cached --binary`.
7. With the diff empty, every `changed` becomes `reply`. A diff over `500_000` chars fails the fix.
8. Move to `ready` with threads, commitMessage, diff and baseSha. Notify `alert.fix-ready` (`fix.threads` = thread count).
9. On error, `failed` plus `alert.fix-failed`, `markHandled` and remove the dir. On shutdown, `requeue` and remove the dir.

Cancel is watched every 2 s, as in `runAgentReview`. Ready keeps the dir. `main.ts` calls `cleanFixDirs` and requeues interrupted running fixes on start, then ticks the fix worker beside the review worker.

- [ ] **Step 1:** Tests, using fake `exec` in the style of `test/agent-review.test.ts`:
  - `parseFixAnswer`:
    - a good block;
    - no block gives undefined (the run fails with "the model gave no answer block") **(Review Focus 2)**;
    - an unknown id is dropped **(Review Focus 2)**;
    - a missing thread becomes an empty reply.
  - `buildInvocation(…, "fix")` uses the edit tools and `workspace-write`.
  - `runAgentFix`:
    - ends ready with the diff and keeps the dir;
    - an empty diff turns `changed` into `reply`;
    - an oversized diff fails;
    - a CLI failure gives failed, handled threads and the dir removed;
    - a shutdown abort gives queued again with the dir removed **(Review Focus 3)**.
  - `cleanFixDirs` removes dirs of non-running, non-ready rows **(Review Focus 3)**.
- [ ] **Step 2:** Run `npx vitest run test/fix-runner.test.ts`. Expected: FAIL.
- [ ] **Step 3:** Implement and wire it up.
- [ ] **Step 4:** Run `npx vitest run` and `npx eslint src test`. Expected: PASS.
- [ ] **Step 5:** Commit `feat: run Agent Fixes with the model CLI`.

### Task 6: Confirm, retry, discard and the `fix` CLI

**Files:**
- Create: `src/fix-confirm.ts`, `test/fix-confirm.test.ts`, `contracts/fixes.v1.json`, `test/fixes-contract.test.ts`
- Modify: `src/cli.ts`

**Interfaces:**
- Produces:
  - `interface ConfirmEdits { commitMessage: string; threads: { id: string; reply: string; post: boolean }[] }` (zod-parsed from stdin, with unknown ids refused)
  - `confirmFix(deps: FixDeps & { post: PostRunner; graphql: GraphqlRunner }, id: number, edits: ConfirmEdits): Promise<"pushed" | "partial" | "branch-moved" | "push-failed" | "nothing">`
  - `postMissingReplies(deps, id): Promise<"pushed" | "partial" | "nothing">`
  - `retryFix(store, id, note, now): number | undefined` discards ready, failed or push-failed and queues a manual fix with the same threads and the note.
  - `discardFix` (ready or push-failed → discarded, then `markHandled` and remove the dir) and `cancelFix` (queued or running → cancelled).
  - `buildFixList(rows: FixRow[]): FixListJson`, where `FixListJson = { version: 1; fixes: FixJson[] }` and `FixJson` is the `FixRow` fields minus `trigger`. `diff` only when ready.

**Confirm order:**
1. ready → confirming.
2. Read `headSha` from `fetchMrDetail`. If it differs from `baseSha`: push-failed, "The branch moved since the fix was made; retry to redo it on the new commits." Return `branch-moved` before any git command. **(Review Focus 1)**
3. When the diff is non-empty: `git -C repo commit -q -m <message>`, then `git -C repo push origin HEAD:refs/heads/<sourceBranch>` with the same timeout as the clone. A failure gives push-failed with "GitLab refused the push (it is not a fast-forward)" or "the push failed (code …)". Read the sha with `git rev-parse HEAD`.
4. Post replies: for each `post` thread that isn't `posted`, POST `projects/:p/merge_requests/:iid/discussions/<numeric id from gid>/notes` with `{ body: reply.replaceAll("{{sha}}", sha.slice(0,8)) }`. Mark `posted` per thread.
5. → pushed, with detail "" or "2 of 3 replies posted". `markHandled` all threads at their noteId, remove the dir, and log `fix pushed` (`pushed_sha` and counts). Notify `alert.fix-pushed` only when partial.

**CLI:** `suica fix list --json`, `fix queue <key> --json`, `fix confirm <id> --json` (edits JSON on stdin), `fix retry <id> --json` (note on stdin), `fix discard <id> --json`, `fix cancel <id> --json` and `fix replies <id> --json`. Each prints `actionJson(outcome)`. Add them to `USAGE`.

- [ ] **Step 1:** Tests, with a fake exec that records git calls and a fake post:
  - `branch moved refuses before git` **(Review Focus 1)**
  - `commit, push, replies in order`, with `{{sha}}` filled in and no `--force` / `--no-verify` in any arg
  - `rejected push gives push-failed`
  - `don't-post threads are skipped`
  - `partial replies then postMissingReplies sends only unsent` **(Review Focus 4)**
  - `reply-only fix posts without git`
  - `confirm refuses an id not ready`
  - `retry queues a manual fix with the note`
  - The contract test: `buildFixList` of a fixture row deep-equals `contracts/fixes.v1.json`.
- [ ] **Step 2:** Run `npx vitest run test/fix-confirm.test.ts test/fixes-contract.test.ts`. Expected: FAIL.
- [ ] **Step 3:** Implement, and add the CLI verbs.
- [ ] **Step 4:** Run `npx vitest run` and `npx eslint src test`. Expected: PASS.
- [ ] **Step 5:** Commit `feat: confirm, retry and discard Agent Fixes`.

### Task 7: Your MRs in the review list

**Files:**
- Modify: `src/reviews.ts` (`buildReviewList`), `src/cli.ts` (`reviewsJson` passes `store.fixes.latestByMr()`), `contracts/reviews.v1.json`, `test/reviews.test.ts`

**Interfaces:**
- Produces: `ReviewListJson.yourMergeRequests: YourMrJson[]`, where `YourMrJson = { key, title, url, draft, createdAt, reviewers, pipelineStatus: null, approvedByAll: boolean, fix: { id, status, threads: number, changed: number, detail } | null }`. The list is in snapshot order.

- [ ] **Step 1:** Test `buildReviewList lists authored MRs with their fix summary`, which updates the golden.
- [ ] **Step 2:** Run it. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `npx vitest run`. Expected: PASS.
- [ ] **Step 5:** Commit `feat: list the Owner's MRs with their Agent Fix`.

### Task 8: macOS app

**Files:**
- Create: `macos/Suica/Sources/SuicaCore/Fixes.swift` (models and actions), `macos/Suica/Sources/Suica/Window/FixTab.swift`, `macos/Suica/Sources/Suica/Window/MergeSheet.swift`, `macos/Suica/Tests/SuicaCoreTests/FixesTests.swift`
- Modify:
  - `Reviews.swift`: decode `yourMergeRequests`, and add a `ReviewGroup.yours` section first.
  - `Models.swift`: the new detail fields.
  - `AgentClient.swift`: methods for each new CLI verb, with stdin through the existing `Invocation`.
  - `ReviewsView.swift`: rows for your MRs; for your MRs, a Fix tab, the Merge button and the comment box.
  - `Copy.swift`, plus the `ContractTests` / `DashboardContractTests` goldens.

**Interfaces:**
- Consumes: the contracts from Tasks 2, 6 and 7.
- Produces:
  - `struct FixInfo: Codable`, matching `FixJson`.
  - `func mergeAvailability(_ d: MergeRequestDetail) -> MergeAvailability`, where `enum MergeAvailability { case merge, whenPipelineSucceeds, blocked(String) }`:
    - `MERGEABLE` → `.merge`.
    - `CI_STILL_RUNNING`, or `CI_MUST_PASS` while the pipeline is `RUNNING`/`PENDING`/`CREATED` → `.whenPipelineSucceeds`.
    - `NOT_APPROVED`, `CI_MUST_PASS` (failed), `CONFLICT`, `DRAFT_STATUS`, `DISCUSSIONS_NOT_RESOLVED`, `NEED_REBASE` and `BLOCKED_STATUS` → `.blocked(Copy…)`, with `Copy.mergeBlockedOther` for anything else.
  - `ReviewsModel` methods: `fixes(for:)`, `queueFix`, `confirmFix(edits:)`, `retryFix(note:)`, `discardFix`, `cancelFix`, `postMissingReplies`, `comment(key:body:)` and `merge(key:sha:options:)`. Each sets a banner from its outcome and reloads the list and detail.

**UI:**
- **Fix tab:** status and activity while running. When ready: a diff (reuse `DiffLineRow` through `parseDiffLines`), and one card per thread with the notes, an action badge, a `TextEditor` reply and a "Don't post" toggle. Then a commit message field, a **Confirm and push** dialog ("Commit, push to <branch> and post N replies?"), **Retry with a note…** and **Discard**. "Fix findings now" sits in the header.
- **Merge sheet:** a squash toggle (disabled when `squashReadOnly`), a delete source branch toggle and the message (default from the detail for the mode). The button reads Merge or Merge when pipeline succeeds. A blocked state shows its reason as help text on the disabled button.
- **Comment box:** at the bottom of the Comments tab for your MRs, with a `TextEditor` and a preview through `MarkdownText`. **Send** is disabled while the box is blank.

- [ ] **Step 1:** `FixesTests`:
  - decodes `contracts/fixes.v1.json` and the new `reviews.v1.json`;
  - `mergeAvailability` for each status above;
  - `confirmFix` sends the edited JSON on stdin and maps outcomes to banners;
  - the comment is refused when blank.
- [ ] **Step 2:** Run `cd macos/Suica && swift test --filter FixesTests`. Expected: FAIL (compile).
- [ ] **Step 3:** Implement the models and views.
- [ ] **Step 4:** Run `swift test` (all). Expected: PASS. Check the UI with the screenshot harness (see memory): the Your MRs group, the Fix tab ready, and the Merge sheet.
- [ ] **Step 5:** Commit `feat(macos): Fix tab, comments and merging for your MRs`.

### Task 9: Docs

**Files:** `CONTEXT.md` (Finding Thread, Agent Fix, Watched MR), `README.md` (feature, config `fix.*` and CLI verbs), and the spec (record the rulings).

- [ ] **Step 1:** Write the docs. Run `npx vitest run` (the README config table test, if any). Expected: PASS.
- [ ] **Step 2:** Commit `docs: Agent Fix, comments and merging`.
