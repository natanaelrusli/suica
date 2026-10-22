# Approval recheck of reviewed merge requests — design

Status: asked by the Owner on 2026-10-22 ("If there's reviewed merge requests, poll and trigger agents to check if there's any MR that are ready to approve but have not been approved"). Decided with the Owner when asked: approve on GitLab as the Owner, read the posted review together with the MR's discussion, check on every poll, and apply it to any posted Agent Review (a first review too). Choices marked _my call_ are the builder's.

## Intent

The approval judge (`2026-10-21-approval-judge-design.md`) decides once, right after a review is written, from the review alone, and an approval follows only a clean re-review (`2026-10-20-rereview-approval-and-agent-name-design.md`). What happens afterwards in the MR's threads never changes that: an Author who explains that a Major is an accepted risk, a thread resolved with a reason, or the Owner's new `review.approveRules` leave the MR on **Reviewed**, unapproved, until someone looks again.

## Behaviour

1. **Switch.** Runs while `review.approve` is on and `review.approveBy` is `agent` (the discussion needs a model to read). _My call_: no new key; turning `review.approve` off stops it.
2. **Which MRs (each poll).** Every MR waiting for the Owner's review (`reviewRequested`) that is not a draft, whose Owner state is not `APPROVED` or `REQUESTED_CHANGES` (_my call_: changes the Owner asked for are theirs to lift), whose newest posted-or-discarded Agent Review is posted, not approved, has a body and covers the MR's current head and description, and which has no review queued, running, ready or being posted. This is the **Reviewed** tab's rule for an MR with a posted Agent Review.
3. **What the agent reads.** The judge's prompt as before (`review.approveWhen` as the bar, then `review.approveRules`), plus the MR's discussion: every thread, resolved or not, with each note's author and text, oldest first, system notes left out, as untrusted data. The prompt says the code has not changed since the review, so a reply saying something is fixed does not fix code; an explanation, an accepted risk, a decision or a resolved thread can count. Bounded: each note up to 1,500 characters and the whole discussion up to 40,000, newest threads kept (_my call_).
4. **Every poll.** Each candidate is checked on every poll, one at a time, beside the poll loop; a new poll does not start another round while one runs. _Accepted by the Owner_: one model call per candidate per round (low effort, 5-minute timeout, tokens under the purpose `approve`).
5. **Approve.** When the verdict approves, the MR is approved as the Owner at the reviewed commit (`approveMergeRequest`, so a push since is refused with 409), the Owner's own threads are resolved as after a re-review approval, and the row records `approved`, the verdict and a note ("Approved as you after rechecking the review and discussion at commit …"). GitLab then reports the Owner as `APPROVED`, so the MR leaves the round and the existing `notice.approved` Review Notice follows through Teams as for any approval.
6. **Not ready.** Nothing is written: the verdict is logged (`approval rechecked`, with whether it approves) and the MR is checked again on the next poll. A failed judge fails closed, as before.

## Constraints

- GitLab is written only by approving at the reviewed commit and resolving the Owner's own threads, as today.
- Logs carry no titles, names or review text.
- No contract or app change: the app already shows the approval through the Owner's state and the row's note.

## Tests

- Unit: the candidate rule (every case of rule 2), the discussion text (system notes left out, resolved marks, the bounds), the prompt with and without a discussion.
- Unit with fakes: a round approves a ready MR and records it, leaves an unready one alone, fails closed, and skips a round while one runs.
