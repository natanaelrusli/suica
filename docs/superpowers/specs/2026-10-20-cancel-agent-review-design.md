# Cancel an Agent Review — design

Status: written from the Owner's request on 2026-10-20 ("Make a way to cancel agent review, when it is running or queued"). Choices marked _my call_ are the builder's and can be changed. Vocabulary is in `CONTEXT.md`.

## Intent

An Agent Review can take many minutes and spends model tokens. The Owner wants to stop one that is queued or already running, from the app.

## Goals

- **Cancel review** on the **Agent review** tab while a review is queued or running; `suica review cancel <id> --json` for the same from the CLI.
- A queued review never starts. A running one stops within seconds: the clone or the model CLI is killed and the checkout is deleted.
- No "failed" notification and no automatic post for a cancelled review.

## Non-goals

- Cancelling a review that is being posted (`posting`): part of it may already be on GitLab.
- A cancel control on the Overview card or the menu bar (_my call_: the tab is where the review lives; the Overview would need the dashboard client to grow a review action).

## Behaviour

- New status `cancelled`, with detail "Cancelled by you." It is a done status (kept 90 days like the others), is not a base for a re-review (only posted and discarded are), and does not count toward `review.maxPerDay` (_my call_: like `skipped`, the Owner did not get a review out of it).
- The CLI and the background agent are separate processes sharing the state database, so `cancel` only moves the row from `queued` or `running` to `cancelled`. A running review checks its row every two seconds and aborts its own signal when the row is no longer `running`; the signal reaches the clone and the CLI. Every later transition of the run is guarded by `from: running`, so a run that finishes in the same moment drops its result instead of overwriting the cancel.
- A cancelled review is not queued again on its own: the MR counts as reviewed for first reviews, and a re-review's head stays marked queued until the Author pushes again (_my call_: cancelling means "not this one"). **Review again** queues a new one.

## Tests

- `test/agent-review.test.ts`: cancelling a queued review (never runs, not counted, can be queued again, a finished review cannot be cancelled); cancelling a running review kills the CLI through the signal, leaves the row cancelled, notifies nothing and deletes the checkout; a cancel that lands as the CLI finishes drops the result.
- `ReviewsTests.swift`: the model cancels only a queued or running review, by id, and reports the outcome.
