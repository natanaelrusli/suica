# Richer logs — design

Status: written from the Owner's request on 2026-10-20 ("Improve the logs. Log more type of events, with more details"). Choices marked _my call_ are the builder's and can be changed. Vocabulary is in `CONTEXT.md`.

## Intent

The Logs page showed little more than start, stop, failures and counts ("teams messages sent", count 1). Nothing said which MR asked for a review, which Teams message went out, or why an Agent Review was skipped (`reason: Skip`). The Owner wants the log to tell what the agent did.

## Goals

New lines, all at `info` unless noted, each with the MR key and the row id where there is one:

| Message | Attributes |
|---|---|
| `daemon started` | `pid`, `node`, poll intervals, `teams_enabled`, `model_cli`, `review_auto`, `review_post`, `review_concurrency` |
| `daemon stopped` | `uptime_seconds` |
| `baseline recorded` | `pending_reviews`, `authored` |
| `review requested` | `mr_key` |
| `reviewer state changed` | `mr_key`, `state` |
| `comment received` | `mr_key`, `note_id` |
| `notifications delivered` | `count`, `total` |
| `poll failure recovered` | `kind`, `failed_polls` |
| `polling paused` / `polling resumed` | (none) |
| `agent review queued` | `id`, `mr_key`, `rereview` |
| `agent review started` | `id`, `mr_key`, `trigger`, `cli`, `model` (when set), `changed_lines`, `rereview`, `incremental` |
| `teams message sent` / `waiting for approval` / `skipped` | `id`, `kind`, `variant`, `mr_key`, `reason` for skipped |
| `teams message postponed` (`debug`: it repeats every poll while Teams is down) | the same and `reason` |
| `teams recipient not found`, `teams recipient lookup failed`, `teams message failed` (`warn`) | the same and `reason` |

Changed lines: `agent review ready` gains `model`, `rereview` and the input and output tokens; `agent review skipped` / `failed` gain `detail` (the reason the Owner sees in the app) and `duration_ms`; `dry-run message recorded` gains the row attributes; `next poll scheduled` (debug) gains `idle_seconds` and `failure_streak`. `teams messages sent` (a count) is gone, replaced by one line per message.

## Non-goals

- Owner actions run through the CLI (`suica send`, `review post`, `mr approve`, pause from the app): the CLI is another process whose output the app reads, so its lines never reach `stdout.log` (_my call_: writing that file from the CLI would break the "stdout only" logging rule; the outbox and review rows already record these actions).
- A version field: `package.json` stays at 0.1.0, so it would say nothing (_my call_).
- Log levels, rotation or a new log format.

## Behaviour

- No person is named: no username, name or email of a Reviewer, Author or recipient, only MR keys, row ids and note ids (_my call_: names are personal data under the logging rule; the id leads to the row in the app).
- `detail` is logged only for the agent's own reasons (a skip, a known run failure); any other error logs only its class, since its text could hold anything.
- Events are logged after the poll's state commit, so an event whose delivery failed and is retried is logged once.
- A recovery is logged only when the failure had been reported (its streak reached the kind's threshold), so a single unreachable poll after a wake stays quiet.
- Pause and resume are logged by the poll loop when the status changes, so the first poll after the Owner pauses says so once.
- Per-message Teams lines come from the poll's dispatch only, not from `suica send`.

## Tests

- `poller.test.ts`: baseline, each event kind, delivered notifications, no person in the log, events logged only after a commit, recovery only after a reported streak.
- `daemon.test.ts`: paused and resumed logged once per change.
- `dispatch.test.ts`: sent, held, obsolete, unresolved and failed lines with the row attributes and without the recipient or the Teams error text.
- `agent-review.test.ts`: started and ready attributes, skipped and failed `detail`, one queued line per queued review.
