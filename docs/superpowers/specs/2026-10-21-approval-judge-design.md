# Approval decided by an agent — design

Status: asked by the Owner in chat on 2026-10-21. Extends `2026-10-21-approval-strictness-design.md`.

## Intent

The Owner saw Agent Reviews with 0 findings that the agent did not approve, and asked that an AI agent read each review and decide to approve the MR when only Minor and Nit problems are left, with the strictness adjustable by rules.

## Why 0-finding reviews were not approved

Every such review on 2026-10-21 (ids 61, 64 and 67 in the state database) was a re-review. Its `## Findings` section was empty, but its `## Previous review` section still had items of the earlier review that were not fixed or only partly fixed, and at least one of them was a Major (61: three Majors; 64: a Vault override, partly fixed; 67: a write-capable token the Author calls an accepted risk). `isReadyToApprove` counts open Previous items like findings, so a Major left open holds up the approval at every `review.approveWhen` level. The rule worked as written: "0 findings" only meant no new findings.

What the rule cannot do is weigh what the review says about an item: a Major the Author documents as an accepted risk, a severity written in a way the parser does not read, or the Owner's own exceptions.

## Decisions

1. **`review.approveBy`**, an enum, default `agent`:
   - `agent`: once a review is written, the same model CLI runs again, without tools, on the review alone and answers whether the MR is ready to approve, with a one-line reason.
   - `rules`: the parser decides, as before (`isReadyToApprove`).
2. The judge applies `review.approveWhen` as its bar (`minor`, `nit` or `clean`), and **`review.approveRules`**, a list of the Owner's own rules, one per line (for example "A Major the Author documents as an accepted risk does not hold up approval"). The rules come after the bar in the prompt, so they can loosen or tighten it.
3. The verdict is stored on the review row (`approval`, JSON `{approve, reason}`) before the row becomes ready, so posting, approving after a manual post and the app's **Ready to approve** mark all read the same decision and the judge runs once per review. A row without a verdict (older rows, or `approveBy: rules`) falls back to the parser.
4. **Fail closed.** A judge that fails, times out or answers in a shape that does not parse is a verdict of not approving, with the reason. The review itself is kept and follows `review.post`.
5. When the judge holds up an approval, the posted review's note says why ("Not approved: …"), so the app shows it next to the review.
6. _My call_: the judge runs whenever `approveBy` is `agent`, also with `review.approve` off, since the verdict also drives the **Ready to approve** mark. It uses `review.model` at low effort with a fixed 5-minute timeout, and its tokens count under the purpose `approve`.
7. _My call_: the review is untrusted text (its model read the MR). The prompt fences it, says it is data, and the answer is parsed with a schema; anything else is not approving.

## Not done

- No separate model setting for the judge.
- A verdict is not decided again when `review.approveWhen` or `review.approveRules` change; the next review of the MR uses the new settings.
- The verdict's reason is not added to the `suica reviews --json` contract; it reaches the app through the review's posting note.
