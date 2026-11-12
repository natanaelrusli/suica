# Approval reliability and one Teams notice per re-review burst

## Problem

1. Suica held approval on MRs whose review had no findings, or only Minor and Nit ones.
2. An Author got one Teams chat per Agent Re-review. One MR (skill-pack !93) sent 12 chats in a day.

## Evidence (live state DB, 2026-11-12)

- The approval judge was never stricter than the rules parser. No review the judge approved was left unapproved.
- 139 posted reviews were held with no Blocker, Critical or Major finding (about 30 of them from before the judge existed). Every hold since the judge shipped came from an open `## Previous review` item, not from a finding. 54 of them said "partly fixed".
- A partly fixed item kept its first severity on every later re-review. Some items were only waiting for evidence that a code reading cannot see, such as "SQL never executed in CI" or "device walk not done" (review 392: "Findings: None", held by a Major "partly fixed" because no pipeline result exists for the head).
- Each posted review queued its own `findings:<reviewId>` notice. The notice went out within seconds because the review's inline comments skip the debounce.
- Notices were never merged by ticket (`groupForMerge` took only nudges). On 2026-11-12 one Author got 35 notices about 16 MRs of ticket 001M-124; 14 were queued in the same second.

## Change

- Judge prompt: the same rule, so the approval recheck applies it to reviews already posted. Replayed through sonnet on 20 held reviews: 9 flip to approve (7 evidence-only gaps such as an integration job not yet run, 1 accepted shortcut, 1 doubtful: 334, leaked webhooks with only the planner key and date missing); Blockers 507, 490 and 494 stay held.
- Re-review prompt: grade a partly fixed item by what is still missing, not by its old severity. An item whose code is done and that only lacks evidence (a pipeline result, a device or manual run) is partly fixed at Minor. The line names only that severity, so the judge and the `rules` parser read it the same way. Items that are not fixed keep their severity, and the bar is not loosened.
- Teams: a re-review that did not approve is announced once 30 minutes pass with no newer review of the MR (`REREVIEW_NOTICE_QUIET_MS`). A newer review replaces the waiting one, because only the latest posted review is announced. While it waits, its comments do not go out as `notice.comments`. The text adds how many earlier items are still open, so the skipped rounds are not lost. `notice.reapproved` and `notice.approved` still go out at once; an approval during the wait drops the waiting notice.
- Teams: notices merge by recipient, variant and ticket like nudges. In a merged notice each bullet carries its own MR's findings, and `review.findings` reads "hasilnya per MR di bawah".
- Replayed over the outbox, a 30-minute gap alone would cut sent re-review notices from 176 to about 125 (15 minutes: 147, 60 minutes: 114). The ticket merge is the bigger cut on days like 2026-11-12.

## My calls

- 30 minutes is a constant, not a setting (shortcut comment in `plan.ts`).
- Evidence-only gaps count as Minor rather than fixed, so they stay visible in the review.
- A missing CI result counts as Minor whatever the head pipeline says; the judge does not see the pipeline. Approval is not merge, and GitLab's pipeline check still guards the merge.
- `postedAt` is the review row's `updated_at`, so a later write to the row restarts the 30 minutes.
