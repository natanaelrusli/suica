# Review Engine Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure Agent Reviews cover a consistent commit, recover safely from partial posting, and expose where review time is spent.

**Architecture:** Keep the SQLite queue, bounded worker and isolated shallow checkouts. Extract immutable review-input preparation and durable posting orchestration from `agent-review.ts`; journal remote writes and reconcile uncertainty before any retry. Keep approval as a separate SHA-guarded action.

**Tech Stack:** Node, TypeScript, node:sqlite, Vitest, GitLab through existing glab runners.

**Spec:** `docs/superpowers/specs/2026-11-16-review-reliability-and-responsive-ui-design.md` (E1–E5).

## Global Constraints

- Node >=24; TypeScript 5.9.3; Swift tools 6.0 and Swift language mode 6; macOS >=15.
- No new runtime dependencies or network service; preserve the CLI-to-SwiftUI architecture.
- Preserve approval strictness, SHA-guarded approval, configured review concurrency, and Owner control over posting.
- Preserve version-1 JSON consumers; additions must be optional or backward compatible.
- Do not send GitLab or Teams messages during implementation verification; use fakes and local fixtures.
- Follow fast-iteration: write regression tests with each task; run the full relevant gate only before push or opening/updating an MR.

## Review Focus

- A branch push or description edit during a review must not label mixed inputs as the reviewed head (Task 1).
- Missing, oversized, binary or truncated diff data must not become a clean approval (Task 1).
- GitLab accepts a write but the response is lost: recovery must not blindly duplicate it (Task 2).
- Two processes or a recovered old process attempt posting: only the current owner may advance local state or approve (Task 2).
- Cancellation, shutdown or cleanup failure must preserve the terminal review state and free the worker slot (Task 3).

---

## File responsibilities and order

1. Create `src/review-input.ts` for version selection and completeness checks; adapt `src/agent-review.ts` preparation and `src/reviews.ts` diff metadata.
2. Create `src/review-post.ts` for posting plans, ownership and reconciliation; add journal storage/migration in `src/store.ts`. Keep public `postAgentReview` in `agent-review.ts` as the compatibility entry point. Change recovery callers in `src/main.ts` and `src/cli.ts`.
3. Create `src/review-timing.ts` for bounded timing records; instrument the worker and replace its synchronous cleanup.

Each task is a separate commit and independently testable. Do not perform the test runs shown below on every edit; collect them for the final gate per fast-iteration.

### Task 1: Bind review inputs to one complete diff version

**Files:** Create `src/review-input.ts`, `test/review-input.test.ts`; modify `src/agent-review.ts:432`, `:532`, `:1044`, `src/reviews.ts:682`; extend `test/agent-review.test.ts`, `test/reviews.test.ts`.

**Interfaces:**
- Consumes existing `RestRunner`, `MrDetailJson`, `ReviewDeps`, `Exec` and `parseMrKey`.
- Produces `ReviewInput { detail: MrDetailJson; headSha: string; baseSha: string; startSha: string; versionId: number }` and `loadReviewInput(rest: RestRunner, detail: MrDetailJson): Promise<ReviewInput>`.
- Produces `assertReviewCoverage(input: ReviewInput): void`, throwing `RunFailure` with a precise reason on missing head, incomplete text or unsupported coverage.
- Add optional `expectedHeadSha?: string` after `gitDir?` in `cloneSourceBranch`; existing Agent Fix callers retain their behavior. Agent Review passes the expected SHA, checks out that exact object detached, verifies `rev-parse HEAD`, and fails if unavailable.

- [ ] **Step 1: Write regression cases using the existing fake REST and Exec patterns.** Tests named `usesVersionMatchingFetchedHead`, `rejectsIncompleteCoverage`, `rejectsUnavailableExactCommit`, `refusesStalePublication`; assertions:

  ```ts
  expect(input.headSha).toBe(SHA_A);
  expect(input.detail.files[0]?.diff).toBe(diffAtA);
  expect(modelCalls).toHaveLength(0); // every incomplete/unavailable fixture
  expect(postCalls).toHaveLength(0); // head or description changed before publishing
  expect(approvalCalls).toHaveLength(0);
  ```

  Include a fork whose branch name also exists on the target, missing diff version, `too_large`, server overflow, absent aggregate line counts, binary change, and a file beyond the 100-file UI page. A version may supply all files independently of the UI page; only demonstrably complete coverage can run.

- [ ] **Step 2: Implement `loadReviewInput` and `assertReviewCoverage`.** Extract and share the existing version schemas/lookup used by `planThreads`. Match `detail.headSha`, retrieve that immutable version, preserve server overflow/completeness fields, and apply the existing 200,000/file and 1,500,000/total text budgets. Missing metadata needed to prove completeness is a refusal. Keep UI rendering limits independent; do not change `fetchMrDetail` into an unlimited read.

- [ ] **Step 3: Wire exact checkout and version input into `runAgentReview`.** Build `mr.diff`, `mr.md`, changed-line checks, prompt and re-review preparation from `ReviewInput`. Verify checkout HEAD before model invocation. Do not silently fall back to a same-named target branch for fork MRs.

- [ ] **Step 4: Guard publication using current head and description hash.** Before the first remote comment, read current MR metadata and compare with the stored review input. On mismatch return existing `PostOutcome` `nothing`, retain `ready`, and set an explanation directing the Owner to review again. Ensure automatic notification/log handling does not claim a successful post. A push during later writes is still guarded by SHA-specific inline positions and existing approval SHA checks; do not promise atomicity across GitLab operations.

- [ ] **Step 5: Record gate commands and commit.** Gate: `npx vitest run test/review-input.test.ts test/agent-review.test.ts test/reviews.test.ts` must pass, including existing Agent Fix compatibility tests in the full gate. Commit affected files with `fix: bind agent reviews to complete immutable inputs`.

### Task 2: Journal posting and reconcile uncertain outcomes

**Files:** Create `src/review-post.ts`, `test/review-post.test.ts`; modify `src/store.ts` schema and Store methods, `src/agent-review.ts:1085`, `src/main.ts` recovery, `src/cli.ts` recovery/post action; extend `test/store.test.ts`, `test/agent-review.test.ts`, `test/review-cli.test.ts`.

**Interfaces:**
- Consumes Task 1 publication preflight and existing `PostRunner`, `PostJsonRunner`, `RestRunner`, `Store`.
- Export `PostPart { key: string; kind: "inline" | "summary"; endpoint: string; payload: string; state: "pending" | "sending" | "confirmed" | "uncertain" | "rejected"; remoteId: string | null }` from `review-post.ts`; payload is frozen JSON, not recomputed from later settings.
- Export `PostingLease { reviewId: number; token: string; expiresAt: number }`.
- Add Store methods `claimReviewPosting(id: number, token: string, now: number): PostingLease | undefined`, `saveReviewPostPlan(lease: PostingLease, parts: readonly PostPart[]): boolean`, `reviewPostParts(id: number): PostPart[]`, `updateReviewPostPart(lease: PostingLease, key: string, state: PostPart["state"], remoteId: string | null, now: number): boolean`, `renewReviewPosting(lease: PostingLease, now: number): boolean`, `finishReviewPosting(lease: PostingLease, now: number): boolean`.
- Export `resumeReviewPosting(deps: ReviewPostDeps, id: number): Promise<"posted" | "held" | "nothing">`; define `ReviewPostDeps` as Store plus the existing REST/post runners, logger, `now`, `ownerUsername: string`, and publication preflight callback `() => Promise<boolean>`. Resolve Owner identity through the existing authenticated-current-user lookup before any writes. `postAgentReview` maps held to its existing failed outcome.

- [ ] **Step 1: Add migration and fault-injection tests.** Exercise database reopen after each write boundary, concurrent claims, old-token completion, mode changes on retry, accepted-but-timeout inline and summary writes, incomplete remote pagination, and legacy interrupted rows. Assertions:

  ```ts
  expect(successfulRemoteMarkers).toHaveLength(new Set(successfulRemoteMarkers).size);
  expect(store.finishReviewPosting(oldLease, now)).toBe(false);
  expect(remoteWritesAfterUnresolvedTimeout).toBe(0);
  expect(store.getAgentReview(id)?.approved).toBe(false); // uncertain or stale owner
  expect(recoveredPlan).toEqual(originalPlan); // mode/config changes cannot rewrite it
  ```

- [ ] **Step 2: Implement the journal migration and fenced Store methods.** Store one ownership row per review and parts keyed by `(review_id, part_key)`, with durable payloads, attempt state, remote IDs and timestamps. Use transactions and token-guarded updates. Lease duration is 15 minutes; renew before each write. A `sending` part found after interruption becomes uncertain, never pending. Retention deletes journal rows with their review.

- [ ] **Step 3: Implement `resumeReviewPosting`.** Freeze the plan before any remote write; marker format is `<!-- suica-review:<id>:<headSha>:<partKey> -->`. Bound body size including marker and sanitize before appending it. Mark sending before the request; confirm after the response. Read all necessary note/discussion pages for reconciliation, matching marker and expected Owner identity. If a write's outcome remains uncertain, stop and retain the inspection warning—even if a search found nothing, absence does not prove a timed-out server write cannot arrive later. Continue only confirmed progress plus never-attempted parts. Findings without valid inline positions are included in the frozen summary from the start. A definite remote rejection becomes `rejected` and holds the remaining plan for inspection; do not silently rewrite an immutable summary or repeatedly resend the rejected part. Update the old inline-refusal fallback tests to assert this explicit hold.

- [ ] **Step 4: Integrate recovery and approval.** Startup and `reviewsJson` may flag abandoned work but must not turn ambiguity into a retryable clean state. Preserve existing statuses/JSON, expose the inspection reason through `detail`, and prevent the UI's retry action from bypassing the journal. Approve only after `finishReviewPosting` succeeds under the current token. Legacy rows with interrupted-post warnings remain held for inspection; do not claim historical writes are deduplicated.

- [ ] **Step 5: Record gate commands and commit.** Gate: `npx vitest run test/review-post.test.ts test/store.test.ts test/agent-review.test.ts test/review-cli.test.ts` must pass. Commit with `fix: persist review posting progress and reconcile ambiguity`.

### Task 3: Measure review stages and remove blocking cleanup

**Files:** Create `src/review-timing.ts`, `test/review-timing.test.ts`; modify `src/agent-review.ts`, `src/review-post.ts`; extend `test/agent-review.test.ts`; create `docs/review-performance.md` for the reproducible measurement procedure.

**Interfaces:**
- Consumes existing Logger and injected `now`.
- Produces `ReviewStage = "input" | "checkout" | "model" | "judge" | "posting" | "cleanup"` and `measureReviewStage<T>(id: number, stage: ReviewStage, now: () => number, emit: (record: ReviewStageRecord) => void, run: () => Promise<T>): Promise<T>`.
- `ReviewStageRecord = { reviewId: number; stage: ReviewStage; durationMs: number; outcome: "ok" | "failed" }`; queue wait is a separate nonnegative `queue_wait_ms` field on the existing start event.

- [ ] **Step 1: Write `recordsSuccessAndFailureOnce` and `cleanupFailureDoesNotChangeReviewOutcome`.** With fake time advancing from 100 to 140, assert `durationMs === 40`, one record, preserved return value/original error, and no prompt/body fields. For cancellation and cleanup errors assert the worker releases its slot and the review remains cancelled/posted as applicable.
- [ ] **Step 2: Instrument the six stage boundaries.** Keep model and judge timing separate, preserve existing total duration and token records, and route records through the existing logger. Replace `rmSync` in the review worker's final cleanup with awaited `node:fs/promises.rm`; catch and log cleanup failure without replacing the primary outcome.
- [ ] **Step 3: Document a local fake-run comparison.** Record concurrency, fixture sizes, queue wait, stage duration distributions and event-loop delay for 20 sequential fixture runs and one configured-concurrency batch. Keep injected fake model latency constant. Report measured numbers only at execution; defer repository caching unless checkout dominates.
- [ ] **Step 4: Run the final gate immediately before push/MR.** Run `npm run check` and `make test-app` (equivalent to `make test-all`), then `swift build --package-path macos/Suica` to compile the executable UI. Expected: all commands exit 0. Resolve failures before publishing; report actual output. Commit with `perf: measure review stages and avoid blocking cleanup`.

## Self-review and handoff

Coverage: E1/E2 → Task 1; E3/E4 → Task 2; E5 → Task 3. All five Review Focus cases have explicit test owners. JSON compatibility and approval policy are preserved. No production speedup is claimed until the measurement procedure runs. The separate UI plan requires none of these new APIs.
