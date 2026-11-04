# Clear cache and junk

## Problem

Suica's state folder grows with files the app can rebuild or no longer needs. On the author's Mac (2026-11-04) the folder held 10 MB: a 1.6 MB Agent Usage cache, a migration backup from Oct 18, a 2 MB write-ahead log beside a 6 MB database, an old update folder, and a 1.5 MB `stdout.log` that is never rotated. There was no way to clear them from the app.

## What it does

`suica cleanup --json` (`src/cleanup.ts`), and **Configuration → Storage → Clear cache and junk…** in the app, which asks first:

| Item | Action | Why it is safe |
| --- | --- | --- |
| `agent-usage-cache.json`, `exchange-rate.json` | delete | caches; the next Agent Usage load rebuilds them (one slow scan) |
| `state.db.before-*` | delete | one-time migration backups |
| `update/` | delete, unless `update/staged/Suica.app` exists | that app waits to be swapped in |
| `fixes/<id>` | `cleanFixDirs` (as at agent start) | keeps running, ready and confirming fixes |
| `stdout.log`, `stderr.log` | truncate to 0 | launchd opens them with O_APPEND (`lsof` shows `AP`), so the agent keeps writing at the new end |
| `state.db` | `wal_checkpoint(TRUNCATE)`, `VACUUM` | the store's busy timeout waits for the agent's writes |

It prints `{"version":1,"status":"cleaned","freedBytes":…}` (contract: `contracts/cleanup.v1.json`): the bytes of these paths before minus after.

## Not touched

The config, `release-key.pem`, templates, `lessons-usage/` (the data behind Lessons usage), `lesson-scopes.json`, and every database row. Rows are already pruned: the poll log, history and approvals after 90 days, and token usage, reviews and fixes by their own retention. `lessons-seen/` prunes itself on every hook run.

## My calls

- One command and no preview or dry run: the confirmation dialog says what goes.
- Logs are emptied, not rotated: the agent's log is diagnostics, and Logs in the app reads the live file.
- No speed work came out of the same request. Measured at idle: the app at 0–1.7% CPU and the agent at about 0.1%. The CLI commands the app runs take about 0.1 s warm (`state --json` took 0.5 s once, cold). The menu bar loop costs about 0.1 s of CPU every 30 s. The ten `suica lessons mcp` processes belonged to open Claude Code sessions, not leaks.
