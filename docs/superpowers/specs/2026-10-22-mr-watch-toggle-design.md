# Watch and unwatch an MR — design

Status: written from the Owner's request on 2026-10-22 ("watch or unwatch my MR, and can trigger ai agent to fix reviewer findings automatically, this can also be triggered manually, configurable"). The Owner skipped the questions, so every choice below marked _my call_ is the builder's. Builds on Agent Fix and Pipeline Fix (README, `2026-10-21-pipeline-fix-design.md`).

## What already existed

- Automatic Agent Fixes of new Finding Threads on every open, not yet approved MR of the Owner (`fix.auto`), and automatic Pipeline Fixes (`fix.pipelines`).
- Manual triggers: **Fix findings now** and **Fix pipeline** on the MR page, `suica fix queue <key> [--pipeline] --json`.
- Settings: `fix.auto`, `fix.pipelines`, `fix.maxPerDay`, `fix.model`, `fix.effort`, `fix.timeoutMinutes`.

What was missing is a choice per MR. Today every MR is watched or none is.

## What it adds

- **Watch / Unwatch** per MR: a button on the MR page of each of the Owner's MRs, and `suica fix watch <key> --json` / `suica fix unwatch <key> --json` (`{"status": "watching" | "not-watching" | "bad-key"}`).
- **`fix.watch`** (new setting, "Which MRs to watch"): `all` (default; every open MR is watched unless you unwatch it, which is today's behaviour) or `chosen` (only MRs you press **Watch** on). An MR's own choice always wins over the setting.
- A **Watched MR** is now: open, authored by the Owner, not approved by every Reviewer, and watched (its own choice, else `fix.watch`). `fix.auto` stays the main switch: off means no automatic fix on any MR.

## Behaviour

- Unwatched MRs get no automatic thread fix and no automatic Pipeline Fix. The pipeline-failed notification still comes (_my call_: it is cheap and tells you something you may want to fix by hand).
- Manual **Fix findings now** and **Fix pipeline** work on every MR of yours, watched or not.
- **Unwatch** cancels the MR's fix while it is queued and was queued automatically (_my call_); a running or ready fix stays, since you may want its work.
- **Watch** forgets when the watcher last read the MR, so the next poll reads its threads and fixes those written while it was unwatched (_my call_: watching means "take care of this MR now").
- Approval still ends automatic thread fixes, as before; pressing **Watch** on an approved MR is kept and applies once an approval is reset.
- Choices of MRs that are no longer open are dropped each poll.
- No ownership check on watch or unwatch (_my call_): it only changes a local preference and nothing reaches GitLab; the watcher only ever looks at the Owner's own MRs.

## Data and contracts

- State schema 17: table `mr_watch (mr_key TEXT PRIMARY KEY, watched INTEGER NOT NULL)`; no row means "follow `fix.watch`".
- `suica reviews --json`: each of `yourMergeRequests` gets `watched` (boolean, the effective value). The contract stays version 1: the field is an addition; the app reads a missing field as watched.
- `config.v1.json` gets `fix.watch`.

## App

- **Yours** rows show a small **Watching** mark (eye) on MRs that are watched and not yet approved; nothing otherwise.
- The MR page of one of your MRs has **Watch** (eye) or **Unwatch** (eye.slash) beside **Fix findings now**; its help says what it does.
- Configuration shows `fix.watch` beside **Watch my MRs**.

## Not done

- No watching of MRs the Owner reviews, no per-MR choice of thread fixes versus pipeline fixes, no per-MR daily cap. None was asked for.

## Tests

- Unit: the effective watch value (choice wins, else the setting); automatic thread fix skipped for an unwatched MR and queued for a chosen one in `chosen` mode; automatic Pipeline Fix skipped for an unwatched MR while the notification still goes out; unwatch cancels a queued automatic fix and keeps a manual one; watch resets the read mark; choices of closed MRs dropped; schema migration from 16; `watched` in the reviews golden (Node writes, Swift decodes, missing reads as watched).
