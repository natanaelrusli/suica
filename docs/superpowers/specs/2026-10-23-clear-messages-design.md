# Clearing messages

## Goal

The Owner can clear messages off the Messages lists once they are done with them, instead of
waiting for the 90-day retention to delete them.

## What can be cleared

- A finished message: sent, skipped, dry run or failed. A message still waiting (queued, pending,
  unresolved) cannot be cleared; Skip is how it ends.
- A message in sending (added 2026-10-23): a send that crashed half way stays there for good and has
  no action, and the app says "may have been delivered: check Teams". It gets a **Clear** button too.
- **Clear** in the Recent heading clears the tab's sent, skipped and dry-run messages (Your MRs:
  nudges, reminders, Re-review Nudges; Others' MRs: Review Notices). A failed message sits under
  Needs attention, so bulk clear leaves it alone (my call: the bulk button belongs to the section it
  sits in).
- A failed or stuck sending message gets its own **Clear** button: it had no action before, so
  nothing took it off Needs attention.
- Right-click any finished message (window or popover) for **Clear** on just that one.

## How

- Schema 19 adds `outbox.cleared_at`. Clearing sets it; the row is not deleted (my call): Statistics
  counts the outbox, and the row's `dedupe_key` keeps the planner from queueing the same message
  again. Retention deletes a cleared row 90 days after its last change, whatever its status, so a cleared
  stuck row does not stay for ever.
- `suica state` and `suica pending` hide cleared rows; `suica stats` and dispatch read them as before.
- CLI: `suica clear <id> [--json]` (`cleared`, or `nothing` with exit 1, like `skip`) and
  `suica clear yours|others|all [--json]` (`cleared` or `nothing`, exit 0).
- The bulk clear asks for confirmation and is hidden while a search is typed, since it clears the
  whole tab and not only the matches (my call).
