# Search on Messages and Review requests, and the Overview and Statistics entrance — design

Status: written on 2026-10-20 from the Owner's request to "make a search feature in messages and review requests" and to "fix the animation when opening statistics and overview page". Choices marked _my call_ are the builder's and can be changed.

## Search

### Intent

The Messages page lists every recent message and Review requests every open MR where the Owner is a Reviewer. Finding one person's messages or one MR means scrolling. A search field narrows both lists.

### Goals

- A toolbar search field on each page, as on Logs and Configuration: **Search messages** and **Search review requests**.
- A row is shown when every word typed appears somewhere in its texts, ignoring case and accents (`localizedStandardContains`, the rule Configuration's search uses). An empty or blank query shows everything.
- Messages match on what their row shows: the kind as labelled ("Nudge", "Re-review", …), the recipient, the MR key and title, the outcome text and the message text.
- MRs match on the title, the key, the author's name and username, and every Reviewer's name and username.

### Non-goals

- Searching beyond what the page has loaded: messages hidden behind "and N more" are not searched, and nothing asks GitLab or the agent. No CLI or contract change.
- Fuzzy matching, highlighting the matched words, or a ⌘F shortcut (Logs and Configuration have none either).

### Behaviour

**Messages** searches the selected tab only, so the tabs keep their meaning (_my call_). While searching, a section without a match is hidden, so "Nothing is waiting for you" does not show under a search that only matched recent messages. With no match in the tab, the page says "No messages match “…”." and, when the other tab has matches, "N matches in Others' MRs." (or Your MRs). A `suica://message/<id>` link clears the search, since it could hide the message it opens. The search is the page's own state: it is empty each time the page opens.

**Review requests** keeps the groups (Waiting for you, You reviewed, Drafts) and their order, counts only the matches in each header and drops a group left empty. "Nothing is waiting for you" is not shown while searching. With no match, the list says "No review requests match “…”.". The selected MR stays open on the right even when the search hides its row (_my call_: closing it while typing would lose the reader's place).

The matching lives in `SuicaCore/Search.swift` (`Search.matches`, `OutboxItem.matches`, `ReviewSummary.matches`, `ReviewListDocument.sections(matching:)`) and is unit-tested in `SearchTests.swift`.

## Overview and Statistics entrance

### Cause

Overview and Statistics are the only pages that change between one and two columns with the window width (`tracksWidth`). Each starts as `wide = false` and learns its width from `onGeometryChange`, whose first call came in through `withMotion(Motion.layout)` like every later one. Every time either page opened, it ran the 0.35 s change from the narrow layout to the wide one on top of the page's own entrance: for a moment the narrow cards faded out under the wide ones, the tiles regrouped from two columns to three (or four), and a ghost of the chart lingered at the bottom.

### Fix

The first width is applied in a transaction with animations disabled. Later changes, such as the sidebar opening or the window being resized, still animate with `Motion.layout`. Frame captures before and after (30 ms apart, switching from Messages) show the page now entering already in its wide layout. There is no automated test: the app target's views are not under test, and the harness capture is the evidence.
