# Overview widgets and a taller menu bar panel — design

Status: written from the Owner's request on 2026-10-20 ("Improve the Overview UI, add more widget and interactive widgets as a shortcut to functions" and "Improve the menubar panel, it is too small and the UI is not user friendly"). The Owner picked the layouts from mockups: the taller panel with tabs (Option A) and the Overview with a quick-action bar, six tiles and action widgets. Choices marked _my call_ are the builder's and can be changed. Vocabulary is in `CONTEXT.md`.

## Intent

The panel's "Needs your attention" and "Recent" sections are too small to read or act on: the panel is 400 pt wide, as tall as its content, and Recent is a collapsed disclosure. The Overview is mostly read-only: four tiles above settings cards, with Restart agent and Pause buried in those cards. The Owner wants both screens to be places to act from, not only to look at.

## Goals

### Menu bar panel (Option A)

- 460 pt wide and a fixed 640 pt tall (_my call_), so the lists have room even with one or two rows.
- Header: app icon, name, Running/Paused with the status light, and "polled N ago" when the last poll is known; Refresh on the right.
- Quick actions, one row of four buttons replacing the three counters: **Pause/Resume**, **Reviews** with the number of review requests, **Statistics**, **Open Suica** (_my call_ on the four). Reviews and Statistics close the panel and open the window on that page.
- An Agent Review strip, shown only while a review runs: what it reviews, CLI, model, for how long, how many are queued, and **Cancel**. Cancel stops that running review (the `review cancel` command the Agent review tab uses).
- A segmented control, **Needs you · n** and **Recent · n**, under it; the chosen list fills the rest of the height and scrolls. Rows are today's `OutboxItemRow`, unchanged, so Send… still asks first. "n more hidden" stays under Needs you.
- The panel opens on Needs you when something is waiting (the badge count is above zero) and on Recent otherwise (_my call_). The choice made by hand holds while the panel stays open.
- Footer: Open Suica ⌘O, Appearance, Quit. Pause moves up into the quick actions; with the quick-action row hidden (below) Pause/Resume stays in the footer, so it is never gone (_my call_).
- Teams disabled: the tabs are replaced by today's "Teams is off" line.
- Appearance → "Show counters in the popover" now shows or hides the quick-action row (_my call_: it is the row that replaced the counters, and the setting is kept rather than removed).

### Overview

- **Quick-action bar** at the top: **Pause/Resume polling**, **Restart agent**, **Refresh**, **Open logs** (reveals the logs path in Finder), **Edit config** (opens Configuration).
- **Six tiles**: Agent, Polling (last poll), To review, **Ready to approve** (new), Needs you, **Tokens today** (new, last 24 h from usage). Each tile with a page behind it opens it: To review and Ready to approve open Reviews, Needs you opens Messages, Tokens today opens Token usage.
- **Waiting for your review** widget: at most five rows in all, one per MR, drafts left out (_my call_). Order: Ready to approve first, then Changed since review (`changedSinceReview` set), then MRs waiting for the Owner (state UNREVIEWED, the rule of the Reviews page's Waiting group), each group in the list's order; an MR in more than one group appears once, in the first. The Ready to approve tile counts every non-draft MR with `readyToApprove`, so it matches the widget's first group. Each row has one action: **Agent review** when one is offered (`offersReview`), **Re-review** when `offersRereview`, otherwise **Open**. Every row title opens the MR on the Reviews page. "All n →" opens Reviews. Approve stays on the Reviews page: it needs the MR's details and head commit.
- **Agent review** widget: the running review with **Cancel**, the queue with **Cancel** per row, and reviews ready to post with **Post…** (the same confirmation as the Agent review tab: Post inline / Post as one comment / Cancel). The posting, post-as and model pickers move under a **Settings** disclosure in this widget, collapsed by default (_my call_).
- **Needs you** widget: the first three Teams messages waiting for the Owner as `OutboxItemRow` (Send… asks first, Skip), "Messages →" opens Messages. Hidden while Teams is off.
- **Last 7 days** widget: bars of review requests per day from the stats document, a line with the week's review requests, nudges sent and poll success rate, "Statistics →". **Tokens** line under it: 24 h, 7 d, 30 d totals, "Usage →".
- **System** disclosure at the bottom, collapsed (_my call_): Agent (with Restart), Model CLI, Polling intervals and the last poll's failure, Files, as today's cards.
- Two columns when wider than 860 pt as today; one column otherwise.

## Non-goals

- Approving from the Overview or the panel.
- New CLI commands or contract changes: everything shown is in `state`, `status --json`, `stats`, `usage` and `reviews --json` today.
- Making the panel resizable or remembering the chosen tab across openings.

## Data and models

- The Overview gets the app's `ReviewsModel` (shared with the Reviews page) and refreshes its list when shown, and every 15 s while a review is active, as the Reviews page does. A list that failed to load shows the error inside the widget; the rest of the page is unaffected.
- `ReviewsModel` gains `cancelAgentReview(id:key:)` so the Overview and the panel can cancel the review they show (from `status`/`state`, which carry the review's id and MR key) without the list being loaded; the existing key-based cancel calls it.
- "Opens the MR on the Reviews page" selects the key in `ReviewsModel`, then navigates.
- The panel gets `WindowModel` and `ReviewsModel` too. On opening it refreshes the menu state as today and reads `status --json` once for the last poll (`WindowModel.refreshStatus()`, _my call_: one document rather than the three a window refresh reads). Cancel goes through `ReviewsModel` and refreshes the menu state afterwards.
- Pure logic lives in `SuicaCore` with tests: the panel's opening tab, the review widget's rows and their action, ready-to-approve and ready-to-post counts, the week's summary figures.

## Tests

- `MenuModelTests`/new tests: opening tab is Needs you with a waiting message and Recent without one.
- `ReviewsTests`: cancel by id works without a loaded list and reports the outcome; the widget's row selection and action (agent review, re-review, open) and ordering; ready-to-approve and ready-to-post counts.
- Statistics summary: sums over the last seven days and the poll success rate (no polls → no rate).
- The views are checked by building and running the app and looking at both screens; there are no view tests in this package.
