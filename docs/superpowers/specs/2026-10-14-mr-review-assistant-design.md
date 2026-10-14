# MR Review Assistant — design

Status: agreed with the Owner in a design interview on 2026-10-13/14. Vocabulary is defined in `CONTEXT.md` (Owner, Author, Reviewer, Review Request, Reviewer Nudge, Review Notice, Activity Alert, Agent Review, Pending Message); this document uses those terms and does not redefine them.

## Goal

A personal background agent on the Owner's Mac that watches GitLab merge requests on `repo.madhani.one`, tells the Owner what needs attention, chats other people in Microsoft Teams so reviews keep moving, and reviews incoming MRs with a language model.

## Flows

| Flow | Trigger | Result |
|---|---|---|
| A. Review Request | Someone adds the Owner as Reviewer on a non-draft MR (or re-requests) | macOS notification, click opens the MR |
| B. Reviewer Nudge | A Reviewer is added to / re-requested on the Owner's non-draft MR | Teams chat from the Owner to the Reviewer; one reminder if still `UNREVIEWED` after 1 working day; max 2 messages per MR per Reviewer; working hours only; never to a Reviewer who already reviewed |
| C. Review Notice | The Owner reviews someone else's MR (debounced), or an Agent Review is posted | Teams chat from the Owner to the MR's Author; variants: approved, requested changes, comments only, agent review |
| D. Activity Alert | A Reviewer's `reviewState` changes, or someone else posts a human comment on the Owner's MR | macOS notification, grouped per MR per poll |
| Agent Review | A Review Request (A) on a non-draft MR | A language model reviews the MR and the result is posted to GitLab as the Owner |

## Decisions

### Runtime and scope
- Single user (the Owner), on the Owner's Mac, as a launchd LaunchAgent. TypeScript on Node 24, run with Node's native type stripping (no build step).
- Poll every 120 s while the Mac is active, every 300 s while idle (idle = no keyboard/mouse input for 300 s). Both intervals and the idle threshold are configurable. After a full sleep the next poll catches up from stored state; many events arriving at once collapse into one summary notification.
- All projects visible to the Owner, no allowlist. Draft MRs are ignored until they are marked ready. Only open MRs are watched.

### GitLab access
- `glab api graphql --hostname <host>` using the Owner's existing `glab` login. No token in our code or config.
- GitLab is read-only for flows A–D. Writing to GitLab happens only through Agent Review (see below).
- The API does not expose coworkers' emails and usernames are employee IDs, so GitLab → Teams identity is resolved by display name (see Teams).

### Teams (Plan 2)
- The agent is an MCP client of the existing Teams MCP (`~/.config/teams-mcp/run.sh`, tools `search_users`, `create_chat`, `send_chat_message`). Messages come from fixed templates, never from a language model.
- Send mode is configurable per flow: `auto`, `approval` or `dry-run`. Default for Reviewer Nudge and Review Notice is `approval`. Approval is done in a CLI (`mra pending`, `mra send <id>`, `mra skip <id>`).
- Templates are text files in the config folder, Indonesian by default, with validated placeholders. An unknown placeholder stops startup instead of sending a broken message.
- Identity: resolve the GitLab display name with `search_users` and cache the result. Exactly one match → use it. Zero or several → send nothing and tell the Owner to add a line to the mapping file.
- State is written before sending (at most once). A missed nudge is acceptable; a duplicate nudge is not.

### Notifications to the Owner
- macOS notifications. `terminal-notifier` (click opens the MR) when installed, otherwise `osascript` (no click-through).

### Agent Review (Plan 3)
- Invoked as `claude -p` (Claude Code headless) with a read-only tool set (`Read`, `Grep`, `Glob`) on a shallow read-only checkout of the MR's source branch in a temp folder that is deleted afterwards. Output is JSON (file, line, severity, comment) validated against a schema; deterministic code posts it.
- Triggered for every non-draft Review Request once the head commit has been stable for 5 minutes, up to 800 changed lines (larger MRs are skipped with a notification), never twice for the same head SHA, and again only on a new Review Request.
- Posted automatically as the Owner. Comments are in English and carry a visible label stating they were written by an agent. Inline where the line is part of the diff, otherwise a general MR note. A summary note is posted even when there are no findings.
- Guardrails, all configurable: the agent never approves and never requests changes; every comment is sanitised (lines starting with `/` are escaped because GitLab runs quick actions in notes, `@mentions` removed, no outbound links); caps on comments per MR and reviews per day; a kill switch (`mra pause`) and a cost cap; a severity threshold.
- The send mode switch exists here too (`auto` / `approval` / `dry-run`). The Owner chose `auto`; a dry-run period at first is recommended.

### State, failures, logging, config
- SQLite file in `~/Library/Application Support/mr-review-assistant/`. The first run records a baseline silently and shows one summary notification ("N MR waiting for your review"); old history never triggers Nudges, Notices or Alerts.
- Each failure kind (glab missing, GitLab auth, GitLab unreachable, GitLab error, notifier) notifies the Owner once and resets on recovery. Network errors back off exponentially up to a cap. Teams sends are never retried automatically.
- Logs: JSON lines to stdout with `timestamp`, `level`, `message`, `service_name`, `environment`, extra context under `attributes`; English constant messages; no employee IDs, names, comment text or tokens.
- One YAML config file plus template files. Unknown keys are rejected.

### Testing
- Vitest. Unit tests for pure logic (snapshot diff → events, debounce, templates, mapping). Integration tests use a real SQLite database and fake GitLab and Teams. Real GitLab and Teams are only exercised by a manual smoke test, which is documented as manual, not E2E.

## Delivery in three plans

1. **Plan 1 — foundation, flows A and D, macOS notifications.** Read-only; no Teams, no language model. Working software on its own.
2. **Plan 2 — Teams (flows B and C).** Teams MCP client, templates, identity mapping, send modes, approval CLI.
3. **Plan 3 — Agent Review.** Written after Plans 1 and 2 exist, because it consumes their event types, store and send-mode config.

## Deliberate gaps (not forgotten)

- The Owner accepted "one last Activity Alert when an MR is merged or closed". Plan 1 watches open MRs only, so an MR that disappears from the open set produces no final alert. Closing this needs a second query for recently merged/closed MRs and is deferred.
- A comment that arrives in the same poll in which an MR is first tracked (or flips from draft to ready) is recorded silently, not alerted.
