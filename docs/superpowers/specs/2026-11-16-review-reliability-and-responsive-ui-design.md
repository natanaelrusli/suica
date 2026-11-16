# Reliable, faster Agent Reviews and responsive MR pages

## Scope and evidence

Requested outcome: analyze the current MR review implementation and plan improvements to reliability, speed, and UI responsiveness. This is a source inspection of commit `a713dc8`, not a production incident report or benchmark. No live GitLab mutations, Teams messages, tests, builds, or profiling were performed. Proposed thresholds below are engineering acceptance criteria, not measured results.

Ship two independent increments: the review engine and the macOS MR page. Their plans are `../plans/2026-11-16-review-engine-reliability.md` and `../plans/2026-11-16-responsive-review-ui.md`. Implement the engine first because incorrect or repeated reviews cost more than slow navigation.

## Current implementation

- `src/agent-review.ts:979`: a bounded worker fills `review.concurrency` slots and immediately starts another queued review when a slot frees. Guarded SQLite transitions claim queued work. Preserve this; increasing concurrency is not the first optimization.
- `src/agent-review.ts:532`: fetches MR detail, shallow-clones a moving branch, runs the model and optional approval judge, stores the result, then optionally posts. Cancellation is observed through an abort signal and row state. Re-reviews already support incremental context.
- `src/agent-review.ts:432`: cloning uses the target project's SSH URL and source branch name. There is no comparison of checkout HEAD with `detail.headSha` before the prompt is built. A push between detail retrieval and cloning can mix old diff data with newer code. Fork-source behavior also needs a fail-closed regression case.
- `src/reviews.ts:862`: detail and diff requests run concurrently; the diff endpoint reads one page of 100 files. `parseDiffs` bounds each diff at 200,000 characters and total text at 1,500,000. Missing diff text becomes null. These are useful UI limits, but the review worker does not explicitly require complete diff coverage before producing a verdict. Fallback line counting can undercount omitted text.
- `src/agent-review.ts:1044`: inline posting already locates an immutable diff version by reviewed head SHA. Reuse that mechanism for review inputs.
- `src/agent-review.ts:1085`: each inline comment is posted sequentially, followed by a summary. A summary failure returns the row to `ready`; retrying can repost successful comments. The warning explicitly acknowledges this. `src/store.ts:1238` also returns stale postings to `ready` after 15 minutes without remote reconciliation.
- `src/agent-review.ts:1156`: approval is a separate, SHA-guarded operation. Preserve approval strictness, the recent evidence-only approval recheck rules, and review notice debounce behavior.
- `macos/Suica/Sources/SuicaCore/Reviews.swift:769`: refresh starts list and selected-detail reads together, ignores superseded results, and avoids storing equal documents. However, overlapping refreshes still launch work; each refresh discards all nonselected detail caches.
- `Reviews.swift:647`: a running review causes a refresh every 3 seconds, an active selected pipeline every 10, queued/posting reviews every 15, otherwise every 30. All refreshes also fetch the complete selected detail, even when only local review activity changed.
- `macos/Suica/Sources/SuicaCore/AgentClient.swift:480`: each detail read launches the CLI, whose `mrJson` fetches fresh GitLab detail and diffs. Process execution is asynchronous and bounded by timeout, but has no task-cancellation handler. Do not add blanket process cancellation: post/send/confirm commands have external side effects.
- `macos/Suica/Sources/Suica/Window/ReviewsView.swift:973`: diff parsing is already detached from the main actor and content uses lazy stacks. Its task identity is only `updatedAt`; two different MRs sharing a timestamp can reuse the wrong parsed state. Markdown block cache misses still parse synchronously on the main actor (`:1388`). The MR list has a fixed 300-point width (`:18`), while the app permits a 760-point window.

## Required outcomes

### Engine

E1. A review's diff, checkout, stored head, and inline positions must identify the same immutable head. Select the version matching the fetched MR head using the existing version lookup. Check out that exact commit, verify HEAD, and use that version's diff. A missing/incomplete version, unavailable commit, or ambiguous coverage must stop before invoking the model. Re-read the current head and description before publishing; a changed input leaves the review ready with an explicit stale explanation and never auto-approves it.

E2. Do not silently review partial textual changes. Keep existing size limits; mark coverage incomplete when file text is omitted by limits or server truncation. Binary-only changes must be explicitly represented as unsupported review coverage rather than assumed clean. The version schema cannot distinguish binary files from empty omitted text, so the internal `unsupported-empty-or-binary` category is conservative unsupported coverage. Preserve the UI's existing truncated-data display. This iteration fails closed instead of adding unbounded pagination or unlimited prompts.

E3. Record posting progress durably before and after each remote write. Use an immutable per-review posting plan and deterministic hidden markers for each inline comment and the summary. A retry skips confirmed writes. A lost acknowledgement requires remote reconciliation; if reconciliation cannot establish what happened, hold for Owner inspection rather than retrying automatically. Do not promise distributed exactly-once delivery.

E4. Posting ownership must be fenced across concurrent CLI/daemon processes. Lease expiry alone cannot authorize repeating an ambiguous write. A recovered old process must not complete the row or approve it. Existing reviews without a journal may use the new path only if they have no interrupted/ambiguous posting history; legacy ambiguous rows require inspection.

E5. Measure queue wait and detail/version, checkout, model, judge, posting, cleanup durations separately. Emit one bounded structured record per stage, with review ID, outcome and elapsed milliseconds; never include prompts, credentials, or response bodies. Use asynchronous temporary-directory removal so completed reviews do not synchronously block the Node event loop. Keep shallow isolated checkouts and configured concurrency; defer shared clone caches until measurements justify their locking and invalidation complexity.

### UI

U1. Coalesce overlapping list reads and detail reads by MR key. Retain at most 8 recently selected detail documents with a 30-second freshness lifetime. Selecting a cached MR shows it immediately; refresh failure preserves the last good data and an error. Generation guards apply to every state mutation, including pruning and loading indicators.

U2. Preserve existing list/activity polling intervals. Fetch full selected detail at most once per 30 seconds while idle and once per 10 seconds while its pipeline runs. Manual refresh and successful mutations force a fresh detail read. A force request arriving during a read schedules at most one trailing read, so it cannot accept a pre-action result as fresh. List/head changes invalidate detail when the list exposes that identity; the time limit remains the fallback for comments and approvals.

U3. Key diff preparation by MR key, head SHA and actual file content, not `updatedAt` alone. Clear old-MR presentation immediately; reject obsolete parse completions. Make block parsing asynchronous, cache by content, cap cached text at 8 MiB, and preserve Markdown links, code, tables, text selection and accessibility. Keep inline attributed-string rendering on its existing supported actor unless profiling proves it needs further work.

U4. Use the available MR-page width: below 900 points, offer a list/detail navigation presentation with a Back control; at 900 points and above retain a 300-point list beside detail. Preserve selection and per-MR tab/collapse state across layout changes. Respect Reduce Motion and VoiceOver. Test at the existing 760 × 480 minimum window and at 1280 × 800.

U5. Deterministic acceptance: three overlapping refreshes launch one list read and one eligible detail read; cycling among 8 fresh cached MRs launches no additional detail reads. An unchanged idle MR causes no more than one full detail read in 30 seconds despite 3-second activity ticks. A same-timestamp MR switch renders the selected MR's diff. Performance target on a recorded reference Mac: cached selection paints within 100 ms and no main-thread parsing interval exceeds 50 ms for the existing maximum diff budget plus a 100 KB review body. Record hardware, build mode, fixtures and before/after traces; do not turn wall-clock timing into flaky unit assertions.

## Global constraints

- Node >=24; TypeScript 5.9.3; Swift tools 6.0 and Swift language mode 6; macOS >=15.
- No new runtime dependencies or network service; preserve the CLI-to-SwiftUI architecture.
- Preserve approval strictness, SHA-guarded approval, configured review concurrency, and Owner control over posting.
- Preserve version-1 JSON consumers; additions must be optional or backward compatible.
- Do not send GitLab or Teams messages during implementation verification; use fakes and local fixtures.
- Follow fast-iteration: write regression tests with each task; run the full relevant gate only before push or opening/updating an MR.

## Deferred

No model change, reduced approval strictness, broad app redesign, daemon HTTP server, shared repository cache, or automatic retry of uncertain external writes. No claim that all slow UI behavior originates in these paths; profiling at the delivery gate determines whether further work is needed.
