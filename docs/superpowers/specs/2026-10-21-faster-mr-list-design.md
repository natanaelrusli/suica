# Faster merge request list

## Problem

The review requests page took about 1.5 to 3 seconds to fill. `suica reviews --json` spent nearly all of it in one GitLab GraphQL call (local work is about 15 ms), and the app asked for the selected MR's detail only after the list had come back, so the two GitLab round trips added up.

## Design

- **The list leaves notes out of its query.** `notes(last: 50)` on every MR was the costly part for GitLab: the same query without it answered in about 0.33 s instead of 0.76 s (median of 12 interleaved runs against repo.madhani.one). The list never shows notes; only the poller reads them (Activity Alerts, Finding Threads), and its query is unchanged. `fetchSnapshot(run, { notes: false })` leaves every MR's `notes` empty.
- **The selected MR loads alongside the list.** A refresh with an MR already selected starts that MR's detail at once instead of after the list. When the refresh selects a different MR (the old one left the list, or nothing was selected yet), that one loads after the list as before.
- **No cache of the daemon's snapshot** (my call): reading the poller's last snapshot would make the page instant, but up to a poll interval stale, and the page is where the Owner checks the current state before approving.

## Result

`suica reviews --json`, 10 interleaved runs each: median 0.83 s before, 0.41 s after (slowest 3.19 s before, 1.20 s after), with byte-identical output. A refresh of the page with an MR selected now waits for the slower of the list and the detail (about 0.6 s), not their sum.

## Code

`snapshotQuery` and `fetchSnapshot` in `src/gitlab.ts` (tested in `test/gitlab-notes.test.ts`), the `reviews --json` command in `src/cli.ts`, and `ReviewsModel.refresh` in `SuicaCore/Reviews.swift` (tested in `ReviewsTests`). The contract is unchanged.
