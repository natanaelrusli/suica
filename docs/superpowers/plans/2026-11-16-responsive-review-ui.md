# Responsive Review UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make MR navigation immediate when cached, reduce redundant GitLab reads, and keep large reviews readable at narrow window widths.

**Architecture:** Preserve the CLI client and SwiftUI observation model. Add bounded cache/fetch coordination inside ReviewsModel, then move content preparation behind an asynchronous bounded cache and adapt the list/detail layout to available width. Do not cancel mutating CLI commands when views disappear.

**Tech Stack:** Swift 6, SwiftUI, Observation, Foundation, Swift Testing; existing TypeScript CLI remains compatible.

**Spec:** `docs/superpowers/specs/2026-11-16-review-reliability-and-responsive-ui-design.md` (U1–U5).

## Global Constraints

- Node >=24; TypeScript 5.9.3; Swift tools 6.0 and Swift language mode 6; macOS >=15.
- No new runtime dependencies or network service; preserve the CLI-to-SwiftUI architecture.
- Preserve approval strictness, SHA-guarded approval, configured review concurrency, and Owner control over posting.
- Preserve version-1 JSON consumers; additions must be optional or backward compatible.
- Do not send GitLab or Teams messages during implementation verification; use fakes and local fixtures.
- Follow fast-iteration: write regression tests with each task; run the full relevant gate only before push or opening/updating an MR.

## Review Focus

- Repeated refresh clicks during slow GitLab calls must share work and keep loading indicators accurate (Task 1).
- A successful action while a read is running must invalidate that read and cause one trailing refresh (Task 1).
- Switching A → B → A while responses arrive out of order must retain the current selection and correct document (Task 1).
- Two MRs with identical update timestamps or changing diff contents must never share stale rendered lines (Task 2).
- Large content, a 760 × 480 window, Reduce Motion and keyboard/VoiceOver use must retain reachable actions and readable content (Task 2).

---

## File responsibilities and order

1. `macos/Suica/Sources/SuicaCore/Reviews.swift` continues to own selection, refresh policy and action invalidation. New `ReviewDetailCache.swift` owns only LRU/freshness bookkeeping; existing `AgentClient.swift` and CLI contracts need no protocol change.
2. New `ReviewPresentation.swift` owns content identity, asynchronous parsed blocks/diff lines, cache limits, and the small layout policy. `ReviewsView.swift` consumes prepared content and implements compact navigation. Keep the rest of the app's layout unchanged.

These two tasks can ship independently of the engine plan. Do not perform test runs after every edit; use the final delivery gate.

### Task 1: Coalesce reads and retain fresh MR details

**Files:** Create `macos/Suica/Sources/SuicaCore/ReviewDetailCache.swift`, `macos/Suica/Tests/SuicaCoreTests/ReviewDetailCacheTests.swift`; modify `macos/Suica/Sources/SuicaCore/Reviews.swift:564`, `:737`, `:769`, `macos/Suica/Sources/Suica/Window/ReviewsView.swift:26`; extend `macos/Suica/Tests/SuicaCoreTests/ReviewsTests.swift`.

**Interfaces:**
- Consumes unchanged `ReviewsClient.reviews()` and `mergeRequest(key:)`, `MergeRequestDetail`, existing fake client gates.
- Add `public enum ReviewRefreshReason: Sendable { case automatic, manual, action }`.
- Change model method to `public func refresh(reason: ReviewRefreshReason = .automatic) async`; add `public func stopRefreshing()` to prevent queued background reads after page disappearance without terminating active mutation processes.
- Keep `select(_ key: String?) async` and `loadDetail(_ key: String, keepingNotice: Bool = false) async` source-compatible; explicit `loadDetail` is a forced read.
- Add a defaulted test clock to `ReviewsModel.init(client: any ReviewsClient, now: @escaping @Sendable () -> Date = Date.init)`.
- New internal `ReviewDetailCache` stores documents and access/fetch timestamps: `init(capacity: Int = 8)`, `value(for key: String, now: Date) -> MergeRequestDetail?` (updates access order), `store(_ value: MergeRequestDetail, now: Date, protecting selectedKey: String?)`, `isFresh(_ key: String, now: Date, lifetime: TimeInterval) -> Bool`, `invalidate(_ key: String)`, `remove(keys: Set<String>)`. Limit 8 entries; protect selected entry during eviction. Mirror the cache into existing observable `details` only on real content/eviction changes.

- [ ] **Step 1: Add deterministic concurrency/cache tests using gates and an injected clock.** Tests: `overlappingRefreshesShareReads`, `actionQueuesOneTrailingRead`, `selectionSurvivesOutOfOrderReplies`, `eightFreshSelectionsReuseDetails`, `evictsLeastRecentlyUsedUnselectedDetail`, `failedReloadKeepsLastGoodDetail`. Pin assertions:

  ```swift
  #expect(await client.listCalls == 1) // three simultaneous automatic refreshes
  #expect(await client.detailCalls == ["g/p!1"])
  #expect(model.selectedKey == "g/p!2") // A's delayed result cannot select A
  #expect(model.details.count <= 8)
  #expect(model.selectedDetail == lastGood) // failed refresh
  #expect(await client.detailCalls.count == 2) // one pre-action + one trailing read
  ```

  Advance fake time through 0, 3, 6 … 27 seconds with a running review; assert one full idle-MR detail call. At 30 seconds assert a second call. For active pipeline detail use 10 seconds. Assert manual refresh bypasses freshness, and old completions cannot prune the new selection or clear its loading state.

- [ ] **Step 2: Implement `ReviewDetailCache` and coalesced list/detail task ownership.** Keep one list task and a dictionary of detail tasks keyed by MR, plus generation counters and a single trailing-force flag per key. A caller joins an eligible in-flight read rather than launches another. Only the owning generation updates errors, timestamps, loading keys or pruning. Read requests across different selections are bounded to two active detail reads; replace the queued selection request with the newest selection rather than accumulating a navigation backlog.

- [ ] **Step 3: Separate list cadence from detail freshness.** Retain `refreshSeconds` values 3/10/15/30 for list/activity updates; apply independent 30-second idle and 10-second active-pipeline detail freshness. Cache hits select synchronously before awaiting any request. Invalidate removed MRs after an authoritative successful list read; use any existing list head identity when available, otherwise rely on the time limit. Do not use local activity changes as proof the remote diff changed.

- [ ] **Step 4: Wire forced invalidation to UI actions.** Pass `.manual` from the refresh button and `.action` after approval, post, cancel, queue and discard. An action increments the detail generation before scheduling one trailing read. Automatic ticks and first appearance use `.automatic`. On disappearance, stop scheduling queued refresh work; let already running bounded reads finish without reactivating the loop. Preserve per-MR errors, approval notices and Owner action controls.

- [ ] **Step 5: Record gate commands and commit.** At the delivery gate run `swift test --package-path macos/Suica --filter 'Reviews|ReviewDetailCache'`; expected all selected tests pass. Commit affected files with `perf: coalesce review refreshes and retain recent details`.

### Task 2: Prepare content safely and adapt narrow MR pages

**Files:** Create `macos/Suica/Sources/SuicaCore/ReviewPresentation.swift`, `macos/Suica/Tests/SuicaCoreTests/ReviewPresentationTests.swift`; modify `macos/Suica/Sources/Suica/Window/ReviewsView.swift:13`, `:973`, `:1324`, `:1388`; extend `macos/Suica/Tests/SuicaCoreTests/MarkdownTests.swift`; create `docs/review-ui-performance.md`.

**Interfaces:**
- Consumes existing `DiffFile`, `DiffLine`, `MarkdownBlock`, `parseDiffLines`, `parseMarkdownBlocks`; preserve their output semantics.
- Add `public struct ReviewContentID: Hashable, Sendable` with MR key, optional head SHA, and a stable digest of file paths/diff content. Constructor `init(key: String, headSha: String?, files: [DiffFile])`. Use platform CryptoKit SHA256, not randomized `Hasher`, for content digest; compute digest during off-main preparation rather than repeatedly in `body`.
- Add `public actor ReviewPresentationCache` with `init(byteLimit: Int = 8 * 1024 * 1024)`, `diffs(key: String, headSha: String?, files: [DiffFile]) async -> PreparedReviewDiff`, `blocks(source: String) async -> [MarkdownBlock]`.
- `PreparedReviewDiff: Sendable` contains `id: ReviewContentID` and `linesByFile: [String: [DiffLine]]`. Make parsed value types Sendable where necessary using actual value members, not unchecked annotations. Cost entries by source UTF-8 bytes; never retain an individual source larger than the total budget. Bound concurrent parsing to two jobs and drop obsolete queued jobs.
- Add `public enum ReviewLayout: Equatable, Sendable { case compact, split }` and `public func reviewLayout(availableWidth: Double) -> ReviewLayout`, with compact below 900 and split at or above 900.

- [ ] **Step 1: Write identity, ordering, parsing and layout regressions.** Tests: `sameTimestampDifferentMRDoesNotReuseDiff`, `contentChangeInvalidatesSameHead`, `oldPreparationCannotReplaceSelectedMR`, `presentationCacheHonorsByteBudget`, `layoutUsesAvailablePageWidth`; assertions:

  ```swift
  #expect(idA != idB) // same timestamp, different MR key
  #expect(idBefore != idAfter) // same head, changed file text
  #expect(prepared.linesByFile == expectedLines)
  #expect(reviewLayout(availableWidth: 899) == .compact)
  #expect(reviewLayout(availableWidth: 900) == .split)
  ```

  Add Markdown fixtures covering links, fenced code, tables, task lists and a 100 KB body; asynchronous preparation must equal existing parser output. Use an internal cache-cost accessor for deterministic eviction assertions; no wall-clock unit thresholds.

- [ ] **Step 2: Implement bounded asynchronous preparation.** Move block-cache misses off the main actor into `ReviewPresentationCache`. Keep the existing inline attributed-string cache for rendering. Store prepared content in view state, reject obsolete completions with selection/generation checks, and clear old-MR content before preparing a new MR. Preserve old content only while refreshing the same unchanged identity. Represent parsing/loading separately from an empty diff.

- [ ] **Step 3: Wire diff task identity to actual inputs.** Replace `.task(id: detail.updatedAt)` with a request identity containing key, head and file values (a value comparison token can avoid hashing in `body`). Consume `PreparedReviewDiff` only if its identity still matches the active request. Cancel obsolete preparation requests cooperatively; a detached worker must check cancellation between files/blocks. Retain lazy rows, truncation notices and text selection.

- [ ] **Step 4: Implement compact list/detail navigation in `ReviewsView`.** Measure available page width outside the app's navigation sidebar. Below 900 points show the list initially; selection opens detail with a labelled Back control restoring list focus. At or above 900 show the existing 300-point list beside detail. Keep the selected key, detail tab and collapsed-file set in per-MR view state across layout switches; bound this state to the same 8 recent MRs. Use existing motion helpers and accessibility labels. Do not shrink the whole app below its existing 760 × 480 minimum.

- [ ] **Step 5: Add a reproducible local profiling procedure.** In `docs/review-ui-performance.md`, specify an injected fake ReviewsClient with 200 MR summaries, a 1,500,000-character diff budget, 100 KB Markdown, and gated 2-second reads. Record reference Mac/OS, release build and before/after traces. Measure cached selection-to-paint (target ≤100 ms), parsing on the main thread (no interval >50 ms), CLI call counts, and retained cache size. Manually verify 760 × 480 and 1280 × 800 windows, resizing with detail selected, keyboard Back/focus, VoiceOver action names, Reduce Motion, and scrolling during refresh. Run against local fixtures, never real post/approve actions.

- [ ] **Step 6: Run the final gate immediately before push/MR and commit.** Run `make test-all` and `swift build --package-path macos/Suica`; expected both exit 0. Execute the local profiling/manual checks above once and record actual results. If latency targets fail, identify the measured remaining hotspot before calling the task complete. Commit with `perf: prepare review content asynchronously and adapt narrow layouts`.

## Self-review and handoff

Coverage: U1/U2 → Task 1; U3/U4 → Task 2; U5 → deterministic tests in Task 1 and profiling in Task 2. Every Review Focus case has an owner. No new daemon endpoint, remote cache, dependency or unsafe process cancellation is required. Timing targets remain unverified until implementation and profiling.
