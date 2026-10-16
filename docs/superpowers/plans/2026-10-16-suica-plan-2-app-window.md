# Suica — Plan 2: the app window (status, statistics, configuration, messages)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Suica gets a proper window, opened from the menu bar, where the Owner sees the agent's status, statistics (poll health, alerts, Teams messages, review turnaround), the held and recent Teams messages, and edits every configuration key.

**Architecture:** The Node agent stays the only brain and the only writer of the config file and the database. It starts recording history (a poll log and review events, schema v3) and gains four JSON commands — `suica status --json`, `suica stats --json`, `suica config show --json`, `suica config set --json` (edits on stdin) — plus `suica agent restart --json`. Each document has a golden file in `contracts/` read by a Vitest test and a Swift test. The Swift app adds a SwiftUI `Window` with a sidebar; it shares the menu bar's `MenuModel` so a message can never be sent twice from the two surfaces. The config form is generated from a field list the agent publishes, so the Swift side does not duplicate the schema.

**Tech Stack:** Node 24 / TypeScript / Vitest / `yaml` 2.9.1 `parseDocument` (keeps comments) / `node:sqlite` (existing); Swift 6.3, SwiftUI, Swift Charts (system framework), macOS 14+, Swift Testing.

**Spec:** No UI spec exists. The Owner asked on 2026-10-16 for "a proper app UI window where the user can see statistics, configs, status", and chose: keep the menu bar and add a window; a **full** config editor; statistics for poll health, alerts shown, Teams messages and review turnaround. The design decisions below stand in for a spec; Task 10 adds a section to `docs/superpowers/specs/2026-10-14-mr-review-assistant-design.md`. Requires Plan 1 (`2026-10-16-suica-plan-1-rename.md`): all names here are the Suica names.

## Design decisions (made here; change them before execution if you disagree)

- **Window sections:** Overview (agent and polling status, paths, restart), Messages (the outbox, same rows and actions as the popover), Statistics, Configuration. The popover gains **Open Suica…**. While the window is open the app shows in the Dock (activation policy `.regular`), and goes back to menu-bar-only when it closes.
- **History starts now.** Nothing before the upgrade is reconstructed. Poll log and review events are kept 90 days (the outbox's retention). Statistics cover the last 14 local days (daily bars) and 30 days (turnaround).
- **What is counted:** *Review Requests* and *activity on your MRs* (reviewer state changes and comments that passed `ignoreAuthors`) as detected, before they are grouped into a summary notification; *Teams messages* from the outbox by the day of their last change; *turnaround* = Review Request → the Owner's review leaves `UNREVIEWED`, and delivered nudge → that Reviewer leaves `UNREVIEWED`, median and 90th percentile (nearest rank) in whole minutes. Paused polls are not logged.
- **Config editor:** a form with every key, generated from the agent's field list; the agent validates (schema, and the templates when Teams is on) and writes the YAML with comments preserved, atomically, mode `0600`, refusing if the file changed since it was read (`conflict`). Edits apply after **Restart agent** (`launchctl kickstart -k`), which the window offers after a save. Templates are not edited in the app; Configuration has **Open templates folder** and **Open config in editor**.
- **The status and config commands work with a broken config,** so the window can show the error and fix it.
- **English in the app.** Unchanged: Indonesian Teams messages and notifications.

## Global Constraints

- Everything in Plan 1's Global Constraints and the earlier plans' constraints applies (Node `>=24`, `.ts` suffixes, erasable syntax only, **no new dependencies** on either side — Swift Charts ships with macOS; no `print`/`try!`/force unwrap/`as!` outside Swift tests; child processes via `Process.executableURL` + argument array with a timeout; JSON logs with **no names, titles, usernames, emails or message text**).
- New JSON goes to stdout only and is never logged. Every document carries `"version": 1`; the Swift decoder reads `version` first and throws `AgentError.unsupportedVersion(n)` for anything else (the existing `decodeAgentState` pattern).
- Text from other people and from the config (names, titles, emails, paths) is shown through `DisplayText.clean(_:max:)`; links open only through `DisplayText.safeURL`.
- `suica config set` reads at most 1 MiB from stdin; anything larger is `bad-request`.
- Branch `feat/no-ticket-suica-window`, cut from the tip of `feat/no-ticket-suica-rename`. MR title `[no-ticket] feat: Suica app window with status, statistics and configuration`. Use the Owner's planner key instead of `no-ticket` if one exists.
- Tests never write the Owner's real config, never call the real `launchctl`, never send a Teams message.
- Run commands: Node `npm run check`; Swift `cd macos/Suica && swift test`.

## Review Focus

1. **Saving a config that would stop the agent from starting** (Teams switched on with a missing template, `workingHours.start` after `end`, an unknown key from a stale field list) — expected: `invalid` with the field's path and message, file unchanged. Tests: `test/config-edit.test.ts` "rejects Teams on with a missing template", "rejects start after end" (Task 6).
2. **The config file edited by hand while the window has unsaved edits** — expected: `conflict`, nothing written, the window keeps the drafts and offers Reload. Tests: `test/config-edit.test.ts` "conflict when the file changed", `ConfigEditorModelTests.swift` "conflictKeepsDrafts" (Tasks 6, 8).
3. **The same message acted on from the popover and the window at once** — expected: one send; the second click is ignored while busy. Test: `WindowTests.swift` "windowAndPopoverShareOneModel" (Task 8).
4. **A history write failing in the middle of a poll** (disk full, locked DB) — expected: the poll result and alerts are unaffected, one warn log with the error class only. Test: `test/poller-history.test.ts` "a failing poll log does not change the poll status" (Task 2).
5. **A day boundary and a clock that jumps** (Mac in another time zone, events in the future) — expected: days bucket by the injected `dayKey`; events after `now` are ignored, never a negative turnaround. Tests: `test/stats.test.ts` "ignores events after now", "never reports a negative turnaround" (Task 3).

## File Structure

| File | Responsibility |
|---|---|
| `src/store.ts` (modify) | Schema v3: `poll_log`, `history_event`; `recordPoll`, `commit(snapshot, history)`, `loadHistory` |
| `src/history.ts` | Pure: `historyEvents` (what one poll adds to the history) |
| `src/poller.ts` (modify) | Records history in the commit and one poll-log row per non-paused poll |
| `src/stats.ts` | Pure: `buildStats`, `localDayKey`; `StatsJson` |
| `src/agent-status.ts` | `readServiceStatus`, `restartService` (launchctl through `Exec`); `buildStatus`; `StatusJson` |
| `src/config.ts` (modify) | `validateConfig` returning per-path issues |
| `src/config-fields.ts` | The field list: every key, type, label, help |
| `src/config-edit.ts` | `showConfig`, `applyConfigEdits`, atomic write |
| `src/cli.ts` (modify) | `status --json`, `stats`, `config show|set`, `agent restart` before the runtime is created where needed |
| `contracts/status.v1.json`, `contracts/stats.v1.json`, `contracts/config.v1.json` | Golden documents |
| `macos/Suica/Sources/SuicaCore/Dashboard.swift` | Codable documents, `JSONValue`, decoders |
| `macos/Suica/Sources/SuicaCore/AgentClient.swift` (modify) | `Invocation.stdin`, `DashboardClient`, its CLI implementation |
| `macos/Suica/Sources/SuicaCore/WindowModel.swift`, `ConfigEditorModel.swift` | View models |
| `macos/Suica/Sources/SuicaCore/Copy.swift` (modify) | New strings |
| `macos/Suica/Sources/Suica/Window/*.swift` | Sidebar, Overview, Messages, Statistics, Configuration views (not unit-tested) |
| `README.md`, spec (modify) | Document the window |

---

### Task 1: Schema v3 and history storage

**Files:**
- Modify: `src/store.ts`
- Test: `test/store-history.test.ts`

**Interfaces:**
- Produces (in `src/store.ts`):
  - `type HistoryKind = "review-requested" | "owner-reviewed" | "reviewer-reviewed" | "activity"`
  - `interface HistoryEvent { readonly kind: HistoryKind; readonly mrKey: string; readonly username: string /* "" unless reviewer-reviewed */; readonly at: number }`
  - `interface PollLogEntry { readonly at: number; readonly status: "ok" | "failed"; readonly failure: string | null; readonly durationMs: number }`
  - `interface HistoryRows { readonly polls: readonly PollLogEntry[]; readonly events: readonly HistoryEvent[] }` (both ordered by `at`)
  - `Store.commit(snapshot: Snapshot, history?: readonly HistoryEvent[]): void` — history rows are inserted in the same transaction (default `[]`, so existing callers and tests compile).
  - `Store.recordPoll(entry: PollLogEntry): void` — inserts, then deletes `poll_log` and `history_event` rows with `at < entry.at - 90 days`.
  - `Store.loadHistory(since: number): HistoryRows`
- Schema v3 (exact):

```sql
CREATE TABLE IF NOT EXISTS poll_log (
  at INTEGER NOT NULL, status TEXT NOT NULL, failure TEXT, duration_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS poll_log_at ON poll_log (at);
CREATE TABLE IF NOT EXISTS history_event (
  kind TEXT NOT NULL, mr_key TEXT NOT NULL, username TEXT NOT NULL, at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS history_event_at ON history_event (at);
```

`SCHEMA_VERSION = 3`; `initSchema` runs this when `version < 3`.

- [ ] **Step 1: Branch**

```bash
git switch feat/no-ticket-suica-rename
git switch -c feat/no-ticket-suica-window
```

- [ ] **Step 2: Write the failing tests** in `test/store-history.test.ts` (real SQLite in a temp folder, prefix `suica-history-`)

```ts
it("upgrades a v2 database to v3 and keeps its rows", () => {
  // create a v2 file: open with the current store, insert an outbox row via applyTeamsPlan, close,
  // then `PRAGMA user_version = 2; DROP TABLE poll_log; DROP TABLE history_event` with DatabaseSync;
  // reopen → user_version 3, listOutbox(["queued"]) still has the row, loadHistory(0) is empty
});
it("stores history events in the commit transaction", () => { /* commit(snapshot, [ev]) → loadHistory(0).events equals [ev] */ });
it("does not store history when the commit fails", () => { /* close the db first or make commit throw → loadHistory empty after reopen */ });
it("records polls oldest first and prunes rows older than 90 days", () => {
  // recordPoll at t0, then at t0 + 91 days → loadHistory(0).polls has only the second; an event at t0 is pruned too
});
it("loadHistory(since) returns only rows at or after since");
```

- [ ] **Step 3: Run to verify they fail**

Run: `npx vitest run test/store-history.test.ts`
Expected: FAIL — `recordPoll is not a function`.

- [ ] **Step 4: Implement** schema v3 and the three methods in `src/store.ts`. `loadHistory` validates `kind` and `status` like `toOutboxRow` does (throw on unknown values).

- [ ] **Step 5: Run the checks**

Run: `npx prettier --write . && npm run check`
Expected: all pass, including the existing store tests.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: add schema v3 with the poll log and review history"
```

---

### Task 2: Record history from the poll cycle

**Files:**
- Create: `src/history.ts`
- Modify: `src/poller.ts`, `src/runtime.ts` (pass `now: Date.now`)
- Test: `test/history.test.ts`, `test/poller-history.test.ts`; update the `PollDeps` builders in `test/poller.test.ts`, `test/poller-teams.test.ts`

**Interfaces:**
- Consumes: `HistoryEvent`, `Store.commit(snapshot, history)`, `Store.recordPoll` (Task 1); `ActivityEvent`, `PreviousState`, `myReviewState`, `reviewerKey` from `src/events.ts`.
- Produces:
  - `historyEvents(snapshot: Snapshot, previous: PreviousState, events: readonly ActivityEvent[], at: number): HistoryEvent[]` in `src/history.ts`. Rules: empty when `!previous.baselineDone`; each `review-requested` event → `review-requested`; each `reviewer-state` and `comment` event → `activity`; a `reviewer-state` event whose previous stored state was `UNREVIEWED` or absent → also `reviewer-reviewed` with that `username`; every non-draft MR in `snapshot.reviewRequested` whose `previous.myReviewStates` value is `UNREVIEWED` and whose current `myReviewState` is not → `owner-reviewed`.
  - `PollDeps.now: () => number` (new, required).
  - `pollOnce` calls `store.commit(snapshot, historyEvents(...))` and, on every return except `"paused"`, `store.recordPoll({ at: start, status, failure, durationMs: now() - start })` with `failure` = the `FailureKind` that ended the poll (`gitlab-*`, `state`, `notifier`) or `null`. A throwing `recordPoll` is caught and logged once per call as `log.warn("poll history not recorded", { reason: error.name })`; it never changes the return value.

- [ ] **Step 1: Write the failing tests**

`test/history.test.ts` (builders from `test/builders.ts`):

```ts
it("records nothing before the baseline");
it("maps a review request and activity events", () => { /* 1 review-requested + 1 comment → kinds ["review-requested","activity"], username "" */ });
it("adds reviewer-reviewed when a Reviewer leaves UNREVIEWED", () => { /* stored UNREVIEWED → APPROVED: activity + reviewer-reviewed("bob") */ });
it("does not add reviewer-reviewed for APPROVED → UNAPPROVED");
it("adds owner-reviewed when the Owner's own state leaves UNREVIEWED", () => { /* myReviewStates g/p!1 UNREVIEWED, now APPROVED */ });
it("ignores the Owner's review on a draft MR");
```

`test/poller-history.test.ts`:

```ts
it("logs an ok poll with its duration", () => { /* now() returns 1000 then 1450 → recordPoll({at:1000,status:"ok",failure:null,durationMs:450}) */ });
it("logs a failed fetch with its failure kind", () => { /* FetchFailure("gitlab-unreachable") → failure "gitlab-unreachable" */ });
it("does not log a paused poll");
it("a failing poll log does not change the poll status", () => { /* recordPoll throws → status "ok", one warn "poll history not recorded" with reason "Error" only */ });
it("commits the history events with the snapshot");
```

- [ ] **Step 2: Run to verify they fail**

Run: `npx vitest run test/history.test.ts test/poller-history.test.ts`
Expected: FAIL — cannot resolve `../src/history.ts`.

- [ ] **Step 3: Implement** `src/history.ts` and the poller changes; add `now` to every `PollDeps` in tests and `src/runtime.ts`.

- [ ] **Step 4: Run the checks**

Run: `npx prettier --write . && npm run check`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: record the poll log and review history on every poll"
```

---

### Task 3: Statistics and `suica stats`

**Files:**
- Create: `src/stats.ts`, `contracts/stats.v1.json`
- Modify: `src/cli.ts`
- Test: `test/stats.test.ts`

**Interfaces:**
- Consumes: `HistoryRows` (Task 1), `OutboxRow` from `src/teams/types.ts`.
- Produces:

```ts
export interface TurnaroundJson { readonly count: number; readonly medianMinutes: number | null; readonly p90Minutes: number | null }
export interface DayJson {
  readonly day: string; // dayKey(ms), e.g. "2026-10-16"
  readonly reviewRequests: number; readonly activity: number;
  readonly nudgesSent: number; // kind nudge or reminder, status sent
  readonly noticesSent: number; readonly skipped: number; readonly failed: number;
}
export interface PollCountsJson { readonly ok: number; readonly failed: number }
export interface StatsJson {
  readonly version: 1;
  readonly generatedAt: number;
  readonly lastPoll: { readonly at: number; readonly status: "ok" | "failed"; readonly failure: string | null; readonly durationMs: number } | null;
  readonly polls24h: PollCountsJson; readonly polls7d: PollCountsJson;
  readonly days: readonly DayJson[]; // oldest first, every day present
  readonly ownerAfterRequest: TurnaroundJson; readonly reviewerAfterNudge: TurnaroundJson;
}
export function buildStats(input: { history: HistoryRows; outbox: readonly OutboxRow[]; now: number; days: number; dayKey: (ms: number) => string }): StatsJson;
export function localDayKey(ms: number): string; // local YYYY-MM-DD
```

Rules: rows with `at`/`updatedAt` after `now` are ignored. `days` covers the `days` local days ending today (step back by `dayKey(now - i * 86_400_000)`; a duplicate key from a DST change is merged). Turnaround pairs: for `ownerAfterRequest`, each `review-requested` (mrKey) with the first later `owner-reviewed` of the same mrKey; for `reviewerAfterNudge`, each `nudge` outbox row with status `sent` (start `updatedAt`) with the first later `reviewer-reviewed` of the same mrKey and `username === recipient`. Only pairs ending within the last 30 days count. Minutes = `Math.round(ms / 60_000)`. Median and p90 by nearest rank on the sorted list (`sorted[Math.ceil(p * n) - 1]`); `null` when `count` is 0. CLI: `suica stats` prints `buildStats({ …, days: 14, dayKey: localDayKey, now: Date.now() })` as one line of JSON (`loadHistory(now - 30 days)`, `teams?.list(true) ?? []`), exit 0.

- [ ] **Step 1: Create `contracts/stats.v1.json`** exactly:

```json
{
  "version": 1,
  "generatedAt": 1792152000000,
  "lastPoll": { "at": 1792148400000, "status": "ok", "failure": null, "durationMs": 1500 },
  "polls24h": { "ok": 1, "failed": 1 },
  "polls7d": { "ok": 2, "failed": 1 },
  "days": [
    { "day": "2026-10-15", "reviewRequests": 1, "activity": 0, "nudgesSent": 0, "noticesSent": 1, "skipped": 0, "failed": 0 },
    { "day": "2026-10-16", "reviewRequests": 0, "activity": 1, "nudgesSent": 1, "noticesSent": 0, "skipped": 1, "failed": 0 }
  ],
  "ownerAfterRequest": { "count": 1, "medianMinutes": 90, "p90Minutes": 90 },
  "reviewerAfterNudge": { "count": 1, "medianMinutes": 120, "p90Minutes": 120 }
}
```

- [ ] **Step 2: Write the failing tests** in `test/stats.test.ts` with `NOW = Date.UTC(2026, 9, 16, 12)`, `H = 3_600_000`, `M = 60_000`, `utcDay = (ms) => new Date(ms).toISOString().slice(0, 10)`:

```ts
it("matches the golden contract file", () => {
  // polls: {at:NOW-2*H,failed,"gitlab-unreachable",800}, {at:NOW-H,ok,null,1500}, {at:NOW-72*H,ok,null,1200}
  // events: review-requested g/p!1 at NOW-26*H; owner-reviewed g/p!1 at NOW-26*H+90*M;
  //         activity g/p!2 at NOW-30*M; reviewer-reviewed g/p!2 "bob" at NOW-20*M
  // outbox: nudge sent to bob on g/p!2 updatedAt NOW-140*M; notice sent updatedAt NOW-25*H; nudge skipped updatedAt NOW-10*M
  // expect(buildStats({history, outbox, now: NOW, days: 2, dayKey: utcDay})).toEqual(JSON.parse(readFileSync("contracts/stats.v1.json","utf8")))
});
it("returns zeros, a null lastPoll and null turnarounds with no history");
it("lists every day including empty ones, oldest first", () => { /* days: 14 → 14 entries, last is utcDay(NOW) */ });
it("ignores events after now");
it("never reports a negative turnaround", () => { /* owner-reviewed before review-requested → count 0 */ });
it("uses nearest-rank median and p90", () => { /* 10 pairs of 1..10 min → median 5, p90 9 */ });
it("drops pairs that ended more than 30 days ago");
it("counts reminders as nudges sent");
```

- [ ] **Step 3: Run to verify they fail**

Run: `npx vitest run test/stats.test.ts`
Expected: FAIL — cannot resolve `../src/stats.ts`.

- [ ] **Step 4: Implement** `src/stats.ts` and the `stats` CLI command (add `stats` to `SIMPLE` and the usage line).

- [ ] **Step 5: Run the checks and the real command (read-only)**

Run: `npx prettier --write . && npm run check && scripts/suica stats | node -e 'const s=JSON.parse(require("fs").readFileSync(0,"utf8"));console.log(s.version, s.days.length)'`
Expected: checks pass; prints `1 14`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: compute statistics and add suica stats"
```

---

### Task 4: Agent status and restart

**Files:**
- Create: `src/agent-status.ts`, `contracts/status.v1.json`
- Modify: `src/cli.ts`
- Test: `test/agent-status.test.ts`

**Interfaces:**
- Consumes: `Exec`, `execFailure` (`src/exec.ts`); `PollLogEntry` (Task 1); `loadConfig`, `ConfigError`, `defaultConfigPath`, `defaultStatePath` (`src/config.ts`); `defaultTemplatesPath` (`src/teams/templates.ts`).
- Produces:

```ts
export const AGENT_LABEL = "com.madhani.suica.agent";
export interface ServiceStatus { readonly loaded: boolean; readonly running: boolean; readonly pid: number | null }
export function parseLaunchctlPrint(stdout: string): ServiceStatus; // loaded: true; running: a line "state = running"; pid: a line "pid = <n>"
export async function readServiceStatus(exec: Exec, uid: number): Promise<ServiceStatus>; // launchctl print gui/<uid>/<label>, 5 s timeout; non-zero exit → {loaded:false,running:false,pid:null}
export async function restartService(exec: Exec, uid: number): Promise<"restarted" | "not-installed" | "failed">; // launchctl kickstart -k gui/<uid>/<label>, 15 s timeout; checks readServiceStatus first
export interface StatusJson {
  readonly version: 1;
  readonly agent: ServiceStatus & { readonly label: string };
  readonly configError: string | null;
  /** Null when the config could not be loaded. */
  readonly paused: boolean | null;
  readonly teamsEnabled: boolean | null;
  readonly lastPoll: PollLogEntry | null;
  readonly polling: { readonly activeSeconds: number; readonly idleSeconds: number } | null;
  readonly paths: { readonly config: string; readonly state: string; readonly logs: string; readonly templates: string };
}
export function buildStatus(input: { service: ServiceStatus; configPath: string; logsPath: string; loaded: { config: Config; paused: boolean; lastPoll: PollLogEntry | null } | { error: string } }): StatusJson;
```

`paths.state` and `paths.templates` are the config's values when it loaded, else the defaults; `paths.logs` is `~/Library/Logs/suica`. CLI: `suica status --json` prints `StatusJson` and exits 0 even when the config is broken (it does not call `createRuntime`; it uses `loadConfig` in a try/catch, and opens the store only when the config loaded). `suica status` without `--json` is unchanged. `suica agent restart --json` prints `actionJson(result)`, exit 0 only for `restarted`. Both are dispatched in `main` before `createRuntime`.

- [ ] **Step 1: Create `contracts/status.v1.json`** exactly:

```json
{
  "version": 1,
  "agent": { "label": "com.madhani.suica.agent", "loaded": true, "running": true, "pid": 4242 },
  "configError": null,
  "paused": false,
  "teamsEnabled": true,
  "lastPoll": { "at": 1792148400000, "status": "ok", "failure": null, "durationMs": 1500 },
  "polling": { "activeSeconds": 120, "idleSeconds": 300 },
  "paths": {
    "config": "/Users/o/.config/suica/config.yaml",
    "state": "/Users/o/Library/Application Support/suica/state.db",
    "logs": "/Users/o/Library/Logs/suica",
    "templates": "/Users/o/.config/suica/templates"
  }
}
```

- [ ] **Step 2: Write the failing tests** in `test/agent-status.test.ts` (fake `Exec` records calls):

```ts
it("matches the golden contract file", () => {
  // config = parseConfig with gitlab.hostname h, teams.enabled true,
  //   teams.templatesPath "/Users/o/.config/suica/templates", statePath "/Users/o/Library/Application Support/suica/state.db";
  // buildStatus({ service: {loaded:true,running:true,pid:4242}, configPath: "/Users/o/.config/suica/config.yaml",
  //   logsPath: "/Users/o/Library/Logs/suica", loaded: { config, paused: false, lastPoll: {at:1792148400000,status:"ok",failure:null,durationMs:1500} } })
  // toEqual the parsed golden
});
it("parses a running service", () => { expect(parseLaunchctlPrint("\tstate = running\n\tpid = 4242\n")).toEqual({ loaded: true, running: true, pid: 4242 }); });
it("parses a loaded service that is not running", () => { /* "state = not running" → running false, pid null */ });
it("reports not loaded when launchctl exits non-zero");
it("calls launchctl print with the exact target and a timeout", () => { /* ["print","gui/501/com.madhani.suica.agent"], {timeoutMs:5000} */ });
it("restart refuses when the agent is not installed", () => { /* print fails → "not-installed", kickstart never called */ });
it("restart kickstarts with -k", () => { /* ["kickstart","-k","gui/501/com.madhani.suica.agent"] → "restarted" */ });
it("builds a status with a config error and default paths", () => { /* {error:"invalid config: …"} → paused null, teamsEnabled null, polling null, lastPoll null */ });
```

- [ ] **Step 3: Run to verify they fail**

Run: `npx vitest run test/agent-status.test.ts`
Expected: FAIL — cannot resolve `../src/agent-status.ts`.

- [ ] **Step 4: Implement** `src/agent-status.ts` and the two CLI commands (`process.getuid()`; `defaultExec`).

- [ ] **Step 5: Run the checks and the real read-only command**

Run: `npx prettier --write . && npm run check && scripts/suica status --json | node -e 'const s=JSON.parse(require("fs").readFileSync(0,"utf8"));console.log(s.version, s.agent.label, s.configError)'`
Expected: checks pass; prints `1 com.madhani.suica.agent null`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: add suica status --json and suica agent restart"
```

---

### Task 5: The config field list and `suica config show`

**Files:**
- Create: `src/config-fields.ts`, `src/config-edit.ts` (the `showConfig` half), `contracts/config.v1.json`
- Modify: `src/config.ts`, `src/cli.ts`
- Test: `test/config-fields.test.ts`, `test/config-show.test.ts`

**Interfaces:**
- Produces in `src/config.ts`: `interface ConfigIssue { readonly path: string; readonly message: string }` (path joined with `.`, `(root)` for the root); `validateConfig(raw: unknown): { ok: true; config: Config } | { ok: false; issues: ConfigIssue[] }`; `parseConfig` keeps its behaviour and message format by using it. Also export `configSchema`.
- Produces in `src/config-fields.ts`:

```ts
export type FieldType = "string" | "int" | "bool" | "enum" | "clock" | "weekdays" | "stringList" | "emailMap";
export interface ConfigField {
  readonly path: readonly string[];
  readonly type: FieldType;
  readonly label: string;
  readonly help: string;
  readonly options?: readonly string[]; // enum only
  readonly placeholder?: string;        // optional keys whose default is computed at runtime
  readonly restartNote?: string;
}
export const CONFIG_FIELDS: readonly ConfigField[];
```

One entry per leaf of `configSchema`, in README table order, 24 in all: 3 `gitlab`, 4 `polling`, 2 `notifications`, 14 `teams` (`enabled`, `command`, `startTimeoutSeconds`, `callTimeoutSeconds`, `modes.nudge`, `modes.notice`, `workingHours.start`, `workingHours.end`, `workingHours.days`, `reminderAfterHours`, `noticeDebounceMinutes`, `maxMessagesPerReviewer`, `templatesPath`, `people`) and `statePath`. Types: `hostname`, `glabPath`, `command`, `templatesPath`, `statePath` → string; `*Seconds`, `*Hours`, `*Minutes`, `summaryThreshold`, `maxMessagesPerReviewer` → int; `enabled` → bool; `modes.*` → enum; `workingHours.start|end` → clock; `workingHours.days` → weekdays; `ignoreAuthors` → stringList; `people` → emailMap. Labels are short English; `help` is the README "Meaning" text. `placeholder`: `teams.command` → `~/.config/teams-mcp/run.sh`, `teams.templatesPath` → `~/.config/suica/templates`, `statePath` → `~/Library/Application Support/suica/state.db`. `statePath.restartNote` = `A new path starts with an empty history and a fresh baseline.`
- Produces in `src/config-edit.ts`:

```ts
export interface FieldJson extends ConfigField { readonly value: unknown /* as written in the file, null when absent */; readonly effective: unknown /* after defaults, null when absent or the config is invalid */ }
export interface ConfigDocJson {
  readonly version: 1; readonly path: string; readonly exists: boolean;
  readonly sha256: string | null; // of the file bytes, hex; null when it does not exist
  readonly issues: readonly ConfigIssue[]; // YAML syntax error → one issue at "(root)"
  readonly fields: readonly FieldJson[];
}
export function showConfig(path: string): ConfigDocJson;
```

CLI: `suica config show --json` prints it, exit 0, before `createRuntime`.

- [ ] **Step 1: Write the failing tests**

`test/config-fields.test.ts`:

```ts
it("covers every leaf of the config schema exactly once", () => {
  // walk configSchema: unwrap ZodDefault, ZodOptional, ZodEffects; recurse into ZodObject shapes;
  // ZodArray and ZodRecord are leaves → sorted list of dotted paths equals sorted CONFIG_FIELDS paths
});
it("gives enum fields the schema's options", () => { /* teams.modes.nudge options ["auto","approval","dry-run"] */ });
it("has a label and help for every field");
```

`test/config-show.test.ts` (temp folder):

```ts
it("matches the golden contract file for the minimal config", () => { /* file "gitlab:\n  hostname: repo.example\n" → equals contracts/config.v1.json with path and sha256 replaced by the test's values */ });
it("reports a missing file with exists false, sha256 null and effective null");
it("reports schema issues per path and keeps the file values", () => { /* polling.activeSeconds: 0 → issues [{path:"polling.activeSeconds",…}], field value 0, effective null */ });
it("reports a YAML syntax error at (root)");
```

- [ ] **Step 2: Run to verify they fail**

Run: `npx vitest run test/config-fields.test.ts test/config-show.test.ts`
Expected: FAIL — cannot resolve `../src/config-fields.ts`.

- [ ] **Step 3: Implement** `validateConfig`, `CONFIG_FIELDS`, `showConfig` and the CLI command.

- [ ] **Step 4: Create `contracts/config.v1.json`** from `showConfig` on the minimal config, then check it by eye before keeping it: 24 fields; `gitlab.hostname` value `"repo.example"`, every other `value` null; each `effective` equals the README table default; `effective` null for `teams.command`, `teams.templatesPath`, `statePath`. Store `"path": "/tmp/config.yaml"` and `"sha256": "0"`; the golden test substitutes those two. The reviewer of this task re-checks the defaults against the README.

- [ ] **Step 5: Run the checks**

Run: `npx prettier --write . && npm run check && scripts/suica config show --json | node -e 'const s=JSON.parse(require("fs").readFileSync(0,"utf8"));console.log(s.version, s.exists, s.fields.length, s.issues.length)'`
Expected: checks pass; prints `1 true 24 0`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: publish the config field list with suica config show"
```

---

### Task 6: Saving the config with `suica config set`

**Files:**
- Modify: `src/config-edit.ts`, `src/cli.ts`
- Test: `test/config-edit.test.ts`

**Interfaces:**
- Consumes: `CONFIG_FIELDS`, `validateConfig` (Task 5); `loadTemplates`, `defaultTemplatesPath` (`src/teams/templates.ts`).
- Produces:

```ts
export interface ConfigEdit { readonly path: readonly string[]; readonly value: unknown /* null removes the key */ }
export interface SaveRequest { readonly baseSha256: string | null; readonly edits: readonly ConfigEdit[] }
export interface SaveResultJson { readonly status: "saved" | "invalid" | "conflict" | "bad-request"; readonly issues: readonly ConfigIssue[]; readonly sha256: string | null }
export function parseSaveRequest(text: string): SaveRequest | undefined; // zod; undefined → bad-request
export function applyConfigEdits(path: string, request: SaveRequest): SaveResultJson;
```

Order in `applyConfigEdits`: (1) every edit path must equal a `CONFIG_FIELDS` path, else `bad-request` with the path as an issue; (2) current file sha256 (null when missing) must equal `baseSha256`, else `conflict`; (3) `parseDocument` the current text (empty document when missing), `setIn` / `deleteIn` each edit, and delete a mapping that became empty; (4) `validateConfig(doc.toJS())`, else `invalid` with its issues; (5) when `teams.enabled` is true, `loadTemplates(templatesPath ?? defaultTemplatesPath())`, a `TemplateError` → `invalid` at `teams.templatesPath`; (6) write `String(doc)` to `<path>.tmp-<pid>` with mode `0600` (parent created `0700`), `renameSync` over the file; return `saved` with the new sha256. Nothing is written on any other status. CLI `suica config set --json`: reads stdin up to 1 MiB (more → `bad-request`), prints `SaveResultJson` on one line, exit 0 only for `saved`; before `createRuntime`. The edit values and issues are never logged.

- [ ] **Step 1: Write the failing tests** in `test/config-edit.test.ts` (temp folder; a templates folder with all five valid files for the Teams cases):

```ts
it("sets a value and keeps comments and other keys", () => { /* "# mine\ngitlab:\n  hostname: h # host\n" + set polling.activeSeconds 60 → file contains "# mine", "# host", "activeSeconds: 60"; status saved; sha256 changed */ });
it("removes a key with null and drops the empty section", () => { /* polling: {activeSeconds: 60} → value null → no "polling:" left */ });
it("creates the file with mode 0600 when baseSha256 is null and it does not exist");
it("conflict when the file changed", () => { /* wrong baseSha256 → conflict, file bytes unchanged */ });
it("conflict when baseSha256 is null but the file exists");
it("rejects start after end", () => { /* workingHours.start "18:00" → invalid, issue path "teams.workingHours", file unchanged */ });
it("rejects Teams on with a missing template", () => { /* enabled true, templatesPath = empty folder → invalid at "teams.templatesPath" */ });
it("rejects an unknown field path as bad-request");
it("rejects a wrongly typed value", () => { /* polling.activeSeconds "fast" → invalid at polling.activeSeconds */ });
it("writes emailMap and weekdays values", () => { /* teams.people {"e123":"a@b.co"}, teams.workingHours.days [1,2,3] → saved, effective values match */ });
it("parseSaveRequest rejects garbage and missing fields");
```

- [ ] **Step 2: Run to verify they fail**

Run: `npx vitest run test/config-edit.test.ts`
Expected: FAIL — `applyConfigEdits is not a function`.

- [ ] **Step 3: Implement** `parseSaveRequest`, `applyConfigEdits` and the CLI command.

- [ ] **Step 4: Run the checks and a round trip on a copy (never the real file)**

Run: `npx prettier --write . && npm run check && D=$(mktemp -d) && printf 'gitlab:\n  hostname: h\n' > $D/c.yaml && SHA=$(SUICA_CONFIG=$D/c.yaml scripts/suica config show --json | node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(0,"utf8")).sha256)') && printf '{"baseSha256":"%s","edits":[{"path":["polling","idleSeconds"],"value":600}]}' "$SHA" | SUICA_CONFIG=$D/c.yaml scripts/suica config set --json; echo "exit $?"; cat $D/c.yaml`
Expected: checks pass; `{"status":"saved",…}`, `exit 0`, and the file shows `idleSeconds: 600`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: save validated config edits with suica config set"
```

---

### Task 7: Swift documents and the dashboard client

**Files:**
- Create: `macos/Suica/Sources/SuicaCore/Dashboard.swift`
- Modify: `macos/Suica/Sources/SuicaCore/AgentClient.swift`
- Test: `macos/Suica/Tests/SuicaCoreTests/DashboardContractTests.swift`, `DashboardClientTests.swift`, `ProcessRunnerTests.swift` (stdin case)

**Interfaces:**
- Consumes: the three golden files (Tasks 3–5); existing `Invocation`, `CommandRunning`, `ProcessRunner`, `AgentError`, `lastLine`, `CLIAgentClient`.
- Produces (all `public`, `Sendable`, `Equatable`):
  - `enum JSONValue: Codable { case null, bool(Bool), int(Int), string(String), array([JSONValue]), object([String: JSONValue]) }` (a JSON number with a fraction decodes as `badOutput`).
  - `StatusDocument`, `StatsDocument` (with `DayStats`, `PollCounts`, `Turnaround`, `PollEntry`), `ConfigDocument` (with `ConfigField`: `path: [String]`, `type: FieldType`, `label`, `help`, `options: [String]?`, `placeholder: String?`, `restartNote: String?`, `value: JSONValue`, `effective: JSONValue`; `ConfigIssue`), `SaveResult` — field names exactly as the Node JSON; `enum FieldType: String, Codable { case string, int, bool, `enum`, clock, weekdays, stringList, emailMap, unknown }` (unknown strings decode as `.unknown`, rendered read-only).
  - `func decodeDocument<T: Decodable>(_ type: T.Type, from data: Data) throws(AgentError) -> T` (version check first, like `decodeAgentState`).
  - `Invocation.stdin: Data?` (new init parameter with default `nil`); `ProcessRunner` writes it to a pipe and closes it, else `nullDevice`.
  - `protocol DashboardClient: Sendable { func status() async throws(AgentError) -> StatusDocument; func stats() async throws(AgentError) -> StatsDocument; func config() async throws(AgentError) -> ConfigDocument; func saveConfig(base: String?, edits: [ConfigEditRequest]) async throws(AgentError) -> SaveResult; func restartAgent() async throws(AgentError) -> ActionResult }` with `struct ConfigEditRequest: Encodable { path: [String]; value: JSONValue }`.
  - `CLIAgentClient: DashboardClient` — arguments `["status","--json"]`, `["stats"]`, `["config","show","--json"]`, `["config","set","--json"]` with the encoded `{"baseSha256":…,"edits":[…]}` on stdin, `["agent","restart","--json"]`; 20 s timeouts except restart 30 s. `saveConfig` decodes `SaveResult` even on exit 1 (like `action`).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func statusMatchesTheGoldenFile() throws { /* decodeDocument(StatusDocument.self, from: contracts/status.v1.json) → agent.pid == 4242, lastPoll?.durationMs == 1500 */ }
@Test func statsMatchesTheGoldenFile() throws { /* days.count == 2, reviewerAfterNudge.medianMinutes == 120 */ }
@Test func configMatchesTheGoldenFile() throws { /* fields.count == 24, first path ["gitlab","hostname"], value .string("repo.example") */ }
@Test func newerDocumentVersionsAreRejected() { /* version 2 → unsupportedVersion(2) */ }
@Test func unknownFieldTypesDecodeAsUnknown() {}
@Test func saveConfigSendsTheRequestOnStdin() async throws { /* fake runner captures invocation: arguments end ["config","set","--json"], stdin decodes to baseSha256 + edits */ }
@Test func saveConfigReadsAnInvalidResultOnExitOne() async throws {}
@Test func restartUsesItsCommand() async throws {}
@Test func runnerPassesStdinToTheChild() async throws { /* /bin/cat with stdin "hello" → stdout "hello" */ }
```

(Contract tests find `contracts/` the way `ContractTests.swift` already does.)

- [ ] **Step 2: Run to verify they fail**

Run: `cd macos/Suica && swift test`
Expected: FAIL — `cannot find 'StatusDocument' in scope`.

- [ ] **Step 3: Implement** `Dashboard.swift` and the `AgentClient.swift` changes.

- [ ] **Step 4: Run the tests**

Run: `cd macos/Suica && swift test`
Expected: all pass, the existing ones included.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: decode the status, stats and config documents in the app"
```

---

### Task 8: Window and config editor view models

**Files:**
- Create: `macos/Suica/Sources/SuicaCore/WindowModel.swift`, `macos/Suica/Sources/SuicaCore/ConfigEditorModel.swift`
- Modify: `macos/Suica/Sources/SuicaCore/Copy.swift`
- Test: `macos/Suica/Tests/SuicaCoreTests/WindowTests.swift`, `ConfigEditorModelTests.swift`

**Interfaces:**
- Consumes: `DashboardClient`, documents (Task 7); `MenuModel`, `AgentError` (existing).
- Produces (`@MainActor @Observable public final class`):
  - `WindowModel(client: any DashboardClient, menu: MenuModel)`: `status: StatusDocument?`, `stats: StatsDocument?` (last good values kept on failure), `errorText: String?`, `banner: String?`, `restarting: Bool`; `let menu: MenuModel` (the same instance the popover uses); `func refresh() async` (status and stats, latest-wins like `MenuModel.refresh`); `func runRefreshLoop(every: Duration) async`; `func restartAgent() async` (ignored while `restarting`; banner `Copy.flash(for:)` of the code; refresh after).
  - `ConfigEditorModel(client: any DashboardClient)`: `document: ConfigDocument?`, `drafts: [String: JSONValue]` keyed by `path.joined(separator: ".")`, `fieldIssues: [String: String]`, `banner: String?`, `saving: Bool`, `restartSuggested: Bool`; `func load() async`; `func value(of field: ConfigField) -> JSONValue` (draft, else `effective` when not null, else `value`); `func set(_ field: ConfigField, _ value: JSONValue)`; `func resetToDefault(_ field: ConfigField)` (draft `.null`); `var isDirty: Bool`; `func discard()`; `func save() async` (ignored while `saving` or not dirty; sends `document.sha256` as base; `saved` → drafts cleared, `restartSuggested = true`, reload; `invalid` → `fieldIssues` from issues, drafts kept; `conflict` → `banner = Copy.configConflict`, drafts kept; `bad-request` → `banner = Copy.configBadRequest`).
- Copy (exact): `openWindow = "Open Suica…"`; sections `overview = "Overview"`, `messages = "Messages"`, `statistics = "Statistics"`, `configuration = "Configuration"`; `agentRunning = "Agent running"`, `agentStopped = "Agent installed but not running"`, `agentNotInstalled = "Agent not installed. Run scripts/install-launchagent.sh."`; `lastPoll(_ relative: String, ok: Bool) -> String` → `"Last poll \(relative): ok"` / `"Last poll \(relative): failed"`; `noPollYet = "No poll recorded yet."`; `restartAgent = "Restart agent"`; `restartToApply = "Saved. Restart the agent to apply the changes."`; `save = "Save"`, `discard = "Discard changes"`, `reload = "Reload"`, `resetToDefault = "Use default"`; `configConflict = "The config file changed on disk. Reload to see it; your edits are kept until then."`; `configBadRequest = "This version of the app doesn't match the agent. Rebuild the app."`; `openConfig = "Open config in editor"`, `openTemplates = "Open templates folder"`, `revealInFinder = "Show in Finder"`; stats labels `polls24h = "Polls, last 24 hours"`, `reviewRequests = "Review requests"`, `activity = "Activity on your MRs"`, `nudgesSent = "Nudges sent"`, `noticesSent = "Review notices sent"`, `ownerTurnaround = "Your time to review"`, `reviewerTurnaround = "Reviewers' time after a nudge"`, `noData = "Not enough data yet"`; `minutes(_ m: Int) -> String` → `"\(m) min"` below 60, else `"\(m / 60) h \(m % 60) min"`; `flash(for:)` gains `"restarted": "Agent restarted."`, `"not-installed": Copy.agentNotInstalled`.

- [ ] **Step 1: Write the failing tests** with a `FakeDashboardClient` (actor; scripted results, records calls) and the existing `FakeAgentClient`:

```swift
@Test func refreshKeepsTheLastGoodStatusOnFailure() async {}
@Test func restartIsIgnoredWhileOneIsRunning() async { /* two concurrent restartAgent() → one call */ }
@Test func restartShowsTheResultAndRefreshes() async { /* "not-installed" → banner Copy.agentNotInstalled, status() called again */ }
@Test func windowAndPopoverShareOneModel() async { /* window.menu === menu; send(item) from window while busy from popover → client.send called once */ }
@Test func valueFallsBackFromDraftToEffectiveToFileValue() async {}
@Test func resetToDefaultSendsNull() async { /* save → edits [{path, .null}] */ }
@Test func saveSendsTheBaseShaAndClearsDraftsOnSuccess() async { /* restartSuggested true, load() called again */ }
@Test func invalidMapsIssuesToFields() async { /* issue "polling.activeSeconds" → fieldIssues["polling.activeSeconds"] */ }
@Test func conflictKeepsDrafts() async { /* banner Copy.configConflict, isDirty still true */ }
@Test func saveIsIgnoredWhenNotDirtyOrWhileSaving() async {}
@Test func minutesFormatting() { #expect(Copy.minutes(45) == "45 min"); #expect(Copy.minutes(135) == "2 h 15 min") }
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd macos/Suica && swift test`
Expected: FAIL — `cannot find 'WindowModel' in scope`.

- [ ] **Step 3: Implement** both models and the Copy additions.

- [ ] **Step 4: Run the tests**

Run: `cd macos/Suica && swift test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add the window and config editor view models"
```

---

### Task 9: The window

**Files:**
- Create: `macos/Suica/Sources/Suica/Window/MainWindow.swift`, `OverviewView.swift`, `MessagesView.swift`, `StatisticsView.swift`, `ConfigurationView.swift`, `FieldEditor.swift`
- Modify: `macos/Suica/Sources/Suica/SuicaApp.swift`, `macos/Suica/Sources/Suica/MenuView.swift`
- Test: none (views); the manual check is Step 2.

**Interfaces:**
- Consumes: `WindowModel`, `ConfigEditorModel`, `MenuModel`, `ItemRow`, `Copy`, `DisplayText` (Tasks 7–8, existing).
- Produces:
  - `SuicaApp` builds one `CLIAgentClient`, one `MenuModel`, one `WindowModel(client:menu:)`, one `ConfigEditorModel`; scenes: the existing `MenuBarExtra` and `Window("Suica", id: "main") { MainWindow(…) }` with `.defaultSize(width: 900, height: 620)`. `UnconfiguredClient` also conforms to `DashboardClient` (every call throws `launchFailed`).
  - `MenuView` footer gains a `Copy.openWindow` button: `openWindow(id: "main")`, then `NSApp.activate()`.
  - `MainWindow`: `NavigationSplitView` with a sidebar list of the four sections (SF Symbols `gauge`, `tray.full`, `chart.bar`, `gearshape`). `.onAppear { NSApp.setActivationPolicy(.regular) }`, `.onDisappear { NSApp.setActivationPolicy(.accessory) }`; `.task { await window.runRefreshLoop(every: .seconds(30)) }` (cancelled when the window closes).
  - `OverviewView`: agent line (`agentRunning`/`agentStopped`/`agentNotInstalled`, pid in secondary text), `configError` in a red notice, polling running/paused with the existing pause toggle (`menu.togglePause()`), last poll (`RelativeDateTimeFormatter`, `failure` shown in secondary text), tracked counts from `menu.state`, Teams on/off and attention count, the four paths each with `revealInFinder` (`NSWorkspace.shared.activateFileViewerSelecting`), and **Restart agent** (disabled while `restarting`).
  - `MessagesView`: the popover's attention and recent lists in a `List`, reusing `ItemRow` and the same confirmation flow on `window.menu`.
  - `StatisticsView`: a tile row (`polls24h` "ok / failed", review requests and activity totals over the 14 days, nudges and notices sent, the two turnarounds as `Copy.minutes(median)` with p90 in secondary text, `noData` when null); one Swift Charts `BarMark` chart of `days`, x = day, stacked series review requests / activity / nudges sent / notices sent, system colours, legend below.
  - `ConfigurationView`: `Form` grouped by the first path component (`gitlab`, `polling`, `notifications`, `teams`, and `statePath` under "Storage"); each row is `FieldEditor` — `TextField` (string, with `placeholder`), `TextField` with an integer formatter (int), `Toggle` (bool), `Picker` (enum), `TextField` validated `HH:MM` (clock), seven `Toggle`s Mon–Sun (weekdays), an editable list with add/remove (stringList), a two-column username/email table with add/remove (emailMap), read-only text (unknown); `help` as secondary text; `restartNote` in orange; the issue from `fieldIssues` in red; a `Copy.resetToDefault` button when the file sets the value. Toolbar: `save` (disabled when not dirty or saving), `discard`, `reload`, `openConfig` (`NSWorkspace.shared.open` on the path), `openTemplates`. `restartSuggested` shows `restartToApply` with a **Restart agent** button.

- [ ] **Step 1: Implement** the views and the app wiring.

- [ ] **Step 2: Build, install and check by hand (with a scratch config, not the real one)**

Run: `cd macos/Suica && swift build && swift test && cd ../.. && scripts/install-macos-app.sh`
Expected: build and tests pass; the app restarts. Then by hand: click the menu bar icon → **Open Suica…** opens the window and a Dock icon appears; each section shows data (Statistics may say "Not enough data yet"); closing the window removes the Dock icon; in Configuration, change `polling.idleSeconds`, **Save**, see "Saved. Restart the agent…", then set it back and save again (the file's other lines and comments are unchanged: `git diff --no-index` against a copy taken before). Ask the Owner before pressing **Restart agent** on the real agent.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: add the Suica window with overview, messages, statistics and configuration"
```

---

### Task 10: Documentation

**Files:**
- Modify: `README.md` (section "App window": what each section shows, that config edits apply after Restart agent, that history starts at the upgrade and is kept 90 days; the new commands `suica status --json`, `suica stats`, `suica config show --json`, `suica config set --json`, `suica agent restart --json`; Known limits: "Statistics start when this version is installed", "The window refreshes every 30 seconds while it is open"; contracts list), spec (a "### App window" subsection under Decisions summarising the Design decisions above in four bullets)

- [ ] **Step 1: Update the docs** as listed.

- [ ] **Step 2: Full checks**

Run: `npm run check && (cd macos/Suica && swift test)`
Expected: both pass.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "docs: document the Suica window, statistics and config editor"
```
