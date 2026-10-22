# A posted Agent Review moves an MR to Reviewed

## Problem

The Merge requests page put an MR in **Waiting** while the Owner's GitLab state was `UNREVIEWED`.
Posting an Agent Review as the Owner leaves that state unchanged, so a reviewed MR stayed in
**Waiting** until the Owner approved it.

## Rule

`ReviewListDocument.isWaiting` decides **Waiting** for a non-draft MR:

1. Approved by the Owner: never waiting (**Approved**).
2. Changed since the agent's posted review (`changedSinceReview`): waiting, so it needs a re-review.
3. Otherwise waiting while the Owner's state is `UNREVIEWED` and the newest Agent Review is not `posted`.

Everything else is **Reviewed**. Without `me` every MR waits, as before.

My call: the Overview tally and the **Waiting for your review** shortcuts use the same rule, so
the counts match the tabs. A re-review that is queued, running or ready after a posted one counts
as waiting until it is posted, since the Owner still has something to do.
