# Overview widgets and taller panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the menu bar panel a 460×640 tabbed panel with quick actions, and turn the Overview into a page of action widgets.

**Architecture:** Selection and counting rules live in `SuicaCore` (tested); the SwiftUI views in `Sources/Suica` only lay them out and call existing model actions. The app's one `ReviewsModel` and `WindowModel` are passed to the panel and the Overview.

**Tech Stack:** Swift 6, SwiftUI (macOS 14), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-20-overview-widgets-and-panel-design.md`

## Global Constraints

- No new CLI commands and no contract changes (`contracts/*.v1.json` untouched).
- All user-visible strings go in `SuicaCore/Copy.swift`.
- Panel: `.frame(width: 460, height: 640)`.
- Overview: two columns above 860 pt (`tracksWidth(above: 860, …)`).
- Swift tests: `cd macos/Suica && swift test`.

## Review Focus

- Reviews list not loaded or failed: the Overview's review widget shows the error or a loading line; tiles show "–"; the rest of the page works. (Task 3 view; the rows function returns `[]` for an empty list — test in Task 1.)
- Teams off (`state.teams == nil`): the panel shows the Teams-off line instead of tabs; the Overview hides Needs you. (Task 2/3 views.)
- Stats with fewer than seven days or no polls: the week summary uses what exists and the poll rate is nil (test in Task 1).
- Cancel pressed for a review that finished meanwhile: the CLI's outcome is shown as the banner, nothing crashes (`cancelAgentReview(id:key:)` reports the code — test in Task 1).
- `me` missing from an older CLI: no MR can be told to wait for the Owner; every non-draft MR counts as waiting (test in Task 1).

---

### Task 1: Core rules

**Files:**
- Create: `macos/Suica/Sources/SuicaCore/Shortcuts.swift`
- Modify: `macos/Suica/Sources/SuicaCore/Reviews.swift` (`ReviewsModel.cancelAgentReview`), `macos/Suica/Sources/SuicaCore/WindowModel.swift` (`refreshStatus`)
- Test: `macos/Suica/Tests/SuicaCoreTests/ShortcutsTests.swift`, `ReviewsTests.swift`, `WindowTests.swift`

**Interfaces (Produces):**
- `public enum PanelTab: Hashable, Sendable { case needsYou, recent; public static func opening(badgeCount: Int) -> PanelTab }`
- `public enum ReviewShortcutAction: Sendable { case agentReview, rereview, open }`
- `public enum ReviewShortcutReason: Sendable { case readyToApprove, changed, waiting }`
- `public struct ReviewShortcut: Identifiable, Equatable { mr: ReviewSummary; reason; action; id = mr.key }`
- `extension ReviewListDocument { func shortcuts(limit: Int = 5) -> [ReviewShortcut]; var readyToApproveCount: Int; var readyToPost: [ReviewSummary] }`
- `public struct WeekSummary: Equatable { days: [DayStats]; reviewRequests: Int; nudgesSent: Int; pollSuccess: Double? }` and `extension StatsDocument { var week: WeekSummary }` (last seven entries of `days`; `pollSuccess` = ok / (ok + failed) of `polls7d`, nil when zero).
- `ReviewsModel.cancelAgentReview(id: Int, key: String) async` (busy-guards on key, sets `agentBanner`, refreshes the list); the key-based cancel calls it.
- `WindowModel.refreshStatus() async` (reads `status` alone; keeps the last good one on failure).

- [ ] **Step 1: Write failing tests**: `opening(badgeCount: 0) == .recent`, `opening(badgeCount: 2) == .needsYou`; `shortcuts` orders ready → changed → waiting, drops drafts, lists an MR once, caps at `limit`; action is `.rereview` when `offersRereview`, `.agentReview` when `offersReview`, else `.open`; empty list → `[]`; without `me` non-draft MRs are `.waiting`; `readyToApproveCount` skips drafts; `readyToPost` holds MRs whose `agentReview.isReady`; `week` with 3 days sums those 3, with `polls7d` 0/0 gives nil, 99/1 gives 0.99; `cancelAgentReview(id: 7, key: "k")` with no list loaded records `cancel 7` and sets the banner; `refreshStatus` stores the status and keeps it after a failure.
- [ ] **Step 2: Run `swift test`** — new tests fail to compile.
- [ ] **Step 3: Implement** the interfaces above.
- [ ] **Step 4: Run `swift test`** — all pass.
- [ ] **Step 5: Commit** `feat: add the rules behind the Overview widgets and the panel tabs`.

### Task 2: Menu bar panel

**Files:** Modify `Sources/Suica/MenuView.swift`, `Sources/Suica/SuicaApp.swift`, `Sources/SuicaCore/Copy.swift`.

**Consumes:** `PanelTab.opening`, `ReviewsModel.cancelAgentReview(id:key:)`, `WindowModel.refreshStatus()`.

- [ ] **Step 1:** `MenuView` takes `window: WindowModel` and `reviews: ReviewsModel`; `SuicaApp` passes them.
- [ ] **Step 2:** Layout per spec: header with "polled N ago" from `window.status?.lastPoll`; quick-action row of four tiles (Pause/Resume, Reviews n, Statistics, Open Suica) shown when `settings.showsPopoverCounters`; running-review strip with Cancel (`reviews.cancelAgentReview(id:key:)` then `model.refresh()`); `Picker(.segmented)` Needs you · n / Recent · n with `@State tab` set from `PanelTab.opening` in `.task`; the list fills the remaining height in a `ScrollView`; footer with Pause only when the quick-action row is hidden.
- [ ] **Step 3:** Update `Copy.popoverCounters` to describe the quick-action row.
- [ ] **Step 4:** `swift build` succeeds. Commit `feat: make the menu bar panel taller with tabs and quick actions`.

### Task 3: Overview widgets

**Files:** Modify `Sources/Suica/Window/OverviewView.swift`, `Sources/Suica/Window/MainWindow.swift`, `Sources/SuicaCore/Copy.swift`.

**Consumes:** everything from Task 1.

- [ ] **Step 1:** `OverviewView` takes `reviews: ReviewsModel`; refreshes it in `.task` and every 15 s while `hasActiveAgentReview`.
- [ ] **Step 2:** Quick-action bar, six tiles, Waiting for your review, Agent review (with Settings disclosure holding today's pickers and the auto-post confirmation), Needs you (first three `OutboxItemRow`), Last 7 days + Tokens, System disclosure holding today's Agent, Model CLI, Polling and Files sections. Post… uses the same confirmation as the Agent review tab.
- [ ] **Step 3:** `swift build`, `swift test` pass. Commit `feat: turn the Overview into widgets with shortcuts`.

### Task 4: Docs and check

- [ ] README's menu bar app section describes the panel and Overview; run the app, look at both screens; commit `docs: describe the Overview widgets and the tabbed panel`.
