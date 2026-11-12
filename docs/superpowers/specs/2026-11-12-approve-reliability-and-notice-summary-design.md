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

- Judge prompt: only the evidence-only half, so the approval recheck applies it to reviews already posted. A partly fixed item that only waits on a pipeline result counts as Minor when the head pipeline's status is SUCCESS and keeps its severity otherwise; one whose code is done and that only waits on a device or manual run counts as Minor whatever the pipeline says. Only the recheck passes the head pipeline's status (`mr.pipeline`, a single uppercase word, else the line is left out); the first judge, right after a review, gets none and cannot lift a CI item. No status, an odd one or a judge error means not approved. General regrading stays in the re-review prompt, where the model has the code. A sample of 20 held reviews replayed once each through sonnet, without the discussion: a broader wording flipped 9, including 334 (leaked webhooks) and 499 (a connection per write). The evidence-only wording flips 5 (392, 390, 388, 386, 198, all a CI job or dev run not yet shown), and 334, 499, 460 and the Blockers 507, 490 and 494 stay held. Replay of the pipeline-aware wording on a copy of the live DB (13 runs, one each, sonnet, without the discussion): with SUCCESS, 392, 390, 388, 386 and 198 approve and 507, 490, 494, 334 and 499 stay held; with RUNNING, 392, 390 and 388 stay held.
- Re-review prompt: grade a partly fixed item by what is still missing, not by its old severity. An item whose code is done and that only lacks evidence (a pipeline result, a device or manual run) is partly fixed at Minor. The line names only that severity, so the judge and the `rules` parser read it the same way. Items that are not fixed keep their severity, and the bar is not loosened.
- Teams: a re-review that did not approve is announced once 30 minutes pass with no newer review of the MR (`REREVIEW_NOTICE_QUIET_MS`). A newer review replaces the waiting one, because only the latest posted review is announced. While it waits, its comments do not go out as `notice.comments`. The text adds how many earlier items are still open, so the skipped rounds are not lost. `notice.reapproved` and `notice.approved` still go out at once; an approval during the wait drops the waiting notice. An approved first review sends only `notice.approved` (it sent findings and approved in the same second for one MR 28 times).
- Teams: notices merge by recipient, variant and ticket like nudges. In a merged notice each bullet carries its own MR's findings, and `review.findings` reads "hasilnya per MR di bawah".
- Replayed over the outbox, a 30-minute gap alone would cut sent re-review notices from 176 to about 125 (15 minutes: 147, 60 minutes: 114). The ticket merge is the bigger cut on days like 2026-11-12.

## My calls

- 30 minutes is a constant, not a setting (shortcut comment in `plan.ts`).
- Evidence-only gaps count as Minor rather than fixed, so they stay visible in the review.
- A missing CI result counts as Minor only when the head pipeline is SUCCESS, and only the recheck (which runs on every poll) passes the status, so an MR whose only open item is CI evidence is approved on the first poll after its pipeline turns green. A project without CI (`mr.pipeline` null) keeps such an item held. Approval is not merge; that GitLab's pipeline check still guards the merge is an assumption about each project's settings.
- `postedAt` is the review row's `updated_at`, so a later write to the row restarts the 30 minutes. In the outbox only 9 of 339 notices came more than 10 minutes after that time.
