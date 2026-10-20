# Statistics pages: people and slowest approvals — design

Status: written on 2026-10-20 from the Owner's request for a sub-menu under Statistics with "the user I review the most", "the user that reviews my MR the most" and "the longest time until an MR is approved". The Owner chose the approval clock: their own MRs, from opening to the first approval. Choices marked _my call_ are the builder's and can be changed.

## Intent

Statistics shows counts and turnaround times, but not who the Owner works with. Three pages under Statistics answer who the Owner reviews most, who reviews the Owner most, and which of the Owner's MRs waited longest for an approval.

## Goals

- Three rows nested under Statistics in the sidebar, as Configuration's categories are: **People you review**, **Your reviewers**, **Slowest approvals**. Statistics itself keeps its page.
- Each covers the last 90 days, the history's retention (_my call_), and lists at most 10 rows (_my call_).
- The figures come from `suica stats`, which still reads only the config and the state database.

## Non-goals

- Reconstructing history. Rows recorded before this version have no MR author, and earlier approvals were never timed; those two pages fill from this version on. **Your reviewers** uses the Reviewer usernames the history already has.
- Asking GitLab for closed MRs or approval times.
- A period picker, medians of the approval time, or approvals of MRs the Owner reviews.

## Behaviour

**People you review** counts `owner-reviewed` history rows, which now carry the MR author's username (they had none). **Your reviewers** counts `reviewer-reviewed` rows, which already carried the Reviewer. Each counts distinct MRs per person, most first, ties by name. A row without a username (from before this version) is left out.

**Names**: GitLab usernames can be opaque (numbers), so the pages show display names. Every poll stores the name of each author and Reviewer on the open MRs in `person_name` (username → name, as last seen). The table is never pruned: it holds one row per colleague (_my call_, rather than a name column per history row, so rows recorded before this version get names too once their people appear on an open MR). Someone no open MR shows (a Reviewer of an MR merged weeks ago) is looked up after each successful poll: up to 10 history usernames without a name, the most recently active first, one `users?username=` REST call each (_my call_: 10 keeps a poll short; the Owner's 7 unnamed Reviewers were all named on the first poll). A user GitLab no longer knows is stored with the username as the name, so it is not asked for again. A failed lookup logs `names not looked up` with the failure kind and is tried on the next poll; it never fails the poll. The app shows `Full Name @username`, or the username alone while the name is not known.

**Slowest approvals**: when a poll sees a Reviewer of one of the Owner's MRs change to APPROVED (the `reviewer-state` event, which already skips drafts, MRs seen for the first time and the Owner), `first_approval` gets a row with the MR's title, URL, `createdAt` and the approver, stamped with the poll's time. `INSERT OR IGNORE` keeps only the first approval of an MR, also after an unapproval. An MR whose `createdAt` is missing or unparsable is left out. The page lists the rows approved in the last 90 days, longest from opening first; a negative wait counts as 0. Rows older than 90 days are dropped with the poll log.

Opening time is GitLab's `createdAt`, so time spent as a draft counts (_my call_: it matches what GitLab shows; the Owner can ask for "since ready" later). The approval time is the poll that saw it, so up to one poll interval late.

## Contract

`contracts/stats.v1.json` gains `peopleIReview` and `peopleWhoReviewMe` (`{ username, name, mergeRequests }`) and `slowestApprovals` (`{ mrKey, title, url, openedAt, approvedAt, minutes, approver: { username, name } }`). The version stays 1: the fields are additions, and the app decodes them as optional, so an older agent's document still loads and the pages show "Not enough data yet".

## Storage

Schema 13 adds `first_approval` (keyed by MR, indexed by `approved_at`) and `person_name`. `history_event` is unchanged; `owner-reviewed` rows now fill `username`. Going back to schema 12 by hand leaves both tables in the file.

## App

`SidebarItem` gains `.statistics(StatisticsPage)`; the window title shows the page after "Statistics", as it does for Configuration's categories. `StatisticsPageView` shows one card per page with a one-line explanation: a ranked list with a bar per person for the two people pages, and for approvals the MR title (a link, opened only when it is http or https), its short key, when it was opened, who approved first and the wait (minutes up to a day, then days and hours). Names and titles are cleaned with `DisplayText.clean` like every text written by others.
