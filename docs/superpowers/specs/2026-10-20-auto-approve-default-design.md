# Automatic approval on by default — design

Status: agreed with the Owner in chat on 2026-10-20. Extends `2026-10-20-rereview-approval-and-agent-name-design.md` and the opt-in approval of commit 4aeb75f.

## Intent

The Owner asked for the agent to approve an MR on its own once no serious findings are left, and reported that the automatic Agent Re-review after a push "sometimes does not trigger".

## Decisions (with the Owner)

1. **Approval rule.** Unchanged: a posted Agent Review that is ready to approve (every finding Minor or Nit, no Blocker, Critical or Major item of the previous review still open) approves the MR as the Owner at the reviewed commit. The Owner chose this over "zero findings only".
2. **On by default.** `review.approve` now defaults to `true` (it was `false`). Setting it to `false` brings back the one-click **Approve** in the app.
3. **Approved MRs.** Re-reviews stay limited to MRs nobody approved. The Owner's approval and the agent's approval both stop re-reviews, until GitLab removes the approval (a project that resets approvals on push).

## Why re-reviews looked unreliable (from the Owner's state database and GitLab's MR versions, 2026-10-20)

No fault was found in the queueing for MRs nobody approved. The misses came from:

- **Approval.** Two MRs the Owner approved got pushes afterwards, and their project keeps approvals on push, so no re-review was queued. This is decision 3 working as intended.
- **The wait.** `review.rereviewAfterMinutes` was 10 at the time. Twice a review was started by hand 2 to 9 minutes after the push, before the wait was over; the automatic ones that did run were queued 10 to 13 minutes after the push, as designed. It is 5 in the Owner's config now.
- **The daily cap.** From 12:23 to 13:25 every poll logged "agent review daily cap reached" (default `review.maxPerDay` 10, counted over a rolling 24 hours, first reviews first). It is 20 in the Owner's config now.

_My call_: no code change for these. Showing in the app why a re-review is waiting (the wait, the cap, an approval) would answer "why didn't it run" without the logs; that is left as a follow-up.
