# Approval reliability and one Teams notice per re-review burst

## Problem

1. Suica held approval on MRs whose review had no findings, or only Minor and Nit ones.
2. An Author got one Teams chat per Agent Re-review. One MR (skill-pack !93) sent 12 chats in a day.

## Evidence (live state DB, 2026-11-12)

- The approval judge was never stricter than the rules parser. No review the judge approved was left unapproved.
- 139 posted reviews were held with no Blocker, Critical or Major finding. Every hold since the judge shipped came from an open `## Previous review` item, not from a finding. 54 of them said "partly fixed".
- A partly fixed item kept its first severity on every later re-review. Some items were only waiting for evidence that a code reading cannot see, such as "SQL never executed in CI" or "device walk not done" (review 392: "Findings: None", held by a Major "partly fixed" because no pipeline result exists for the head).
- Each posted review queued its own `findings:<reviewId>` notice. The notice went out within seconds because the review's inline comments skip the debounce.

## Change

- Re-review prompt: grade a partly fixed item by what is still missing, not by its old severity. An item whose code is done and that only lacks evidence (a pipeline result, a device or manual run) is partly fixed at Minor. The line names only that severity, so the judge and the `rules` parser read it the same way. Items that are not fixed keep their severity, and the bar is not loosened.
- Teams: a re-review that did not approve is announced once 30 minutes pass with no newer review of the MR (`REREVIEW_NOTICE_QUIET_MS`). A newer review replaces the waiting one, because only the latest posted review is announced. While it waits, its comments do not go out as `notice.comments`. The text adds how many earlier items are still open, so the skipped rounds are not lost. `notice.reapproved` and `notice.approved` still go out at once.

## My calls

- 30 minutes is a constant, not a setting (shortcut comment in `plan.ts`).
- Evidence-only gaps count as Minor rather than fixed, so they stay visible in the review.
- Reviews already posted keep their old grading until the next push re-reviews them.
