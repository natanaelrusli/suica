# Why an automatic Agent Re-review has not run — design

Status: written on 2026-10-20 from a look at the Owner's report that automatic re-reviews "sometimes don't trigger". It extends Agent Re-review (`2026-10-19-agent-rereview-design.md`) and the stale-review mark (`2026-10-20-rereview-approval-and-agent-name-design.md`). Choices marked _my call_ are the builder's and can be changed.

## Intent

The Owner's state database and GitLab's MR versions showed no queueing bug. Every missed re-review had a reason the app never showed: the Owner had approved the MR (re-reviews skip approved MRs on purpose, and the Owner wants that), a review was started by hand before the `review.rereviewAfterMinutes` wait ran out, or the daily cap (`review.maxPerDay`) was reached for an hour. With no sign of any of these, the Owner pressed Review by hand. The review requests list should now say why the automatic re-review has not run.

## Goals

- For an MR whose head moved past its last posted Agent Review, the row says why no automatic Agent Re-review has run yet: waiting after the last push (and when it is due), held by the daily cap, approved, or a draft.
- The reasons follow the queue's own rules, so the list cannot disagree with what the agent does.

## Non-goals

- Changing when re-reviews run. Approved MRs stay skipped.
- Saying when the daily cap frees a slot (_my call_: it needs the time of the oldest automatic review in the window; add it when the plain reason is not enough).
- A reason for a head already queued once whose review failed, was skipped, discarded or cancelled; it is not retried on its own, and the row's review status already shows how it ended.
- Showing a reason while `review.auto` is off: then no re-review is automatic.

## Behaviour

`rereviewWaiting` in `src/agent-rereview.ts` sits next to `planRereviews` and runs it, so the head tracking, the wait and the "moved past the posted review" rule are the same code (`movedPastPosted` is shared). An MR gets a reason only when its head is known and not already queued, its newest posted-or-discarded review was posted at another commit, and no review is open (queued, running, ready or posting). Then, in this order:

1. `approved`: the Owner's reviewer state is APPROVED (by hand, or by the agent approving as the Owner), the same check `queueAutomaticReviews` applies.
2. `draft`.
3. `waiting` with `dueAt` (epoch ms): not in `planRereviews`' due list, so the wait after the last push has not run out. A head that moved since the agent's last poll counts as pushed now, as the next poll will record it.
4. `daily-cap`: due, but automatic reviews in the last 24 hours reached `review.maxPerDay` (`dailyCapReached`, shared with the queue).

A due MR under the cap gets no reason: the next poll queues it.

`suica reviews --json` reads the tracking the agent saved at its last poll (`store.loadReviewHeads`) through `rereviewWaitingReasons` in `src/agent-review.ts` and adds `rereviewWaiting` (`{reason, dueAt?}` or null) to each MR (`contracts/reviews.v1.json`). The app decodes it (absent from an older CLI means none) and shows one grey line with a clock on the row: "Auto re-review due at 15:20", "Auto re-review held: daily review cap reached", "No auto re-review: approved" or "No auto re-review while it is a draft". An unknown reason from a newer CLI shows nothing.

## Risks

- The list reads the tracking as of the agent's last poll. Between polls, `dueAt` for a head that just moved is an estimate (now plus the wait).
- When first reviews use the last slots under the cap, a due re-review waits without a `daily-cap` reason until the cap is actually reached.
