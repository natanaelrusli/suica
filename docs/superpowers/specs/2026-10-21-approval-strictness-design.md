# Approval without waiting, and its strictness — design

Status: asked by the Owner in chat on 2026-10-21. Extends `2026-10-20-auto-approve-default-design.md`.

## Intent

The Owner asked that when an Agent Review finds nothing new, or only Minor or Nit findings, the agent approves the MR directly, and that how strict this is can be set in the config.

## Problem

With `review.approve` on, the agent approved only after the review was posted. With `review.post: approval` (the default) a ready review waits for the Owner to post it, so a review with nothing serious left still sat in the app until the Owner pressed **Post to GitLab…**.

## Decisions

1. **No wait for a review the agent approves.** With `review.approve` on, a review that is ready to approve is posted (as `review.postAs` says) and the MR approved the moment the review is ready, whatever `review.post` is. A review that is not ready to approve keeps following `review.post`. _My call_: the review is still posted before approving, so the Author sees the Minor and Nit findings and the approval stays tied to a visible review, as before.
2. **`review.approveWhen`**, an enum, default `minor` (the behaviour so far):
   - `minor`: every finding is Minor or Nit; every open item of the `## Previous review` section names Minor or Nit and nothing more serious.
   - `nit`: the same with Nit only.
   - `clean`: no findings and no open item.

   A finding or open item without a severity counts as serious at every level, since the wording is a model's. The same setting drives the app's **Ready to approve** mark (`readyToApprove` in `suica reviews --json`).
3. _My call_: an `enum` field with titled options in the app rather than the `level` slider, whose titles and icons are made for effort.

## Not done

- No level stricter than `clean` or more lenient than `minor` (approving with a Major left).
- `review.approve: false` keeps the old flow: every review follows `review.post`, and the Owner approves with one click.
