# Merged Nudge

## Why

Each of the Owner's MRs queues its own Reviewer Nudge, Reminder and Re-review Nudge. When the Owner opens three MRs for one ticket and asks the same person to review all of them, that person gets three chats in a row. One chat listing the three links says the same thing without the spam.

## What the Owner sees

Messages that are due to the same person in the same dispatch pass go out as one Teams chat when they are the same kind of message and their MR titles carry the same ticket key. The chat is the usual template with `{{mr.link}}` replaced by a list, one MR per line:

```
Halo Bob, saya Bahlil, agen review-nya Nata. Boleh minta tolong review MR ini?
- [[ABC-123] Add login](https://…/-/merge_requests/5)
- [[ABC-123] Add login UI](https://…/-/merge_requests/6)
Terima kasih!
```

Messages and Statistics still show one row per MR. Rows that were folded into another chat end as `sent` (or `dry-run`) with the detail `merged into #<id>`.

## Decisions

- **Same ticket (my call):** the first match of `/\b[A-Z][A-Z0-9]+-\d+\b/` in the MR title, such as `ABC-123` in `[ABC-123] Add login` or `feat(ABC-123): add login`. The poll query does not fetch the source branch, so the branch is not used.
- **Same topic without a ticket key (my call): no merge.** Fuzzy title matching would put unrelated MRs in one chat. Open question for the Owner: what should count as the same topic when there is no key?
- **Same kind of message:** same recipient, same `kind` and same `variant`. A nudge, a reminder and a re-review are never mixed. Review Notices (to Authors) and messages written by hand are never merged.
- **Where it happens (my call):** at dispatch time. The planner, the `nudge_state` ledger, dedupe keys, `stillNeeded` and the outbox schema do not change, so reminders and the Re-review ledger behave as before.
- **Limit:** only rows that are queued in the same `dispatchQueued` pass merge. A row queued by a later poll goes alone. Rows held outside working hours or for approval pile up and merge when they are released.
- **Size (my call):** at most 10 MRs per chat; a larger group is split in order.
- **Wording (my call):** the built-in and custom templates are not changed, so "MR ini" stays singular. A `*.multi` template would be a later change.
- **Approval mode:** every row of the group becomes `pending` with the same merged text; one macOS notification per group (for the lead row); `suica send <id>` on any of them sends the chat and moves the other pending rows with the same recipient, variant and text to `sent`.

## Non-goals

No new config key, no hold window to wait for later siblings, no grouping by branch, no change to the Swift app or the contracts (rows keep the same fields).

## Risk

A false ticket key (`UTF-8`, `SHA-256`) merges two MRs that mention the same one; the result is one chat with two links, never a lost message.
