# Lessons usage log: design

- **Date:** 2026-10-29
- **Status:** approved for planning (answers from Nata on 2026-10-29)
- **Builds on:** [review lessons](2026-10-26-review-lessons-design.md)

## Why

Lessons reach Coding Agents through the Claude Code hook (session start, file read, file edit) and the `suica-lessons` MCP server, and today nothing records it. Nata wants to see which projects use the Lessons, what each project was handed, and how many tokens that context added.

## What

1. **Every delivery is logged.** One entry each time the hook answers with Lessons, and each time an MCP tool answers with at least one Lesson. Nothing is logged when nothing is handed over (an empty answer, `No lessons apply here.`, a failure).
2. **An entry holds:** `at` (epoch ms), `project` (the repo's `group/sub/project`; `null` for a session started in a scope folder outside any repo), `scope` (the Lesson Scope folder), `source` (`session`, `read`, `edit` or `mcp`), `tool` (the MCP tool name, MCP only), `sessionId` (hook only, and only when it matches the seen store's `SESSION_ID` pattern), `file` (the repo-relative path for `read`/`edit`, and for `mcp` when `path` is a file in a repo), `lessonIds`, `tokens`.
3. **Tokens are an estimate:** `ceil(chars / 4)` of the exact text handed to the agent (the hook's `additionalContext`, the MCP reply's text), the same four characters a token the learner's `tokenCap` uses. The document and the app say "estimated". *My call:* count the whole text including the intro line, since that is what the agent's context grows by.
4. **Storage:** files, not the database. The hook and the MCP server open the state database read-only and the hook must never stall a Read or an Edit, so entries go to `<stateDir>/lessons-usage/YYYY-MM-DD.jsonl` (UTC day of `at`), one JSON line per delivery, appended, files and folder private (`0o600`, `0o700`). Files older than 30 days are removed when the log is opened. Every write failure is swallowed, like the seen store: a missing entry never costs the agent its Lessons. *My call:* the 30 days is fixed, no config row.
5. **`suica lessons usage --json`** prints the last 30 days as one document (`contracts/lessons.v1.json` under `usage`): totals; one row per project (or per scope folder for `null`-project entries), heaviest by tokens first, with deliveries, sessions, tokens, distinct Lessons, counts per source, the last use, and the Lessons it got (id, title, times; at most 20, most often first); and the newest 100 entries. A Lesson that is gone since shows with a `null` title. A malformed line is skipped. Works while lessons are off (the log is history), and reads nothing when the folder is missing.
6. **App:** the Lessons page's List/Graph picker gets a third view, **Usage**: the projects with their numbers, and for the chosen project the Lessons it got and its recent deliveries (time, source, file, Lessons, tokens). Tokens carry the "estimated" label.

## Not in scope

Real tokenizer counts; per-agent attribution (the hook does not know which agent ran it); a config row for retention; exporting the log to the vault.
