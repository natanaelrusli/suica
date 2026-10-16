# MR Review Assistant — Plan 2: Teams chats (Reviewer Nudge and Review Notice)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On top of Plan 1, chat other people in Microsoft Teams as the Owner: a Reviewer Nudge (and one reminder) to the Reviewers of the Owner's MRs, and a Review Notice to the Author after the Owner has reviewed someone else's MR. Messages come from fixed Indonesian templates, can be held for approval, and are sent at most once.

**Architecture:** After each successful poll commit, a pure planner (`plan.ts`) compares the snapshot with the previous state and a small ledger and produces *intents*. Intents are stored idempotently in an SQLite `outbox`. A dispatcher turns queued rows into messages according to the per-flow send mode (`auto`, `approval`, `dry-run`), only inside working hours, and records `sending` **before** anything leaves the machine, so a crash or an error can never cause a second send. Teams is reached through the existing Teams MCP (`~/.config/teams-mcp/run.sh`) with a small in-house stdio MCP client; the whole feature is off until `teams.enabled: true`.

**Tech Stack:** Same as Plan 1. No new runtime dependency: the MCP stdio protocol is a few dozen lines of JSON-RPC, while the official SDK would add about 17 packages (express, hono, jose, …) to a tool that holds the Owner's credentials.

**Spec:** `docs/superpowers/specs/2026-10-14-mr-review-assistant-design.md` (section "Teams (Plan 2)"); vocabulary in `CONTEXT.md`. Builds on `docs/superpowers/plans/2026-10-14-mr-review-assistant-plan-1-foundation-and-alerts.md`, which is implemented on branch `feat/no-ticket-polling-foundation`.

## Global Constraints

- Everything in Plan 1's Global Constraints still applies (Node `>=24` with native type stripping and `.ts` import suffixes, erasable syntax only, Madhani TypeScript standard, exact dependency pins, no `console.log`, JSON logs with the Madhani fields and no employee IDs / names / titles / message text / process arguments, every external call has a timeout, Owner-facing strings Indonesian, everything else English, `no-ticket` branches).
- **No new dependencies** in `package.json`. If a task seems to need one, stop and rule on it in the ledger instead.
- Branch `feat/no-ticket-teams-chats`, cut from the tip of `feat/no-ticket-polling-foundation` (the default branch `trunk` does not exist yet; if Plan 1 has been merged by then, cut from `trunk` instead). MR title `[no-ticket] feat: chat reviewers and authors in Teams`.
- Teams is **disabled by default** (`teams.enabled: false`); both send modes default to `approval`; the Owner flips a flow to `auto` deliberately.
- Message text comes only from the template files / built-in defaults, sent with `format: "text"` (never markdown, never mentions). Every value substituted into a template passes through `clean()` from `src/format.ts` (MR titles and names are written by other people).
- **At most once.** The outbox row is moved to `sending` (compare-and-set) before any Teams call that can deliver a message; a row in `sending`, `sent` or `failed` is never sent again by code. A missed message is acceptable; a duplicate is not. No automatic retry of a send.
- Teams must never block GitLab alerts: Teams work runs after the state commit, MCP calls have timeouts (`startTimeoutSeconds` 30, `callTimeoutSeconds` 60), and a Teams failure never changes the poll status.
- Working hours default Monday–Friday 09:00–17:00 in the Mac's local time zone. Limits: at most 2 messages per MR per Reviewer; a reminder only if the Reviewer is still `UNREVIEWED` 24 hours after the nudge; a Review Notice only after 10 minutes without further change by the Owner. All configurable.
- `search_users` of the Teams MCP builds an OData filter from the raw query string (`startswith(displayName,'<query>')`): single quotes in the query must be doubled before the call. It matches prefixes only, so a person is accepted only on an exact (normalised) display-name match.
- Never run a step that sends a real message to a coworker without the Owner's explicit confirmation in chat. The only automated real send is `mra selftest` to the Owner's own notes chat `48:notes`.

## Review Focus

1. **Upgrade path** — the Owner's Plan 1 database is already baselined and full of MRs the Owner reviewed long ago. Switching Teams on must not message anyone about history: no nudge for existing Reviewers, no notice for reviews the Owner gave before Teams was enabled. Tests: `test/plan.test.ts` ("Teams baseline").
2. **Awkward names** — GitLab display names with `'`, `%`, `\`, emoji, accents or 300 characters, in `search_users` queries (OData) and in the chat text. Tests: `test/teams-api.test.ts`, `test/dispatch.test.ts` (sanitised values).
3. **Never guess a person** — a prefix match ("Rayhan" finds "Rayhan Aswiansyah"), two people with the same display name, a deleted GitLab user (`ghost`), and a Teams user without `mail`. Tests: `test/identity.test.ts`.
4. **Send exactly once** — Teams call fails or the process dies after the row is `sending`; `mra send` run twice at once or alongside the daemon; changing a flow from `approval` to `auto` while old rows are `pending`. Tests: `test/dispatch.test.ts` ("at most once" group).
5. **Slow or broken Teams MCP** — the server never answers `initialize`, hangs on a call, exits, or the command is missing; none of this may delay or suppress GitLab alerts. Tests: `test/mcp.test.ts`, `test/poller-teams.test.ts`.
6. **Working-hours edges** — exactly the end minute, weekends, a custom `days` list including Sunday (`7`), and a message created outside hours that must wait (not be dropped). Tests: `test/hours.test.ts`, `test/dispatch.test.ts`.

## File Structure

| File | Responsibility |
|---|---|
| `src/config.ts` (modify) | `teams` section of the YAML schema |
| `src/teams/types.ts` | Shared types and constant lists: intents, plan, ledger state, outbox rows, template names |
| `src/teams/hours.ts` | `isWithinWorkingHours` |
| `src/gitlab.ts` (modify) | Fetch the Owner's notes on review-requested MRs too |
| `src/teams/plan.ts` | Pure planner: snapshot + previous + ledger → intents and ledger updates |
| `src/teams/templates.ts` | Default Indonesian templates, loading, validation, rendering |
| `src/teams/mcp.ts` | Minimal stdio MCP client (`initialize`, `tools/call`) |
| `src/teams/api.ts` | `TeamsApi` over MCP tool calls: output parsing, OData escaping, `TeamsFailure` |
| `src/teams/gateway.ts` | One MCP session per use: spawn, run, always close |
| `src/teams/identity.ts` | GitLab person → Teams email: people map, cache, exact name match |
| `src/store.ts` (modify) | Schema v2: outbox, nudge ledger, review rounds, identity cache; compare-and-set transitions |
| `src/teams/dispatch.ts` | Outbox → messages by mode, hours and the at-most-once rule; `mra` helpers |
| `src/teams/service.ts` | `TeamsService`: plan + dispatch + CLI operations behind one object |
| `src/teams/format-outbox.ts` | Text listing for `mra pending` |
| `src/failures.ts`, `src/poller.ts`, `src/runtime.ts`, `src/cli.ts` (modify) | Wiring: failure kinds, post-commit Teams step, runtime, CLI commands |
| `test/*.test.ts`, `test/teams-builders.ts`, `test/fixtures/fake-mcp-server.ts` | Tests and fixtures |

---

### Task 1: Teams configuration and working hours

**Files:**
- Modify: `src/config.ts`
- Create: `src/teams/hours.ts`
- Modify (replace whole file): `test/config.test.ts`
- Test: `test/hours.test.ts`

**Interfaces:**
- Produces: `Config["teams"]` with `enabled`, `command?`, `startTimeoutSeconds`, `callTimeoutSeconds`, `modes {nudge, notice}` (each `"auto" | "approval" | "dry-run"`), `workingHours {start, end, days}`, `reminderAfterHours`, `noticeDebounceMinutes`, `maxMessagesPerReviewer`, `templatesPath?`, `people` (record username → email); `isWithinWorkingHours(now: Date, hours: Config["teams"]["workingHours"]): boolean`.

- [ ] **Step 1: Branch**

```bash
cd ~/project/suica
git switch feat/no-ticket-polling-foundation
git switch -c feat/no-ticket-teams-chats
```

- [ ] **Step 2: Write the failing tests**

`test/hours.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { isWithinWorkingHours } from "../src/teams/hours.ts";

const hours = { start: "09:00", end: "17:00", days: [1, 2, 3, 4, 5] };
// Local times: 2026-10-14 is a Wednesday, 2026-10-17 a Saturday, 2026-10-18 a Sunday.
const at = (day: number, hour: number, minute = 0): Date => new Date(2026, 9, day, hour, minute);

describe("isWithinWorkingHours", () => {
  it("includes the start minute and excludes the end minute on a working day", () => {
    expect(isWithinWorkingHours(at(14, 8, 59), hours)).toBe(false);
    expect(isWithinWorkingHours(at(14, 9, 0), hours)).toBe(true);
    expect(isWithinWorkingHours(at(14, 16, 59), hours)).toBe(true);
    expect(isWithinWorkingHours(at(14, 17, 0), hours)).toBe(false);
  });

  it("is false on days that are not listed", () => {
    expect(isWithinWorkingHours(at(17, 10), hours)).toBe(false);
    expect(isWithinWorkingHours(at(18, 10), hours)).toBe(false);
  });

  it("numbers Sunday as 7 in a custom day list", () => {
    expect(isWithinWorkingHours(at(18, 10), { ...hours, days: [7] })).toBe(true);
    expect(isWithinWorkingHours(at(17, 10), { ...hours, days: [6, 7] })).toBe(true);
  });
});
```

`test/config.test.ts` (replace the whole file; the first test now expects the `teams` defaults):

```ts
import { describe, expect, it } from "vitest";
import { ConfigError, parseConfig } from "../src/config.ts";

const MINIMAL = "gitlab:\n  hostname: gitlab.example\n";

describe("parseConfig", () => {
  it("applies every default to a minimal config", () => {
    expect(parseConfig(MINIMAL)).toEqual({
      gitlab: { hostname: "gitlab.example", glabPath: "glab", timeoutSeconds: 60 },
      polling: {
        activeSeconds: 120,
        idleSeconds: 300,
        idleAfterSeconds: 300,
        maxBackoffSeconds: 900,
      },
      notifications: { summaryThreshold: 4, ignoreAuthors: [] },
      teams: {
        enabled: false,
        startTimeoutSeconds: 30,
        callTimeoutSeconds: 60,
        modes: { nudge: "approval", notice: "approval" },
        workingHours: { start: "09:00", end: "17:00", days: [1, 2, 3, 4, 5] },
        reminderAfterHours: 24,
        noticeDebounceMinutes: 10,
        maxMessagesPerReviewer: 2,
        people: {},
      },
    });
  });

  it("lets values be overridden", () => {
    const config = parseConfig(
      `${MINIMAL}polling:\n  activeSeconds: 60\nnotifications:\n  ignoreAuthors: [ci-bot]\nstatePath: /tmp/state.db\n`,
    );
    expect(config.polling.activeSeconds).toBe(60);
    expect(config.notifications.ignoreAuthors).toEqual(["ci-bot"]);
    expect(config.statePath).toBe("/tmp/state.db");
  });

  it("rejects unknown keys so typos are not silently ignored", () => {
    expect(() => parseConfig(`${MINIMAL}polling:\n  activeSecs: 5\n`)).toThrow(ConfigError);
    expect(() => parseConfig(`${MINIMAL}teams:\n  enable: true\n`)).toThrow(ConfigError);
  });

  it("rejects non-positive intervals", () => {
    expect(() => parseConfig(`${MINIMAL}polling:\n  activeSeconds: 0\n`)).toThrow(ConfigError);
  });

  it("rejects a missing GitLab hostname and names the field", () => {
    expect(() => parseConfig("polling: {}\n")).toThrow(/gitlab/);
  });

  it("rejects invalid YAML and an empty file", () => {
    expect(() => parseConfig("gitlab: [unclosed")).toThrow(ConfigError);
    expect(() => parseConfig("")).toThrow(ConfigError);
  });
});

describe("teams section", () => {
  it("lets each flow have its own send mode", () => {
    const config = parseConfig(
      `${MINIMAL}teams:\n  enabled: true\n  modes:\n    nudge: dry-run\n    notice: auto\n`,
    );
    expect(config.teams.enabled).toBe(true);
    expect(config.teams.modes).toEqual({ nudge: "dry-run", notice: "auto" });
  });

  it("rejects an unknown send mode", () => {
    expect(() => parseConfig(`${MINIMAL}teams:\n  modes:\n    nudge: yolo\n`)).toThrow(ConfigError);
  });

  it("rejects malformed or inverted working hours and bad weekdays", () => {
    expect(() => parseConfig(`${MINIMAL}teams:\n  workingHours:\n    start: "9am"\n`)).toThrow(
      ConfigError,
    );
    expect(() =>
      parseConfig(`${MINIMAL}teams:\n  workingHours:\n    start: "17:00"\n    end: "09:00"\n`),
    ).toThrow(/before/);
    expect(() => parseConfig(`${MINIMAL}teams:\n  workingHours:\n    days: [0]\n`)).toThrow(
      ConfigError,
    );
  });

  it("accepts a people map of GitLab usernames to emails and rejects anything else", () => {
    const config = parseConfig(`${MINIMAL}teams:\n  people:\n    "20435": rayhan@madhani.id\n`);
    expect(config.teams.people).toEqual({ "20435": "rayhan@madhani.id" });
    expect(() => parseConfig(`${MINIMAL}teams:\n  people:\n    "20435": not-an-email\n`)).toThrow(
      ConfigError,
    );
  });
});
```

- [ ] **Step 3: Run to verify they fail**

Run: `npx vitest run test/hours.test.ts test/config.test.ts`
Expected: FAIL — cannot resolve `../src/teams/hours.ts`; and the config tests fail because `teams` is missing from the parsed config.

- [ ] **Step 4: Implement**

In `src/config.ts`, add these two constants above `const configSchema`:

```ts
const sendModeSchema = z.enum(["auto", "approval", "dry-run"]);
const clockSchema = z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/, "must be HH:MM (24 hours)");
```

and insert this property into the top-level `z.object({ … })` of `configSchema`, right after the `notifications` property:

```ts
    teams: z
      .object({
        enabled: z.boolean().default(false),
        command: z.string().min(1).optional(),
        startTimeoutSeconds: positiveInt.default(30),
        callTimeoutSeconds: positiveInt.default(60),
        modes: z
          .object({
            nudge: sendModeSchema.default("approval"),
            notice: sendModeSchema.default("approval"),
          })
          .strict()
          .default({}),
        workingHours: z
          .object({
            start: clockSchema.default("09:00"),
            end: clockSchema.default("17:00"),
            days: z.array(z.number().int().min(1).max(7)).min(1).default([1, 2, 3, 4, 5]),
          })
          .strict()
          .refine((hours) => hours.start < hours.end, "start must be before end")
          .default({}),
        reminderAfterHours: positiveInt.default(24),
        noticeDebounceMinutes: positiveInt.default(10),
        maxMessagesPerReviewer: positiveInt.default(2),
        templatesPath: z.string().min(1).optional(),
        people: z.record(z.string(), z.string().email()).default({}),
      })
      .strict()
      .default({}),
```

`src/teams/hours.ts`:

```ts
import type { Config } from "../config.ts";

type WorkingHours = Config["teams"]["workingHours"];

function minutesOfDay(clock: string): number {
  const match = /^(\d\d):(\d\d)$/.exec(clock);
  return Number(match?.[1]) * 60 + Number(match?.[2]);
}

/** Local time of the Mac. Days are ISO numbers: Monday is 1, Sunday is 7. */
export function isWithinWorkingHours(now: Date, hours: WorkingHours): boolean {
  const isoDay = now.getDay() === 0 ? 7 : now.getDay();
  if (!hours.days.includes(isoDay)) return false;
  const current = now.getHours() * 60 + now.getMinutes();
  return current >= minutesOfDay(hours.start) && current < minutesOfDay(hours.end);
}
```

- [ ] **Step 5: Run the checks**

Run: `npx prettier --write . && npm run check`
Expected: all pass (the 6 old config tests, 4 new config tests, 3 hours tests, everything from Plan 1).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: add the teams configuration section and working hours"
```

---

### Task 2: Shared types and schema v2 (outbox, ledger, identity cache)

**Files:**
- Create: `src/teams/types.ts`, `test/teams-builders.ts`
- Modify: `src/store.ts`
- Test: `test/store-teams.test.ts`

**Interfaces:**
- Produces (types): `TEMPLATE_NAMES`/`TemplateName`, `OUTBOX_KINDS`/`OutboxKind`, `OUTBOX_STATUSES`/`OutboxStatus`, `ATTENTION_STATUSES`, `isTemplateName`, `isOutboxKind`, `isOutboxStatus`, `IntentMr`, `Intent`, `NudgeRecord`, `Round`, `TeamsState`, `TeamsPlan`, `OutboxRow` (exact shapes below).
- Produces (store, added to `Store`): `loadTeams(): TeamsState`; `applyTeamsPlan(plan: TeamsPlan, now: number): number` (number of new outbox rows); `listOutbox(statuses: readonly OutboxStatus[]): OutboxRow[]` (oldest first); `getOutbox(id: number): OutboxRow | undefined`; `transitionOutbox(id: number, from: OutboxStatus, to: OutboxStatus, fields: { detail?: string; text?: string }, now: number): boolean` (compare-and-set); `loadIdentity(username: string): string | undefined`; `saveIdentity(username: string, email: string, now: number): void`.

- [ ] **Step 1: Write the shared types and builders**

`src/teams/types.ts`:

```ts
import type { Person, ReviewState } from "../domain.ts";

export const TEMPLATE_NAMES = [
  "nudge",
  "reminder",
  "notice.approved",
  "notice.changes",
  "notice.comments",
] as const;
export type TemplateName = (typeof TEMPLATE_NAMES)[number];

export const OUTBOX_KINDS = ["nudge", "reminder", "notice"] as const;
export type OutboxKind = (typeof OUTBOX_KINDS)[number];

export const OUTBOX_STATUSES = [
  "queued",
  "pending",
  "sending",
  "sent",
  "skipped",
  "failed",
  "unresolved",
  "dry-run",
] as const;
export type OutboxStatus = (typeof OUTBOX_STATUSES)[number];

/** Rows that need the Owner's attention; `mra pending` lists these by default. */
export const ATTENTION_STATUSES: readonly OutboxStatus[] = [
  "pending",
  "unresolved",
  "failed",
  "sending",
];

export function isTemplateName(value: string): value is TemplateName {
  return (TEMPLATE_NAMES as readonly string[]).includes(value);
}
export function isOutboxKind(value: string): value is OutboxKind {
  return (OUTBOX_KINDS as readonly string[]).includes(value);
}
export function isOutboxStatus(value: string): value is OutboxStatus {
  return (OUTBOX_STATUSES as readonly string[]).includes(value);
}

export interface IntentMr {
  readonly key: string;
  readonly iid: number;
  readonly projectPath: string;
  readonly title: string;
  readonly url: string;
}

/** A message the planner wants to send; stored idempotently under `dedupeKey`. */
export interface Intent {
  readonly dedupeKey: string;
  readonly kind: OutboxKind;
  readonly variant: TemplateName;
  readonly mr: IntentMr;
  readonly recipient: Person;
}

export interface NudgeRecord {
  readonly sentCount: number;
  readonly lastSentAt: number;
}

/** The Owner's review activity on one MR where the Owner is a Reviewer. */
export interface Round {
  readonly myState: ReviewState;
  readonly myNotes: number;
  readonly changedAt: number;
  readonly noticedState: ReviewState;
  readonly noticedNotes: number;
}

export interface TeamsState {
  /** False until the first plan has been applied: history is recorded, never announced. */
  readonly baselineDone: boolean;
  /** Key is `reviewerKey(mrKey, username)`. */
  readonly nudges: ReadonlyMap<string, NudgeRecord>;
  /** Key is the MR key. */
  readonly rounds: ReadonlyMap<string, Round>;
}

export interface TeamsPlan {
  readonly intents: readonly Intent[];
  readonly nudgeUpdates: readonly { readonly key: string; readonly record: NudgeRecord }[];
  readonly roundUpdates: readonly { readonly mrKey: string; readonly round: Round }[];
  /** Ledger rows not listed here are deleted (the MR or Reviewer is gone). */
  readonly keepNudges: readonly string[];
  readonly keepRounds: readonly string[];
  readonly baselineDone: boolean;
}

export interface OutboxRow {
  readonly id: number;
  readonly dedupeKey: string;
  readonly kind: OutboxKind;
  readonly variant: TemplateName;
  readonly mrKey: string;
  readonly mrIid: number;
  readonly mrProject: string;
  readonly mrTitle: string;
  readonly mrUrl: string;
  /** GitLab username of the person who receives the chat. */
  readonly recipient: string;
  readonly recipientName: string;
  readonly status: OutboxStatus;
  readonly detail: string;
  /** Rendered text, once the row left `queued`. */
  readonly text: string | null;
  readonly createdAt: number;
  readonly updatedAt: number;
}
```

`test/teams-builders.ts`:

```ts
import type { Intent, TeamsPlan } from "../src/teams/types.ts";
import { person } from "./builders.ts";

export const NOW = Date.UTC(2026, 9, 14, 3, 0);

export function intent(slot: number, overrides: Partial<Intent> = {}): Intent {
  return {
    dedupeKey: `nudge:g/p!5|bob:${slot}`,
    kind: "nudge",
    variant: "nudge",
    mr: {
      key: "g/p!5",
      iid: 5,
      projectPath: "g/p",
      title: "Add thing",
      url: "https://gitlab.example/g/p/-/merge_requests/5",
    },
    recipient: person("bob", "Bob"),
    ...overrides,
  };
}

export function teamsPlan(overrides: Partial<TeamsPlan> = {}): TeamsPlan {
  return {
    intents: [],
    nudgeUpdates: [],
    roundUpdates: [],
    keepNudges: [],
    keepRounds: [],
    baselineDone: true,
    ...overrides,
  };
}
```

- [ ] **Step 2: Write the failing store tests**

`test/store-teams.test.ts`:

```ts
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, describe, expect, it } from "vitest";
import { openStore } from "../src/store.ts";
import type { Round } from "../src/teams/types.ts";
import { mr, reviewer, snapshot } from "./builders.ts";
import { NOW, intent, teamsPlan } from "./teams-builders.ts";

const folders: string[] = [];
afterEach(() => {
  for (const folder of folders.splice(0)) rmSync(folder, { recursive: true, force: true });
});
function tempDb(): string {
  const folder = mkdtempSync(join(tmpdir(), "mra-store2-"));
  folders.push(folder);
  return join(folder, "state.db");
}

const round: Round = {
  myState: "APPROVED",
  myNotes: 1,
  changedAt: NOW,
  noticedState: "UNREVIEWED",
  noticedNotes: 0,
};
const DAY = 24 * 3_600_000;

describe("schema v2", () => {
  it("migrates a version 1 database in place and keeps its data", () => {
    const path = tempDb();
    const old = new DatabaseSync(path);
    old.exec(`
      CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE tracked_authored (mr_key TEXT PRIMARY KEY);
      CREATE TABLE my_review_state (mr_key TEXT PRIMARY KEY, state TEXT NOT NULL);
      CREATE TABLE reviewer_state (mr_key TEXT NOT NULL, username TEXT NOT NULL, state TEXT NOT NULL, PRIMARY KEY (mr_key, username));
      CREATE TABLE seen_note (note_id TEXT PRIMARY KEY);
      INSERT INTO meta (key, value) VALUES ('baseline_done', '1');
      PRAGMA user_version = 1;
    `);
    old.close();

    const store = openStore(path);
    expect(store.load().baselineDone).toBe(true);
    expect(store.loadTeams()).toEqual({
      baselineDone: false,
      nudges: new Map(),
      rounds: new Map(),
    });
    store.close();

    const raw = new DatabaseSync(path);
    expect(raw.prepare("PRAGMA user_version").get()?.["user_version"]).toBe(2);
    raw.close();
  });
});

describe("applyTeamsPlan", () => {
  it("queues intents once, whatever the number of times the same plan is applied", () => {
    const store = openStore(":memory:");
    const plan = teamsPlan({ intents: [intent(1)] });
    expect(store.applyTeamsPlan(plan, NOW)).toBe(1);
    expect(store.applyTeamsPlan(plan, NOW + 1000)).toBe(0);
    const rows = store.listOutbox(["queued"]);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      dedupeKey: "nudge:g/p!5|bob:1",
      kind: "nudge",
      variant: "nudge",
      mrKey: "g/p!5",
      mrIid: 5,
      mrProject: "g/p",
      mrTitle: "Add thing",
      recipient: "bob",
      recipientName: "Bob",
      status: "queued",
      detail: "",
      text: null,
      createdAt: NOW,
      updatedAt: NOW,
    });
  });

  it("records the ledger and the Teams baseline", () => {
    const store = openStore(":memory:");
    store.applyTeamsPlan(
      teamsPlan({
        nudgeUpdates: [{ key: "g/p!5|bob", record: { sentCount: 1, lastSentAt: NOW } }],
        roundUpdates: [{ mrKey: "g/p!7", round }],
        keepNudges: ["g/p!5|bob"],
        keepRounds: ["g/p!7"],
      }),
      NOW,
    );
    expect(store.loadTeams()).toEqual({
      baselineDone: true,
      nudges: new Map([["g/p!5|bob", { sentCount: 1, lastSentAt: NOW }]]),
      rounds: new Map([["g/p!7", round]]),
    });
  });

  it("deletes ledger rows that are no longer kept, and old finished outbox rows", () => {
    const store = openStore(":memory:");
    store.applyTeamsPlan(
      teamsPlan({
        intents: [intent(1), intent(2)],
        nudgeUpdates: [
          { key: "a|x", record: { sentCount: 1, lastSentAt: NOW } },
          { key: "b|y", record: { sentCount: 1, lastSentAt: NOW } },
        ],
        roundUpdates: [
          { mrKey: "a", round },
          { mrKey: "b", round },
        ],
        keepNudges: ["a|x", "b|y"],
        keepRounds: ["a", "b"],
      }),
      NOW - 100 * DAY,
    );
    const [first, second] = store.listOutbox(["queued"]);
    store.transitionOutbox(first?.id ?? 0, "queued", "sent", {}, NOW - 100 * DAY);
    expect(second?.status).toBe("queued");

    store.applyTeamsPlan(teamsPlan({ keepNudges: ["a|x"], keepRounds: ["a"] }), NOW);
    const state = store.loadTeams();
    expect([...state.nudges.keys()]).toEqual(["a|x"]);
    expect([...state.rounds.keys()]).toEqual(["a"]);
    // The 100-day-old sent row is pruned; the unfinished queued row stays however old it is.
    expect(store.listOutbox(["sent"])).toHaveLength(0);
    expect(store.listOutbox(["queued"])).toHaveLength(1);
  });

  it("is untouched by the Plan 1 commit", () => {
    const store = openStore(":memory:");
    store.applyTeamsPlan(teamsPlan({ intents: [intent(1)], keepRounds: ["g/p!7"], roundUpdates: [{ mrKey: "g/p!7", round }] }), NOW);
    store.commit(snapshot({ reviewRequested: [mr(1, { reviewers: [reviewer("me", "UNREVIEWED")] })] }));
    expect(store.listOutbox(["queued"])).toHaveLength(1);
    expect(store.loadTeams().rounds.size).toBe(1);
  });
});

describe("outbox transitions", () => {
  it("is a compare-and-set: only one caller can move a row out of a status", () => {
    const store = openStore(":memory:");
    store.applyTeamsPlan(teamsPlan({ intents: [intent(1)] }), NOW);
    const id = store.listOutbox(["queued"])[0]?.id ?? 0;
    expect(store.transitionOutbox(id, "queued", "pending", { text: "halo" }, NOW + 1)).toBe(true);
    expect(store.transitionOutbox(id, "queued", "sending", {}, NOW + 2)).toBe(false);
    expect(store.getOutbox(id)).toMatchObject({ status: "pending", text: "halo", updatedAt: NOW + 1 });
  });

  it("keeps the text when a later transition does not provide one, and can overwrite the detail", () => {
    const store = openStore(":memory:");
    store.applyTeamsPlan(teamsPlan({ intents: [intent(1)] }), NOW);
    const id = store.listOutbox(["queued"])[0]?.id ?? 0;
    store.transitionOutbox(id, "queued", "pending", { text: "halo" }, NOW);
    store.transitionOutbox(id, "pending", "failed", { detail: "error" }, NOW);
    expect(store.getOutbox(id)).toMatchObject({ status: "failed", text: "halo", detail: "error" });
  });

  it("lists by status, oldest first, and returns undefined for an unknown id", () => {
    const store = openStore(":memory:");
    store.applyTeamsPlan(teamsPlan({ intents: [intent(1), intent(2)] }), NOW);
    const ids = store.listOutbox(["queued"]).map((row) => row.id);
    expect(ids).toHaveLength(2);
    expect(ids[0]).toBeLessThan(ids[1] ?? 0);
    expect(store.listOutbox(["sent", "failed"])).toEqual([]);
    expect(store.getOutbox(9999)).toBeUndefined();
  });
});

describe("identity cache", () => {
  it("saves and loads an email per GitLab username", () => {
    const store = openStore(":memory:");
    expect(store.loadIdentity("20435")).toBeUndefined();
    store.saveIdentity("20435", "rayhan@madhani.id", NOW);
    store.saveIdentity("20435", "rayhan.new@madhani.id", NOW + 1);
    expect(store.loadIdentity("20435")).toBe("rayhan.new@madhani.id");
  });
});
```

- [ ] **Step 3: Run to verify they fail**

Run: `npx vitest run test/store-teams.test.ts`
Expected: FAIL — `store.loadTeams is not a function` (and the migration test fails on the schema version).

- [ ] **Step 4: Implement the store changes**

In `src/store.ts`:

1. Add imports (next to the existing ones):

```ts
import { isOutboxKind, isOutboxStatus, isTemplateName } from "./teams/types.ts";
import type {
  NudgeRecord,
  OutboxRow,
  OutboxStatus,
  Round,
  TeamsPlan,
  TeamsState,
} from "./teams/types.ts";
```

2. Extend the `Store` interface (add after `setPaused`):

```ts
  loadTeams(): TeamsState;
  /** Queues the plan's intents (idempotent per `dedupeKey`) and updates the ledger in one transaction. */
  applyTeamsPlan(plan: TeamsPlan, now: number): number;
  listOutbox(statuses: readonly OutboxStatus[]): OutboxRow[];
  getOutbox(id: number): OutboxRow | undefined;
  /** Compare-and-set: true only for the one caller that found the row in `from`. */
  transitionOutbox(
    id: number,
    from: OutboxStatus,
    to: OutboxStatus,
    fields: { detail?: string; text?: string },
    now: number,
  ): boolean;
  loadIdentity(username: string): string | undefined;
  saveIdentity(username: string, email: string, now: number): void;
```

3. Replace `const SCHEMA_VERSION = 1;` with these constants (keep the existing `SCHEMA` constant as is):

```ts
const SCHEMA_VERSION = 2;
const SCHEMA_V2 = `
CREATE TABLE IF NOT EXISTS outbox (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  dedupe_key TEXT NOT NULL UNIQUE,
  kind TEXT NOT NULL,
  variant TEXT NOT NULL,
  mr_key TEXT NOT NULL,
  mr_iid INTEGER NOT NULL,
  mr_project TEXT NOT NULL,
  mr_title TEXT NOT NULL,
  mr_url TEXT NOT NULL,
  recipient TEXT NOT NULL,
  recipient_name TEXT NOT NULL,
  status TEXT NOT NULL,
  detail TEXT NOT NULL DEFAULT '',
  text TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS outbox_status ON outbox (status);
CREATE TABLE IF NOT EXISTS nudge_state (
  key TEXT PRIMARY KEY,
  sent_count INTEGER NOT NULL,
  last_sent_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS review_round (
  mr_key TEXT PRIMARY KEY,
  my_state TEXT NOT NULL,
  my_notes INTEGER NOT NULL,
  changed_at INTEGER NOT NULL,
  noticed_state TEXT NOT NULL,
  noticed_notes INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS identity (
  username TEXT PRIMARY KEY,
  email TEXT NOT NULL,
  resolved_at INTEGER NOT NULL
);
`;
const META_TEAMS_BASELINE = "teams_baseline_done";
const FINISHED_STATUSES = ["sent", "skipped", "failed", "dry-run"] as const;
const OUTBOX_RETENTION_MS = 90 * 24 * 3_600_000;
```

4. Replace the body of `initSchema` with:

```ts
function initSchema(db: DatabaseSync): void {
  const found = db.prepare("PRAGMA user_version").get()?.["user_version"];
  const version = typeof found === "number" ? found : 0;
  if (version > SCHEMA_VERSION) {
    throw new Error(`state database schema ${version} is newer than supported ${SCHEMA_VERSION}`);
  }
  if (version === 0) db.exec(SCHEMA);
  if (version < 2) db.exec(SCHEMA_V2);
  if (version !== SCHEMA_VERSION) db.exec(`PRAGMA user_version = ${SCHEMA_VERSION}`);
}
```

5. Add this helper next to `text(...)`:

```ts
function integer(row: Row, column: string): number {
  const value = row[column];
  if (typeof value !== "number") throw new Error(`column ${column} is not an integer`);
  return value;
}

function toOutboxRow(row: Row): OutboxRow {
  const kind = text(row, "kind");
  const variant = text(row, "variant");
  const status = text(row, "status");
  if (!isOutboxKind(kind) || !isTemplateName(variant) || !isOutboxStatus(status)) {
    throw new Error("outbox row has an unknown kind, variant or status");
  }
  const stored = row["text"];
  return {
    id: integer(row, "id"),
    dedupeKey: text(row, "dedupe_key"),
    kind,
    variant,
    mrKey: text(row, "mr_key"),
    mrIid: integer(row, "mr_iid"),
    mrProject: text(row, "mr_project"),
    mrTitle: text(row, "mr_title"),
    mrUrl: text(row, "mr_url"),
    recipient: text(row, "recipient"),
    recipientName: text(row, "recipient_name"),
    status,
    detail: text(row, "detail"),
    text: typeof stored === "string" ? stored : null,
    createdAt: integer(row, "created_at"),
    updatedAt: integer(row, "updated_at"),
  };
}
```

6. In the object returned by `openStore`, add these methods before `isPaused:`:

```ts
    loadTeams() {
      const nudges = new Map<string, NudgeRecord>();
      for (const row of rows("SELECT key, sent_count, last_sent_at FROM nudge_state")) {
        nudges.set(text(row, "key"), {
          sentCount: integer(row, "sent_count"),
          lastSentAt: integer(row, "last_sent_at"),
        });
      }
      const rounds = new Map<string, Round>();
      for (const row of rows("SELECT * FROM review_round")) {
        rounds.set(text(row, "mr_key"), {
          myState: text(row, "my_state"),
          myNotes: integer(row, "my_notes"),
          changedAt: integer(row, "changed_at"),
          noticedState: text(row, "noticed_state"),
          noticedNotes: integer(row, "noticed_notes"),
        });
      }
      return { baselineDone: metaValue(META_TEAMS_BASELINE) === "1", nudges, rounds };
    },

    applyTeamsPlan(plan, now) {
      const insertOutbox = db.prepare(
        `INSERT OR IGNORE INTO outbox
           (dedupe_key, kind, variant, mr_key, mr_iid, mr_project, mr_title, mr_url,
            recipient, recipient_name, status, detail, text, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'queued', '', NULL, ?, ?)`,
      );
      const upsertNudge = db.prepare(
        `INSERT INTO nudge_state (key, sent_count, last_sent_at) VALUES (?, ?, ?)
         ON CONFLICT(key) DO UPDATE SET
           sent_count = excluded.sent_count, last_sent_at = excluded.last_sent_at`,
      );
      const upsertRound = db.prepare(
        `INSERT INTO review_round
           (mr_key, my_state, my_notes, changed_at, noticed_state, noticed_notes)
         VALUES (?, ?, ?, ?, ?, ?)
         ON CONFLICT(mr_key) DO UPDATE SET
           my_state = excluded.my_state, my_notes = excluded.my_notes,
           changed_at = excluded.changed_at, noticed_state = excluded.noticed_state,
           noticed_notes = excluded.noticed_notes`,
      );
      db.exec("BEGIN IMMEDIATE");
      try {
        let created = 0;
        for (const item of plan.intents) {
          const result = insertOutbox.run(
            item.dedupeKey,
            item.kind,
            item.variant,
            item.mr.key,
            item.mr.iid,
            item.mr.projectPath,
            item.mr.title,
            item.mr.url,
            item.recipient.username,
            item.recipient.name,
            now,
            now,
          );
          created += Number(result.changes);
        }
        for (const { key, record } of plan.nudgeUpdates) {
          upsertNudge.run(key, record.sentCount, record.lastSentAt);
        }
        for (const { mrKey, round } of plan.roundUpdates) {
          upsertRound.run(
            mrKey,
            round.myState,
            round.myNotes,
            round.changedAt,
            round.noticedState,
            round.noticedNotes,
          );
        }
        const keepNudges = new Set(plan.keepNudges);
        for (const row of rows("SELECT key FROM nudge_state")) {
          const key = text(row, "key");
          if (!keepNudges.has(key)) db.prepare("DELETE FROM nudge_state WHERE key = ?").run(key);
        }
        const keepRounds = new Set(plan.keepRounds);
        for (const row of rows("SELECT mr_key FROM review_round")) {
          const key = text(row, "mr_key");
          if (!keepRounds.has(key)) {
            db.prepare("DELETE FROM review_round WHERE mr_key = ?").run(key);
          }
        }
        db.prepare(
          `DELETE FROM outbox WHERE updated_at < ? AND status IN (${FINISHED_STATUSES.map(() => "?").join(", ")})`,
        ).run(now - OUTBOX_RETENTION_MS, ...FINISHED_STATUSES);
        if (plan.baselineDone) setMeta(META_TEAMS_BASELINE, "1");
        db.exec("COMMIT");
        return created;
      } catch (error) {
        db.exec("ROLLBACK");
        throw error;
      }
    },

    listOutbox(statuses) {
      if (statuses.length === 0) return [];
      const marks = statuses.map(() => "?").join(", ");
      return db
        .prepare(`SELECT * FROM outbox WHERE status IN (${marks}) ORDER BY id`)
        .all(...statuses)
        .map(toOutboxRow);
    },

    getOutbox(id) {
      const row = db.prepare("SELECT * FROM outbox WHERE id = ?").get(id);
      return row === undefined ? undefined : toOutboxRow(row);
    },

    transitionOutbox(id, from, to, fields, now) {
      const result = db
        .prepare(
          `UPDATE outbox SET status = ?, detail = COALESCE(?, detail), text = COALESCE(?, text),
             updated_at = ? WHERE id = ? AND status = ?`,
        )
        .run(to, fields.detail ?? null, fields.text ?? null, now, id, from);
      return Number(result.changes) === 1;
    },

    loadIdentity(username) {
      const row = db.prepare("SELECT email FROM identity WHERE username = ?").get(username);
      return row === undefined ? undefined : text(row, "email");
    },

    saveIdentity(username, email, now) {
      db.prepare(
        `INSERT INTO identity (username, email, resolved_at) VALUES (?, ?, ?)
         ON CONFLICT(username) DO UPDATE SET email = excluded.email, resolved_at = excluded.resolved_at`,
      ).run(username, email, now);
    },
```

- [ ] **Step 5: Run the checks**

Run: `npx prettier --write . && npm run check`
Expected: all pass — the 5 existing store tests (the "newer version" test still uses `user_version = 99`), the existing permission test, and the 9 new tests.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: add schema v2 with the Teams outbox, ledger and identity cache"
```

---

### Task 3: Fetch the Owner's notes on review-requested MRs

**Files:**
- Modify: `src/gitlab.ts` (the `SNAPSHOT_QUERY` constant)
- Test: `test/gitlab-notes.test.ts`

**Interfaces:**
- Consumes: `parseSnapshot` already maps `notes` when present.
- Produces: `Snapshot.reviewRequested[].notes` now carries the most recent notes (the Owner's own comments are what flow C counts).

- [ ] **Step 1: Write the failing test**

`test/gitlab-notes.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { SNAPSHOT_QUERY, parseSnapshot } from "../src/gitlab.ts";

describe("SNAPSHOT_QUERY", () => {
  it("asks for notes once, in the fragment shared by both lists", () => {
    expect(SNAPSHOT_QUERY.match(/notes\(last: 50\)/g)).toHaveLength(1);
    const fragment = SNAPSHOT_QUERY.slice(SNAPSHOT_QUERY.indexOf("fragment MrFields"));
    expect(fragment).toContain("notes(last: 50)");
  });
});

describe("parseSnapshot notes on review-requested MRs", () => {
  it("keeps the notes of an MR the Owner was asked to review", () => {
    const node = {
      iid: "7",
      title: "Add thing",
      webUrl: "https://gitlab.example/g/p/-/merge_requests/7",
      draft: false,
      project: { fullPath: "g/p" },
      author: { username: "alice", name: "Alice" },
      reviewers: { nodes: [] },
      notes: {
        nodes: [{ id: "n1", system: false, author: { username: "me", name: "Nata" } }],
      },
    };
    const snapshot = parseSnapshot({
      data: {
        currentUser: {
          username: "me",
          name: "Nata",
          reviewRequestedMergeRequests: { pageInfo: { hasNextPage: false }, nodes: [node] },
          authoredMergeRequests: { pageInfo: { hasNextPage: false }, nodes: [] },
        },
      },
    });
    expect(snapshot.reviewRequested[0]?.notes).toEqual([
      { id: "n1", system: false, author: { username: "me", name: "Nata" } },
    ]);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npx vitest run test/gitlab-notes.test.ts`
Expected: FAIL — the query-string test finds `notes(last: 50)` inside the authored list instead of the fragment (the parse test already passes).

- [ ] **Step 3: Replace the query constant in `src/gitlab.ts`**

```ts
export const SNAPSHOT_QUERY = `
query MrReviewAssistantSnapshot {
  currentUser {
    username
    name
    reviewRequestedMergeRequests(state: opened, first: ${PAGE_SIZE}) {
      pageInfo { hasNextPage }
      nodes { ...MrFields }
    }
    authoredMergeRequests(state: opened, first: ${PAGE_SIZE}) {
      pageInfo { hasNextPage }
      nodes { ...MrFields }
    }
  }
}
fragment MrFields on MergeRequest {
  iid
  title
  webUrl
  draft
  project { fullPath }
  author { username name }
  reviewers { nodes { username name mergeRequestInteraction { reviewState } } }
  notes(last: ${NOTES_WINDOW}) { nodes { id system author { username name } } }
}
`;
```

- [ ] **Step 4: Run the checks**

Run: `npx prettier --write . && npm run check`
Expected: all pass.

- [ ] **Step 5: Validate the new query against the real GitLab (read-only)**

```bash
node --input-type=module -e '
import { glabRunner, fetchSnapshot } from "./src/gitlab.ts";
const run = glabRunner({ hostname: "repo.madhani.one", glabPath: "glab", timeoutSeconds: 60 });
const s = await fetchSnapshot(run);
console.log(JSON.stringify({ reviewRequested: s.reviewRequested.length, withNotes: s.reviewRequested.filter((m) => m.notes.length > 0).length, authored: s.authored.length }));
'
```

Expected: one JSON line with no error; `withNotes` is greater than 0 if any MR you review has comments. A GraphQL error or a complexity error means `NOTES_WINDOW` must be lowered — rule on it in the ledger.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: fetch notes for review-requested merge requests"
```

---

### Task 4: The planner

**Files:**
- Create: `src/teams/plan.ts`
- Test: `test/plan.test.ts`

**Interfaces:**
- Consumes: `Snapshot`, `PreviousState`, `reviewerKey`, `myReviewState`, `UNREVIEWED`, `TeamsState`, `TeamsPlan`, `Intent`, `Round`, `TemplateName`.
- Produces: `PlanConfig { maxMessagesPerReviewer: number; reminderAfterMs: number; noticeDebounceMs: number }`; `PlanInput { snapshot; previous; state: TeamsState; now: number; config: PlanConfig }`; `planTeams(input: PlanInput): TeamsPlan`.

Rules the planner implements (from the spec): a **nudge** (variant `nudge`) goes to a Reviewer of the Owner's non-draft MR who is `UNREVIEWED` and was not `UNREVIEWED` in the previous poll (a new Reviewer, a brand-new MR, a draft that became ready, or a re-request); a **reminder** (variant `reminder`) goes to a Reviewer who got exactly one message, is still `UNREVIEWED`, and whose last message is at least `reminderAfterMs` old; never more than `maxMessagesPerReviewer` per MR per Reviewer. A **notice** goes to the MR's Author when the Owner's review state or comment count changed, nothing changed for `noticeDebounceMs`, and the change has not been announced yet; its variant is `notice.approved`, `notice.changes` or `notice.comments`. Nothing is queued until both the Plan 1 baseline and the Teams baseline are done.

- [ ] **Step 1: Write the failing tests**

`test/plan.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import type { MergeRequest } from "../src/domain.ts";
import { reviewerKey } from "../src/events.ts";
import { planTeams } from "../src/teams/plan.ts";
import type { PlanConfig } from "../src/teams/plan.ts";
import type { Round, TeamsState } from "../src/teams/types.ts";
import { ME, mr, note, person, previous, reviewer, snapshot } from "./builders.ts";
import { NOW } from "./teams-builders.ts";

const HOUR = 3_600_000;
const MINUTE = 60_000;
const config: PlanConfig = {
  maxMessagesPerReviewer: 2,
  reminderAfterMs: 24 * HOUR,
  noticeDebounceMs: 10 * MINUTE,
};

function teamsState(overrides: Partial<TeamsState> = {}): TeamsState {
  return { baselineDone: true, nudges: new Map(), rounds: new Map(), ...overrides };
}

function plan(input: {
  snapshot: ReturnType<typeof snapshot>;
  previous?: ReturnType<typeof previous>;
  state?: TeamsState;
  now?: number;
}) {
  return planTeams({
    snapshot: input.snapshot,
    previous: input.previous ?? previous(),
    state: input.state ?? teamsState(),
    now: input.now ?? NOW,
    config,
  });
}

const BOB = reviewerKey("g/p!5", "bob");
const own = (overrides: Partial<MergeRequest> = {}): MergeRequest =>
  mr(5, { author: ME, reviewers: [reviewer("bob", "UNREVIEWED", "Bob")], ...overrides });
const known = (state: string) =>
  previous({
    trackedAuthored: new Set(["g/p!5"]),
    reviewerStates: new Map([[BOB, state]]),
  });

describe("reviewer nudges (flow B)", () => {
  it("nudges a Reviewer who was added to a tracked MR, and only that Reviewer", () => {
    const current = snapshot({
      authored: [own({ reviewers: [reviewer("carol", "UNREVIEWED"), reviewer("bob", "UNREVIEWED", "Bob")] })],
    });
    const before = previous({
      trackedAuthored: new Set(["g/p!5"]),
      reviewerStates: new Map([[reviewerKey("g/p!5", "carol"), "UNREVIEWED"]]),
    });
    const result = plan({ snapshot: current, previous: before });
    expect(result.intents).toEqual([
      {
        dedupeKey: "nudge:g/p!5|bob:1",
        kind: "nudge",
        variant: "nudge",
        mr: {
          key: "g/p!5",
          iid: 5,
          projectPath: "g/p",
          title: "MR 5",
          url: "https://gitlab.example/g/p/-/merge_requests/5",
        },
        recipient: { username: "bob", name: "Bob" },
      },
    ]);
    expect(result.nudgeUpdates).toEqual([{ key: BOB, record: { sentCount: 1, lastSentAt: NOW } }]);
  });

  it("nudges every Reviewer of a brand-new MR", () => {
    const current = snapshot({
      authored: [own({ reviewers: [reviewer("bob", "UNREVIEWED"), reviewer("carol", "UNREVIEWED")] })],
    });
    expect(plan({ snapshot: current }).intents.map((i) => i.recipient.username)).toEqual([
      "bob",
      "carol",
    ]);
  });

  it("does not nudge Reviewers that were already there before", () => {
    expect(plan({ snapshot: snapshot({ authored: [own()] }), previous: known("UNREVIEWED") }).intents).toEqual([]);
  });

  it("does not nudge a Reviewer who has already reviewed", () => {
    const current = snapshot({ authored: [own({ reviewers: [reviewer("bob", "APPROVED")] })] });
    expect(plan({ snapshot: current }).intents).toEqual([]);
  });

  it("ignores draft MRs and the Owner as a Reviewer", () => {
    const draft = snapshot({ authored: [own({ draft: true })] });
    expect(plan({ snapshot: draft }).intents).toEqual([]);
    const self = snapshot({ authored: [own({ reviewers: [reviewer("me", "UNREVIEWED")] })] });
    expect(plan({ snapshot: self }).intents).toEqual([]);
  });

  it("nudges again on a re-request, but never beyond the cap", () => {
    const current = snapshot({ authored: [own()] });
    const oneSent = teamsState({ nudges: new Map([[BOB, { sentCount: 1, lastSentAt: NOW - HOUR }]]) });
    const again = plan({ snapshot: current, previous: known("APPROVED"), state: oneSent });
    expect(again.intents.map((i) => [i.dedupeKey, i.kind])).toEqual([["nudge:g/p!5|bob:2", "nudge"]]);
    const twoSent = teamsState({ nudges: new Map([[BOB, { sentCount: 2, lastSentAt: NOW - HOUR }]]) });
    expect(plan({ snapshot: current, previous: known("APPROVED"), state: twoSent }).intents).toEqual([]);
  });

  it("reminds once, 24 hours after the nudge, while the Reviewer is still UNREVIEWED", () => {
    const current = snapshot({ authored: [own()] });
    const sentAt = (age: number, count = 1) =>
      teamsState({ nudges: new Map([[BOB, { sentCount: count, lastSentAt: NOW - age }]]) });
    const due = plan({ snapshot: current, previous: known("UNREVIEWED"), state: sentAt(24 * HOUR) });
    expect(due.intents.map((i) => [i.dedupeKey, i.kind, i.variant])).toEqual([
      ["nudge:g/p!5|bob:2", "reminder", "reminder"],
    ]);
    expect(due.nudgeUpdates).toEqual([{ key: BOB, record: { sentCount: 2, lastSentAt: NOW } }]);
    expect(
      plan({ snapshot: current, previous: known("UNREVIEWED"), state: sentAt(24 * HOUR - MINUTE) }).intents,
    ).toEqual([]);
    expect(
      plan({ snapshot: current, previous: known("UNREVIEWED"), state: sentAt(48 * HOUR, 2) }).intents,
    ).toEqual([]);
  });

  it("does not remind a Reviewer who reviewed in the meantime", () => {
    const current = snapshot({ authored: [own({ reviewers: [reviewer("bob", "APPROVED")] })] });
    const state = teamsState({ nudges: new Map([[BOB, { sentCount: 1, lastSentAt: NOW - 30 * HOUR }]]) });
    expect(plan({ snapshot: current, previous: known("UNREVIEWED"), state }).intents).toEqual([]);
  });

  it("keeps the ledger rows of Reviewers on open non-draft MRs only, never the Owner", () => {
    const current = snapshot({
      authored: [
        own({ reviewers: [reviewer("bob", "APPROVED"), reviewer("me", "UNREVIEWED")] }),
        mr(6, { author: ME, draft: true, reviewers: [reviewer("dave", "UNREVIEWED")] }),
      ],
    });
    expect(plan({ snapshot: current }).keepNudges).toEqual([BOB]);
  });
});

describe("review notices (flow C)", () => {
  const KEY = "g/p!7";
  const theirs = (state: string, notes: MergeRequest["notes"] = []): MergeRequest =>
    mr(7, { author: person("alice", "Alice"), reviewers: [reviewer("me", state)], notes });
  const round = (overrides: Partial<Round> = {}): Round => ({
    myState: "UNREVIEWED",
    myNotes: 0,
    changedAt: NOW - HOUR,
    noticedState: "UNREVIEWED",
    noticedNotes: 0,
    ...overrides,
  });
  const withRound = (value: Round) => teamsState({ rounds: new Map([[KEY, value]]) });

  it("records the first sighting without any notice", () => {
    const result = plan({ snapshot: snapshot({ reviewRequested: [theirs("UNREVIEWED")] }) });
    expect(result.intents).toEqual([]);
    expect(result.roundUpdates).toEqual([
      { mrKey: KEY, round: round({ changedAt: NOW }) },
    ]);
    expect(result.keepRounds).toEqual([KEY]);
  });

  it("restarts the debounce when the Owner's review changes, and notices only after it", () => {
    const current = snapshot({ reviewRequested: [theirs("APPROVED")] });
    const changed = plan({ snapshot: current, state: withRound(round()) });
    expect(changed.intents).toEqual([]);
    expect(changed.roundUpdates).toEqual([{ mrKey: KEY, round: round({ myState: "APPROVED", changedAt: NOW }) }]);

    const settled = plan({
      snapshot: current,
      state: withRound(round({ myState: "APPROVED", changedAt: NOW - 11 * MINUTE })),
    });
    expect(settled.intents).toEqual([
      {
        dedupeKey: "notice:g/p!7:APPROVED:0",
        kind: "notice",
        variant: "notice.approved",
        mr: {
          key: KEY,
          iid: 7,
          projectPath: "g/p",
          title: "MR 7",
          url: "https://gitlab.example/g/p/-/merge_requests/7",
        },
        recipient: { username: "alice", name: "Alice" },
      },
    ]);
    expect(settled.roundUpdates).toEqual([
      {
        mrKey: KEY,
        round: round({ myState: "APPROVED", changedAt: NOW - 11 * MINUTE, noticedState: "APPROVED" }),
      },
    ]);
  });

  it("uses the 'changes' variant and the 'comments' variant", () => {
    const changes = plan({
      snapshot: snapshot({ reviewRequested: [theirs("REQUESTED_CHANGES")] }),
      state: withRound(round({ myState: "REQUESTED_CHANGES", changedAt: NOW - 11 * MINUTE })),
    });
    expect(changes.intents.map((i) => i.variant)).toEqual(["notice.changes"]);

    const comments = plan({
      snapshot: snapshot({ reviewRequested: [theirs("UNREVIEWED", [note("n1", ME)])] }),
      state: withRound(round({ myNotes: 1, changedAt: NOW - 11 * MINUTE })),
    });
    expect(comments.intents.map((i) => [i.variant, i.dedupeKey])).toEqual([
      ["notice.comments", "notice:g/p!7:UNREVIEWED:1"],
    ]);
  });

  it("counts only the Owner's own human notes", () => {
    const others = [note("a", person("alice")), note("b", ME, true)];
    const result = plan({
      snapshot: snapshot({ reviewRequested: [theirs("UNREVIEWED", others)] }),
      state: withRound(round({ changedAt: NOW - 11 * MINUTE })),
    });
    expect(result.intents).toEqual([]);
  });

  it("does not announce the same activity twice", () => {
    const result = plan({
      snapshot: snapshot({ reviewRequested: [theirs("APPROVED")] }),
      state: withRound(
        round({ myState: "APPROVED", noticedState: "APPROVED", changedAt: NOW - 11 * MINUTE }),
      ),
    });
    expect(result.intents).toEqual([]);
    expect(result.roundUpdates).toEqual([]);
  });

  it("starts a new round on a re-request without announcing the old comments", () => {
    const result = plan({
      snapshot: snapshot({ reviewRequested: [theirs("UNREVIEWED", [note("a", ME), note("b", ME)])] }),
      state: withRound(
        round({ myState: "APPROVED", myNotes: 2, noticedState: "APPROVED", noticedNotes: 2 }),
      ),
    });
    expect(result.intents).toEqual([]);
    expect(result.roundUpdates).toEqual([
      {
        mrKey: KEY,
        round: round({ myState: "UNREVIEWED", myNotes: 2, noticedNotes: 2, changedAt: NOW }),
      },
    ]);
  });

  it("ignores draft MRs", () => {
    const draft = mr(7, { draft: true, reviewers: [reviewer("me", "APPROVED")] });
    const result = plan({ snapshot: snapshot({ reviewRequested: [draft] }) });
    expect(result.roundUpdates).toEqual([]);
    expect(result.keepRounds).toEqual([]);
  });
});

describe("Teams baseline", () => {
  it("queues nothing and seeds the rounds with what already exists (upgrade from Plan 1)", () => {
    const current = snapshot({
      authored: [own()],
      reviewRequested: [
        mr(7, { author: person("alice", "Alice"), reviewers: [reviewer("me", "APPROVED")], notes: [note("n1", ME)] }),
      ],
    });
    // Plan 1 finished its baseline long ago; Teams has just been switched on.
    const first = plan({
      snapshot: current,
      previous: previous({ baselineDone: true }),
      state: teamsState({ baselineDone: false }),
    });
    expect(first.intents).toEqual([]);
    expect(first.baselineDone).toBe(true);
    expect(first.roundUpdates).toEqual([
      {
        mrKey: "g/p!7",
        round: {
          myState: "APPROVED",
          myNotes: 1,
          changedAt: NOW,
          noticedState: "APPROVED",
          noticedNotes: 1,
        },
      },
    ]);

    // On the next poll the seeded round is in the ledger and still produces nothing.
    const seeded = new Map(first.roundUpdates.map((update) => [update.mrKey, update.round] as const));
    const second = plan({
      snapshot: current,
      previous: known("UNREVIEWED"),
      state: teamsState({ rounds: seeded }),
      now: NOW + HOUR,
    });
    expect(second.intents).toEqual([]);
  });

  it("queues nothing while the Plan 1 baseline itself is still pending", () => {
    const current = snapshot({ authored: [own()] });
    const result = plan({ snapshot: current, previous: previous({ baselineDone: false }) });
    expect(result.intents).toEqual([]);
  });
});
```


- [ ] **Step 2: Run to verify it fails**

Run: `npx vitest run test/plan.test.ts`
Expected: FAIL — cannot resolve `../src/teams/plan.ts`.

- [ ] **Step 3: Implement `src/teams/plan.ts`**

```ts
import { UNREVIEWED } from "../domain.ts";
import type { MergeRequest, Snapshot } from "../domain.ts";
import { myReviewState, reviewerKey } from "../events.ts";
import type { PreviousState } from "../events.ts";
import type { Intent, IntentMr, Round, TeamsPlan, TeamsState, TemplateName } from "./types.ts";

export interface PlanConfig {
  readonly maxMessagesPerReviewer: number;
  readonly reminderAfterMs: number;
  readonly noticeDebounceMs: number;
}

export interface PlanInput {
  readonly snapshot: Snapshot;
  readonly previous: PreviousState;
  readonly state: TeamsState;
  readonly now: number;
  readonly config: PlanConfig;
}

const APPROVED = "APPROVED";
const REQUESTED_CHANGES = "REQUESTED_CHANGES";

function intentMr(mr: MergeRequest): IntentMr {
  return { key: mr.key, iid: mr.iid, projectPath: mr.projectPath, title: mr.title, url: mr.url };
}

function noticeVariant(round: Round): TemplateName | undefined {
  if (round.myState === APPROVED && round.noticedState !== APPROVED) return "notice.approved";
  if (round.myState === REQUESTED_CHANGES && round.noticedState !== REQUESTED_CHANGES) {
    return "notice.changes";
  }
  if (round.myNotes > round.noticedNotes) return "notice.comments";
  return undefined;
}

/**
 * Pure: decides which Teams messages are due and how the ledger changes. Nothing is queued until
 * both the Plan 1 baseline and the Teams baseline exist, so switching Teams on later never
 * announces history.
 */
export function planTeams(input: PlanInput): TeamsPlan {
  const { snapshot, previous, state, now, config } = input;
  const live = previous.baselineDone && state.baselineDone;
  const intents: Intent[] = [];
  const nudgeUpdates: { key: string; record: { sentCount: number; lastSentAt: number } }[] = [];
  const roundUpdates: { mrKey: string; round: Round }[] = [];
  const keepNudges: string[] = [];
  const keepRounds: string[] = [];

  for (const mr of snapshot.authored) {
    if (mr.draft) continue;
    for (const reviewer of mr.reviewers) {
      if (reviewer.username === snapshot.me.username) continue;
      const key = reviewerKey(mr.key, reviewer.username);
      keepNudges.push(key);
      if (!live || reviewer.state !== UNREVIEWED) continue;
      const record = state.nudges.get(key);
      const sent = record?.sentCount ?? 0;
      if (sent >= config.maxMessagesPerReviewer) continue;
      // Not UNREVIEWED before (or not there at all) and UNREVIEWED now: added, or asked again.
      const asking = previous.reviewerStates.get(key) !== UNREVIEWED;
      const reminderDue =
        record !== undefined &&
        sent === 1 &&
        previous.reviewerStates.get(key) === UNREVIEWED &&
        now - record.lastSentAt >= config.reminderAfterMs;
      if (!asking && !reminderDue) continue;
      const slot = sent + 1;
      intents.push({
        dedupeKey: `nudge:${key}:${slot}`,
        kind: asking ? "nudge" : "reminder",
        variant: asking ? "nudge" : "reminder",
        mr: intentMr(mr),
        recipient: { username: reviewer.username, name: reviewer.name },
      });
      nudgeUpdates.push({ key, record: { sentCount: slot, lastSentAt: now } });
    }
  }

  for (const mr of snapshot.reviewRequested) {
    if (mr.draft) continue;
    keepRounds.push(mr.key);
    const myState = myReviewState(snapshot, mr);
    const myNotes = mr.notes.filter(
      (note) => !note.system && note.author.username === snapshot.me.username,
    ).length;
    const existing = state.rounds.get(mr.key);
    if (existing === undefined) {
      // First sighting: while seeding, what exists counts as announced; afterwards an MR starts
      // as "nothing announced", so a review given before the agent saw it is still announced.
      const seeded = state.baselineDone
        ? { state: UNREVIEWED, notes: 0 }
        : { state: myState, notes: myNotes };
      roundUpdates.push({
        mrKey: mr.key,
        round: {
          myState,
          myNotes,
          changedAt: now,
          noticedState: seeded.state,
          noticedNotes: seeded.notes,
        },
      });
      continue;
    }
    let round = existing;
    if (myState !== existing.myState || myNotes !== existing.myNotes) {
      round = { ...existing, myState, myNotes, changedAt: now };
      if (myState === UNREVIEWED && existing.myState !== UNREVIEWED) {
        // A new Review Request after an earlier review: do not announce the old comments again.
        round = { ...round, noticedState: UNREVIEWED, noticedNotes: myNotes };
      }
    }
    const variant = noticeVariant(round);
    if (live && variant !== undefined && now - round.changedAt >= config.noticeDebounceMs) {
      intents.push({
        dedupeKey: `notice:${mr.key}:${myState}:${myNotes}`,
        kind: "notice",
        variant,
        mr: intentMr(mr),
        recipient: mr.author,
      });
      round = { ...round, noticedState: myState, noticedNotes: myNotes };
    }
    if (round !== existing) roundUpdates.push({ mrKey: mr.key, round });
  }

  return { intents, nudgeUpdates, roundUpdates, keepNudges, keepRounds, baselineDone: true };
}
```

- [ ] **Step 4: Run the checks**

Run: `npx prettier --write . && npm run check`
Expected: all pass, the new planner tests green. A failure in "restarts the debounce…" usually means `changedAt` was not reset on a state change — fix the code, not the test.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: plan reviewer nudges, reminders and review notices"
```

---

### Task 5: Message templates

**Files:**
- Create: `src/teams/templates.ts`
- Test: `test/templates.test.ts`

**Interfaces:**
- Consumes: `TEMPLATE_NAMES`, `TemplateName` from `src/teams/types.ts`.
- Produces: `PLACEHOLDERS` (`"mr.title" | "mr.url" | "mr.iid" | "mr.project" | "person.name" | "owner.name"`), `Placeholder`, `Templates = Readonly<Record<TemplateName, string>>`, `DEFAULT_TEMPLATES`, `TemplateError`, `validateTemplate(label: string, text: string): void`, `renderTemplate(text: string, values: Readonly<Record<Placeholder, string>>): string`, `loadTemplates(directory: string): Templates`, `defaultTemplatesPath(): string`.

- [ ] **Step 1: Write the failing tests**

`test/templates.test.ts`:

```ts
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  DEFAULT_TEMPLATES,
  TemplateError,
  loadTemplates,
  renderTemplate,
  validateTemplate,
} from "../src/teams/templates.ts";
import { TEMPLATE_NAMES } from "../src/teams/types.ts";

const folders: string[] = [];
afterEach(() => {
  for (const folder of folders.splice(0)) rmSync(folder, { recursive: true, force: true });
});
function tempDir(): string {
  const folder = mkdtempSync(join(tmpdir(), "mra-tpl-"));
  folders.push(folder);
  return folder;
}

const values = {
  "mr.title": "Add thing",
  "mr.url": "https://gitlab.example/g/p/-/merge_requests/7",
  "mr.iid": "7",
  "mr.project": "g/p",
  "person.name": "Alice",
  "owner.name": "Nata",
};

describe("validateTemplate", () => {
  it("accepts known placeholders with or without spaces", () => {
    expect(() => validateTemplate("x", "Halo {{person.name}} {{ mr.url }}")).not.toThrow();
  });

  it("rejects an unknown placeholder and names it with the template", () => {
    expect(() => validateTemplate("nudge.txt", "Halo {{person.nmae}}")).toThrow(
      /nudge\.txt.*person\.nmae/,
    );
  });

  it("rejects an empty template", () => {
    expect(() => validateTemplate("x", "  \n ")).toThrow(TemplateError);
  });

  it("accepts every built-in template", () => {
    for (const name of TEMPLATE_NAMES) {
      expect(() => validateTemplate(name, DEFAULT_TEMPLATES[name])).not.toThrow();
    }
  });
});

describe("renderTemplate", () => {
  it("replaces every occurrence and trims the result", () => {
    expect(renderTemplate("\nHalo {{person.name}}, {{ person.name }}!\n{{mr.url}}\n", values)).toBe(
      "Halo Alice, Alice!\nhttps://gitlab.example/g/p/-/merge_requests/7",
    );
  });

  it("does not expand placeholders that appear inside a substituted value", () => {
    const tricky = { ...values, "mr.title": "{{owner.name}}" };
    expect(renderTemplate("{{mr.title}}", tricky)).toBe("{{owner.name}}");
  });

  it("refuses an unknown placeholder at render time too", () => {
    expect(() => renderTemplate("{{nope}}", values)).toThrow(TemplateError);
  });
});

describe("loadTemplates", () => {
  it("uses the built-in Indonesian defaults when the folder does not exist", () => {
    expect(loadTemplates(join(tempDir(), "missing"))).toEqual(DEFAULT_TEMPLATES);
    expect(DEFAULT_TEMPLATES.nudge).toContain("boleh minta tolong review");
  });

  it("lets a file replace one template and keeps the others", () => {
    const directory = tempDir();
    writeFileSync(join(directory, "reminder.txt"), "Ping {{person.name}}: {{mr.url}}\n");
    const loaded = loadTemplates(directory);
    expect(loaded.reminder).toBe("Ping {{person.name}}: {{mr.url}}\n");
    expect(loaded.nudge).toBe(DEFAULT_TEMPLATES.nudge);
  });

  it("stops with the file name when a template file has an unknown placeholder", () => {
    const directory = tempDir();
    mkdirSync(directory, { recursive: true });
    writeFileSync(join(directory, "nudge.txt"), "Halo {{who}}");
    expect(() => loadTemplates(directory)).toThrow(/nudge\.txt.*who/);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npx vitest run test/templates.test.ts`
Expected: FAIL — cannot resolve `../src/teams/templates.ts`.

- [ ] **Step 3: Implement `src/teams/templates.ts`**

```ts
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { TEMPLATE_NAMES } from "./types.ts";
import type { TemplateName } from "./types.ts";

export const PLACEHOLDERS = [
  "mr.title",
  "mr.url",
  "mr.iid",
  "mr.project",
  "person.name",
  "owner.name",
] as const;
export type Placeholder = (typeof PLACEHOLDERS)[number];
export type Templates = Readonly<Record<TemplateName, string>>;

export const DEFAULT_TEMPLATES: Templates = {
  nudge:
    "Halo {{person.name}}, boleh minta tolong review MR ini? {{mr.title}}\n{{mr.url}}\nTerima kasih!",
  reminder:
    "Halo {{person.name}}, mengingatkan kembali soal review MR ini ya: {{mr.title}}\n{{mr.url}}\nTerima kasih!",
  "notice.approved":
    "Halo {{person.name}}, MR kamu sudah saya review dan saya approve: {{mr.title}}\n{{mr.url}}",
  "notice.changes":
    "Halo {{person.name}}, saya sudah review MR kamu dan ada perubahan yang perlu dilihat: {{mr.title}}\n{{mr.url}}",
  "notice.comments":
    "Halo {{person.name}}, saya sudah review MR kamu dan meninggalkan beberapa komentar: {{mr.title}}\n{{mr.url}}",
};

export class TemplateError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "TemplateError";
  }
}

const PLACEHOLDER_PATTERN = /\{\{\s*([\w.]+)\s*\}\}/g;

function isPlaceholder(name: string): name is Placeholder {
  return (PLACEHOLDERS as readonly string[]).includes(name);
}

/** Throws a `TemplateError` naming `label` when the text is empty or uses an unknown placeholder. */
export function validateTemplate(label: string, text: string): void {
  if (text.trim().length === 0) throw new TemplateError(`template ${label} is empty`);
  for (const match of text.matchAll(PLACEHOLDER_PATTERN)) {
    const name = match[1] ?? "";
    if (!isPlaceholder(name)) {
      throw new TemplateError(`template ${label} uses an unknown placeholder: ${name}`);
    }
  }
}

/** One pass over the template, so a value that looks like a placeholder is never expanded. */
export function renderTemplate(text: string, values: Readonly<Record<Placeholder, string>>): string {
  return text
    .replace(PLACEHOLDER_PATTERN, (_whole, name: string) => {
      if (!isPlaceholder(name)) throw new TemplateError(`unknown placeholder: ${name}`);
      return values[name];
    })
    .trim();
}

export function defaultTemplatesPath(): string {
  return join(homedir(), ".config", "mr-review-assistant", "templates");
}

/** A file `<name>.txt` in `directory` replaces the built-in template of the same name. */
export function loadTemplates(directory: string): Templates {
  const loaded: Record<TemplateName, string> = { ...DEFAULT_TEMPLATES };
  for (const name of TEMPLATE_NAMES) {
    const file = join(directory, `${name}.txt`);
    if (!existsSync(file)) continue;
    const text = readFileSync(file, "utf8");
    validateTemplate(`${name}.txt`, text);
    loaded[name] = text;
  }
  return loaded;
}
```

- [ ] **Step 4: Run the checks**

Run: `npx prettier --write . && npm run check`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add validated Indonesian message templates"
```

---

### Task 6: Minimal MCP stdio client

**Files:**
- Create: `src/teams/mcp.ts`, `test/fixtures/fake-mcp-server.ts`
- Test: `test/mcp.test.ts`

**Interfaces:**
- Produces: `McpErrorKind = "spawn" | "timeout" | "closed" | "protocol" | "server"`; `McpError extends Error { kind }`; `ToolResult { text: string; isError: boolean }`; `McpSession { callTool(name, args): Promise<ToolResult>; close(): void }`; `McpOptions { command: string; args?: readonly string[]; startTimeoutMs: number; callTimeoutMs: number }`; `openMcpSession(options: McpOptions): Promise<McpSession>`.

The protocol was checked against the real server on 2026-10-16 with a throwaway probe: `initialize` (protocol `2025-03-26`) answered in about 3 s, `tools/list` returned 31 tools. Frames are newline-delimited JSON on stdin/stdout.

- [ ] **Step 1: Write the fake server and the failing tests**

`test/fixtures/fake-mcp-server.ts`:

```ts
import { createInterface } from "node:readline";
import { z } from "zod";

// Modes: ok | noisy (prints non-JSON lines first) | silent (never answers) | crash (exits at once).
// Tools: echo, fail (isError), bad (malformed result), anything else never answers (hang).
const mode = process.argv[2] ?? "ok";
if (mode === "crash") process.exit(3);

const requestSchema = z.object({
  id: z.number().optional(),
  method: z.string(),
  params: z.record(z.string(), z.unknown()).optional(),
});

function reply(id: number, result: unknown): void {
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, result })}\n`);
}

if (mode === "noisy") {
  process.stdout.write("starting up...\n");
  process.stdout.write("{not json\n");
}

createInterface({ input: process.stdin }).on("line", (line) => {
  const request = requestSchema.parse(JSON.parse(line));
  if (mode === "silent" || request.id === undefined) return;
  if (request.method === "initialize") {
    reply(request.id, {
      protocolVersion: "2025-03-26",
      capabilities: {},
      serverInfo: { name: "fake", version: "0" },
    });
    return;
  }
  if (request.method !== "tools/call") return;
  const name = request.params?.["name"];
  const args = request.params?.["arguments"];
  if (name === "echo") {
    reply(request.id, { content: [{ type: "text", text: `echo:${JSON.stringify(args)}` }] });
  } else if (name === "fail") {
    reply(request.id, { content: [{ type: "text", text: "❌ nope" }], isError: true });
  } else if (name === "bad") {
    reply(request.id, { content: "not an array" });
  }
});
```

`test/mcp.test.ts`:

```ts
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { McpError, openMcpSession } from "../src/teams/mcp.ts";
import type { McpSession } from "../src/teams/mcp.ts";

const server = fileURLToPath(new URL("./fixtures/fake-mcp-server.ts", import.meta.url));
const open = (mode: string, startTimeoutMs = 5000, callTimeoutMs = 5000): Promise<McpSession> =>
  openMcpSession({ command: process.execPath, args: [server, mode], startTimeoutMs, callTimeoutMs });

async function withSession<T>(mode: string, use: (session: McpSession) => Promise<T>): Promise<T> {
  const session = await open(mode);
  try {
    return await use(session);
  } finally {
    session.close();
  }
}

describe("openMcpSession", () => {
  it("calls a tool and returns its text", async () => {
    const result = await withSession("ok", (s) => s.callTool("echo", { a: 1 }));
    expect(result).toEqual({ text: 'echo:{"a":1}', isError: false });
  });

  it("ignores log noise that is not JSON on stdout", async () => {
    const result = await withSession("noisy", (s) => s.callTool("echo", {}));
    expect(result.text).toBe("echo:{}");
  });

  it("maps a tool-level error to isError without throwing", async () => {
    const result = await withSession("ok", (s) => s.callTool("fail", {}));
    expect(result).toEqual({ text: "❌ nope", isError: true });
  });

  it("times out when the server never answers initialize", async () => {
    await expect(open("silent", 200)).rejects.toMatchObject({ kind: "timeout" });
  });

  it("times out one hanging call and stays usable for the next", async () => {
    const session = await open("ok", 5000, 200);
    try {
      await expect(session.callTool("hang", {})).rejects.toMatchObject({ kind: "timeout" });
      await expect(session.callTool("echo", {})).resolves.toMatchObject({ text: "echo:{}" });
    } finally {
      session.close();
    }
  });

  it("rejects when the server exits during startup", async () => {
    await expect(open("crash")).rejects.toMatchObject({ kind: "closed" });
  });

  it("reports a missing command as a spawn error", async () => {
    const attempt = openMcpSession({
      command: "/nonexistent/teams-mcp",
      startTimeoutMs: 2000,
      callTimeoutMs: 2000,
    });
    await expect(attempt).rejects.toMatchObject({ kind: "spawn" });
  });

  it("rejects a malformed tool result as a protocol error", async () => {
    await withSession("ok", async (s) => {
      await expect(s.callTool("bad", {})).rejects.toMatchObject({ kind: "protocol" });
    });
  });

  it("rejects calls that are still pending when the session is closed", async () => {
    const session = await open("ok");
    const pending = session.callTool("hang", {});
    session.close();
    await expect(pending).rejects.toBeInstanceOf(McpError);
    await expect(pending).rejects.toMatchObject({ kind: "closed" });
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npx vitest run test/mcp.test.ts`
Expected: FAIL — cannot resolve `../src/teams/mcp.ts`.

- [ ] **Step 3: Implement `src/teams/mcp.ts`**

```ts
import { spawn } from "node:child_process";
import { z } from "zod";

export type McpErrorKind = "spawn" | "timeout" | "closed" | "protocol" | "server";

export class McpError extends Error {
  readonly kind: McpErrorKind;

  constructor(kind: McpErrorKind, message: string) {
    super(message);
    this.name = "McpError";
    this.kind = kind;
  }
}

export interface ToolResult {
  readonly text: string;
  readonly isError: boolean;
}

export interface McpSession {
  callTool(name: string, args: Readonly<Record<string, unknown>>): Promise<ToolResult>;
  /** Stops the server and fails every call still waiting. Safe to call more than once. */
  close(): void;
}

export interface McpOptions {
  readonly command: string;
  readonly args?: readonly string[];
  readonly startTimeoutMs: number;
  readonly callTimeoutMs: number;
}

const PROTOCOL_VERSION = "2025-03-26";
const CLIENT_INFO = { name: "mr-review-assistant", version: "0.1.0" };

const frameSchema = z.object({
  id: z.number().optional(),
  result: z.unknown().optional(),
  error: z.object({ message: z.string() }).optional(),
});
const toolResultSchema = z.object({
  content: z.array(z.object({ type: z.string(), text: z.string().optional() })),
  isError: z.boolean().optional(),
});

interface Pending {
  readonly resolve: (value: unknown) => void;
  readonly reject: (error: McpError) => void;
  readonly timer: ReturnType<typeof setTimeout>;
}

/**
 * Minimal MCP client over stdio: newline-delimited JSON-RPC, `initialize` then `tools/call`.
 * The server's stderr is ignored; lines on stdout that are not JSON-RPC frames are skipped.
 */
export async function openMcpSession(options: McpOptions): Promise<McpSession> {
  const child = spawn(options.command, [...(options.args ?? [])], {
    stdio: ["pipe", "pipe", "ignore"],
  });
  const pending = new Map<number, Pending>();
  let nextId = 1;
  let closed = false;
  let buffer = "";

  const failAll = (error: McpError): void => {
    closed = true;
    for (const entry of pending.values()) {
      clearTimeout(entry.timer);
      entry.reject(error);
    }
    pending.clear();
  };

  child.on("error", (error: NodeJS.ErrnoException) => {
    failAll(
      new McpError("spawn", error.code === "ENOENT" ? "MCP command not found" : "MCP process error"),
    );
  });
  child.on("exit", () => {
    failAll(new McpError("closed", "MCP server exited"));
  });
  child.stdin.on("error", () => {
    failAll(new McpError("closed", "MCP server closed its input"));
  });

  const handleLine = (line: string): void => {
    let raw: unknown;
    try {
      raw = JSON.parse(line);
    } catch {
      return; // A log line, not a JSON-RPC frame.
    }
    const frame = frameSchema.safeParse(raw);
    if (!frame.success || frame.data.id === undefined) return;
    const entry = pending.get(frame.data.id);
    if (entry === undefined) return;
    pending.delete(frame.data.id);
    clearTimeout(entry.timer);
    if (frame.data.error !== undefined) {
      entry.reject(new McpError("server", "MCP server returned an error"));
    } else {
      entry.resolve(frame.data.result);
    }
  };

  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk: string) => {
    buffer += chunk;
    for (;;) {
      const end = buffer.indexOf("\n");
      if (end < 0) break;
      const line = buffer.slice(0, end).trim();
      buffer = buffer.slice(end + 1);
      if (line.length > 0) handleLine(line);
    }
  });

  const write = (message: object): void => {
    if (!closed) child.stdin.write(`${JSON.stringify(message)}\n`);
  };

  const request = (method: string, params: object, timeoutMs: number): Promise<unknown> =>
    new Promise((resolve, reject) => {
      if (closed) {
        reject(new McpError("closed", "MCP server is not running"));
        return;
      }
      const id = nextId;
      nextId += 1;
      const timer = setTimeout(() => {
        pending.delete(id);
        reject(new McpError("timeout", `MCP ${method} timed out`));
      }, timeoutMs);
      pending.set(id, { resolve, reject, timer });
      write({ jsonrpc: "2.0", id, method, params });
    });

  const close = (): void => {
    const wasOpen = !closed;
    failAll(new McpError("closed", "MCP session closed"));
    if (wasOpen) child.kill("SIGTERM");
  };

  try {
    await request(
      "initialize",
      { protocolVersion: PROTOCOL_VERSION, capabilities: {}, clientInfo: CLIENT_INFO },
      options.startTimeoutMs,
    );
    write({ jsonrpc: "2.0", method: "notifications/initialized" });
  } catch (error) {
    close();
    throw error;
  }

  return {
    async callTool(name, args) {
      const raw = await request("tools/call", { name, arguments: args }, options.callTimeoutMs);
      const parsed = toolResultSchema.safeParse(raw);
      if (!parsed.success) throw new McpError("protocol", "unexpected tools/call result");
      return {
        text: parsed.data.content
          .flatMap((part) => (part.type === "text" && part.text !== undefined ? [part.text] : []))
          .join("\n"),
        isError: parsed.data.isError === true,
      };
    },
    close,
  };
}
```

- [ ] **Step 4: Run the checks**

Run: `npx prettier --write . && npm run check`
Expected: all pass. If the "missing command" test reports a timeout instead of `spawn`, the `error` event arrived after the request timer — check that `failAll` runs on the `error` event before the 2 s timeout, which it does on every platform tested so far.

- [ ] **Step 5: Manual check against the real server (read-only, no message, no Graph call)**

```bash
node --input-type=module -e '
import { homedir } from "node:os";
import { join } from "node:path";
import { openMcpSession } from "./src/teams/mcp.ts";
const s = await openMcpSession({ command: join(homedir(), ".config/teams-mcp/run.sh"), startTimeoutMs: 30000, callTimeoutMs: 60000 });
const r = await s.callTool("auth_status", {});
console.log(JSON.stringify({ isError: r.isError, startsWithOk: r.text.startsWith("✅") }));
s.close();
'
```

Expected: `{"isError":false,"startsWithOk":true}`. This reads the Owner's own profile (the same `auth_status` the Owner already ran) and sends nothing. If it times out, the Teams MCP is not connecting; report it to the Owner (`teams` was reported as `CONNECT_TIMEOUT` in the Claude session on 2026-10-16) and continue with the fake-server tests only.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: add a minimal stdio MCP client"
```

---

### Task 7: Teams API and gateway

**Files:**
- Create: `src/teams/api.ts`, `src/teams/gateway.ts`
- Test: `test/teams-api.test.ts`, `test/gateway.test.ts`

**Interfaces:**
- Consumes: `ToolResult`, `McpError`, `McpOptions`, `McpSession`, `openMcpSession` from `src/teams/mcp.ts`.
- Produces: `TeamsFailureKind = "unavailable" | "error"`; `TeamsFailure extends Error { kind }`; `TeamsUser { displayName: string | null; userPrincipalName: string; mail: string | null; id: string }`; `TeamsApi { searchUsers(query): Promise<TeamsUser[]>; openChat(email): Promise<string>; sendMessage(chatId, text): Promise<string> }`; `ToolCaller`; `escapeODataString`; `createTeamsApi(call: ToolCaller): TeamsApi`; `TeamsGateway { session<T>(use: (api: TeamsApi) => Promise<T>): Promise<T> }`; `createTeamsGateway(options: McpOptions, open?: (options: McpOptions) => Promise<McpSession>): TeamsGateway`.

Facts taken from the Teams MCP 1.0.1 source (read from the local npx cache, not run): `search_users` returns a JSON array of `{displayName, userPrincipalName, mail, id}`, or the text `No users found matching your search.`, or `❌ Error: …` (without `isError`); `create_chat` returns `✅ Chat created successfully. Chat ID: <id>` or `❌ Error: …`; `send_chat_message` returns `✅ Message sent successfully. Message ID: <id>` or an `isError` result starting `❌ Failed to send message:`.

- [ ] **Step 1: Write the failing tests**

`test/teams-api.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import type { ToolResult } from "../src/teams/mcp.ts";
import { TeamsFailure, createTeamsApi, escapeODataString } from "../src/teams/api.ts";

function fakeCaller(result: ToolResult): {
  calls: { name: string; args: Record<string, unknown> }[];
  call: (name: string, args: Readonly<Record<string, unknown>>) => Promise<ToolResult>;
} {
  const calls: { name: string; args: Record<string, unknown> }[] = [];
  return {
    calls,
    call: (name, args) => {
      calls.push({ name, args: { ...args } });
      return Promise.resolve(result);
    },
  };
}
const ok = (text: string): ToolResult => ({ text, isError: false });

describe("escapeODataString", () => {
  it("doubles single quotes so a name cannot break out of the filter", () => {
    expect(escapeODataString("O'Brien")).toBe("O''Brien");
    expect(escapeODataString("a') or (displayName ne '")).toBe("a'') or (displayName ne ''");
    expect(escapeODataString("100% ✓ \\")).toBe("100% ✓ \\");
  });
});

describe("searchUsers", () => {
  const users = [
    { displayName: "Rayhan A", userPrincipalName: "rayhan@x.id", mail: "rayhan@x.id", id: "u1" },
    { displayName: null, userPrincipalName: "svc@x.id", mail: null, id: "u2" },
  ];

  it("parses the JSON list and sends an escaped, trimmed query", async () => {
    const { calls, call } = fakeCaller(ok(JSON.stringify(users)));
    await expect(createTeamsApi(call).searchUsers("  O'Brien ")).resolves.toEqual(users);
    expect(calls).toEqual([{ name: "search_users", args: { query: "O''Brien" } }]);
  });

  it("shortens a very long query to 100 characters before escaping", async () => {
    const { calls, call } = fakeCaller(ok("No users found matching your search."));
    await createTeamsApi(call).searchUsers("x".repeat(300));
    expect(String(calls[0]?.args["query"])).toHaveLength(100);
  });

  it("returns an empty list without calling Teams for an empty query", async () => {
    const { calls, call } = fakeCaller(ok("[]"));
    await expect(createTeamsApi(call).searchUsers("   ")).resolves.toEqual([]);
    expect(calls).toHaveLength(0);
  });

  it("returns an empty list for the 'no users' text", async () => {
    const { call } = fakeCaller(ok("No users found matching your search."));
    await expect(createTeamsApi(call).searchUsers("zzz")).resolves.toEqual([]);
  });

  it("fails on error text that is not flagged as an error, on non-JSON and on a wrong shape", async () => {
    for (const text of ["❌ Error: Insufficient privileges", "<html>", '[{"id":1}]']) {
      const { call } = fakeCaller(ok(text));
      await expect(createTeamsApi(call).searchUsers("a")).rejects.toMatchObject({ kind: "error" });
    }
  });
});

describe("openChat", () => {
  it("returns the chat id from the success text", async () => {
    const { calls, call } = fakeCaller(ok("✅ Chat created successfully. Chat ID: 19:abc@unq.gbl.spaces"));
    await expect(createTeamsApi(call).openChat("rayhan@x.id")).resolves.toBe("19:abc@unq.gbl.spaces");
    expect(calls).toEqual([{ name: "create_chat", args: { userEmails: ["rayhan@x.id"] } }]);
  });

  it("fails when there is no chat id or the text is an error", async () => {
    for (const result of [ok("❌ Error: nope"), ok("✅ done"), { text: "x", isError: true }]) {
      const { call } = fakeCaller(result);
      await expect(createTeamsApi(call).openChat("a@x.id")).rejects.toBeInstanceOf(TeamsFailure);
    }
  });
});

describe("sendMessage", () => {
  it("sends plain text and returns the message id", async () => {
    const { calls, call } = fakeCaller(ok("✅ Message sent successfully. Message ID: 1699"));
    await expect(createTeamsApi(call).sendMessage("19:abc", "halo")).resolves.toBe("1699");
    expect(calls).toEqual([
      { name: "send_chat_message", args: { chatId: "19:abc", message: "halo", format: "text" } },
    ]);
  });

  it("fails on an error result or on text that does not confirm the send", async () => {
    for (const result of [
      { text: "❌ Failed to send message: 403", isError: true },
      ok("something else"),
    ]) {
      const { call } = fakeCaller(result);
      await expect(createTeamsApi(call).sendMessage("c", "t")).rejects.toMatchObject({
        kind: "error",
      });
    }
  });
});
```

`test/gateway.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { TeamsFailure } from "../src/teams/api.ts";
import { createTeamsGateway } from "../src/teams/gateway.ts";
import { McpError } from "../src/teams/mcp.ts";
import type { McpOptions, McpSession } from "../src/teams/mcp.ts";

const options: McpOptions = { command: "x", startTimeoutMs: 1000, callTimeoutMs: 1000 };

function fakeSession(callTool: McpSession["callTool"]): { session: McpSession; closed: () => number } {
  let closes = 0;
  return {
    session: {
      callTool,
      close: () => {
        closes += 1;
      },
    },
    closed: () => closes,
  };
}

describe("createTeamsGateway", () => {
  it("opens one session per use and always closes it", async () => {
    const fake = fakeSession(() => Promise.resolve({ text: "No users found matching your search.", isError: false }));
    const gateway = createTeamsGateway(options, () => Promise.resolve(fake.session));
    await expect(gateway.session((api) => api.searchUsers("a"))).resolves.toEqual([]);
    expect(fake.closed()).toBe(1);
    await expect(
      gateway.session(() => Promise.reject(new Error("boom"))),
    ).rejects.toThrow("boom");
    expect(fake.closed()).toBe(2);
  });

  it("reports a server that cannot be started as unavailable", async () => {
    const gateway = createTeamsGateway(options, () => Promise.reject(new McpError("timeout", "t")));
    await expect(gateway.session(() => Promise.resolve(1))).rejects.toMatchObject({
      name: "TeamsFailure",
      kind: "unavailable",
    });
  });

  it("maps transport problems to unavailable and protocol or server problems to error", async () => {
    const attempt = async (kind: McpError["kind"]): Promise<string> => {
      const fake = fakeSession(() => Promise.reject(new McpError(kind, "x")));
      const gateway = createTeamsGateway(options, () => Promise.resolve(fake.session));
      try {
        await gateway.session((api) => api.searchUsers("a"));
      } catch (error) {
        if (error instanceof TeamsFailure) return error.kind;
      }
      return "none";
    };
    expect(await attempt("timeout")).toBe("unavailable");
    expect(await attempt("closed")).toBe("unavailable");
    expect(await attempt("spawn")).toBe("unavailable");
    expect(await attempt("protocol")).toBe("error");
    expect(await attempt("server")).toBe("error");
  });
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `npx vitest run test/teams-api.test.ts test/gateway.test.ts`
Expected: FAIL — cannot resolve the new modules.

- [ ] **Step 3: Implement `src/teams/api.ts`**

```ts
import { z } from "zod";
import type { ToolResult } from "./mcp.ts";

export type TeamsFailureKind = "unavailable" | "error";

export class TeamsFailure extends Error {
  readonly kind: TeamsFailureKind;

  constructor(kind: TeamsFailureKind, message: string) {
    super(message);
    this.name = "TeamsFailure";
    this.kind = kind;
  }
}

export interface TeamsUser {
  readonly displayName: string | null;
  readonly userPrincipalName: string;
  readonly mail: string | null;
  readonly id: string;
}

export interface TeamsApi {
  searchUsers(query: string): Promise<TeamsUser[]>;
  /** Returns the id of the 1:1 chat with `email` (Graph returns the existing chat if there is one). */
  openChat(email: string): Promise<string>;
  /** Plain text only. Returns the message id, or "unknown" when the server does not report one. */
  sendMessage(chatId: string, text: string): Promise<string>;
}

export type ToolCaller = (
  name: string,
  args: Readonly<Record<string, unknown>>,
) => Promise<ToolResult>;

const MAX_QUERY_CHARACTERS = 100;

const usersSchema = z.array(
  z.object({
    displayName: z.string().nullable(),
    userPrincipalName: z.string(),
    mail: z.string().nullable(),
    id: z.string(),
  }),
);

/** The Teams MCP puts the query inside `startswith(displayName,'…')`: a quote must be doubled. */
export function escapeODataString(value: string): string {
  return value.replaceAll("'", "''");
}

/** The Teams MCP reports some failures as plain text starting with ❌ without setting isError. */
function failed(result: ToolResult): boolean {
  return result.isError || result.text.startsWith("❌");
}

export function createTeamsApi(call: ToolCaller): TeamsApi {
  return {
    async searchUsers(query) {
      const trimmed = [...query.trim()].slice(0, MAX_QUERY_CHARACTERS).join("");
      if (trimmed.length === 0) return [];
      const result = await call("search_users", { query: escapeODataString(trimmed) });
      if (failed(result)) throw new TeamsFailure("error", "search_users failed");
      if (result.text.startsWith("No users found")) return [];
      let raw: unknown;
      try {
        raw = JSON.parse(result.text);
      } catch {
        throw new TeamsFailure("error", "search_users returned text that is not JSON");
      }
      const parsed = usersSchema.safeParse(raw);
      if (!parsed.success) throw new TeamsFailure("error", "search_users returned an unexpected shape");
      return parsed.data;
    },

    async openChat(email) {
      const result = await call("create_chat", { userEmails: [email] });
      const id = /Chat ID:\s*(\S+)/.exec(result.text)?.[1];
      if (failed(result) || id === undefined) throw new TeamsFailure("error", "create_chat failed");
      return id;
    },

    async sendMessage(chatId, text) {
      const result = await call("send_chat_message", { chatId, message: text, format: "text" });
      if (failed(result) || !result.text.includes("sent successfully")) {
        throw new TeamsFailure("error", "send_chat_message failed");
      }
      return /Message ID:\s*(\S+)/.exec(result.text)?.[1] ?? "unknown";
    },
  };
}
```

- [ ] **Step 4: Implement `src/teams/gateway.ts`**

```ts
import { TeamsFailure, createTeamsApi } from "./api.ts";
import type { TeamsApi } from "./api.ts";
import { McpError, openMcpSession } from "./mcp.ts";
import type { McpOptions, McpSession } from "./mcp.ts";

export interface TeamsGateway {
  /** Starts the Teams MCP, runs `use` with an API bound to it, and always stops the server again. */
  session<T>(use: (api: TeamsApi) => Promise<T>): Promise<T>;
}

function toFailure(error: unknown): TeamsFailure {
  if (error instanceof TeamsFailure) return error;
  if (error instanceof McpError) {
    const transport = error.kind === "spawn" || error.kind === "timeout" || error.kind === "closed";
    return new TeamsFailure(transport ? "unavailable" : "error", `MCP ${error.kind}`);
  }
  return new TeamsFailure("error", "unexpected Teams failure");
}

export function createTeamsGateway(
  options: McpOptions,
  open: (options: McpOptions) => Promise<McpSession> = openMcpSession,
): TeamsGateway {
  return {
    async session(use) {
      let mcp: McpSession;
      try {
        mcp = await open(options);
      } catch (error) {
        throw toFailure(error);
      }
      const api = createTeamsApi(async (name, args) => {
        try {
          return await mcp.callTool(name, args);
        } catch (error) {
          throw toFailure(error);
        }
      });
      try {
        return await use(api);
      } finally {
        mcp.close();
      }
    },
  };
}
```

- [ ] **Step 5: Run the checks**

Run: `npx prettier --write . && npm run check`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: add the Teams API wrapper and per-use MCP gateway"
```

---

### Task 8: Identity resolution

**Files:**
- Create: `src/teams/identity.ts`
- Test: `test/identity.test.ts`

**Interfaces:**
- Consumes: `TeamsApi`, `TeamsUser`, `Person`, `Store["loadIdentity" | "saveIdentity"]`.
- Produces: `Resolution = { kind: "resolved"; email: string } | { kind: "unresolved"; reason: "no-match" | "ambiguous" }`; `IdentityDeps { api: Pick<TeamsApi, "searchUsers">; store: Pick<Store, "loadIdentity" | "saveIdentity">; people: Readonly<Record<string, string>>; now: () => number }`; `normalizeName(name: string): string`; `resolveEmail(deps: IdentityDeps, person: Person): Promise<Resolution>`.

Order: the `teams.people` map from the config, then the cache, then a Teams search accepted only on an exact (normalised) display-name match to exactly one Teams user.

- [ ] **Step 1: Write the failing tests**

`test/identity.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { TeamsFailure } from "../src/teams/api.ts";
import type { TeamsUser } from "../src/teams/api.ts";
import { normalizeName, resolveEmail } from "../src/teams/identity.ts";
import type { IdentityDeps } from "../src/teams/identity.ts";
import { openStore } from "../src/store.ts";
import { person } from "./builders.ts";

const user = (displayName: string | null, id: string, mail: string | null = `${id}@x.id`): TeamsUser => ({
  displayName,
  userPrincipalName: `${id}@upn.x.id`,
  mail,
  id,
});

function setup(options: { found?: TeamsUser[]; people?: Record<string, string>; fail?: Error } = {}) {
  const store = openStore(":memory:");
  const queries: string[] = [];
  const deps: IdentityDeps = {
    api: {
      searchUsers: (query) => {
        queries.push(query);
        return options.fail === undefined ? Promise.resolve(options.found ?? []) : Promise.reject(options.fail);
      },
    },
    store,
    people: options.people ?? {},
    now: () => 1000,
  };
  return { deps, store, queries };
}

describe("normalizeName", () => {
  it("ignores case, repeated spaces, accents composition and surrounding whitespace", () => {
    expect(normalizeName("  Rayhan   ASWIANSYAH ")).toBe("rayhan aswiansyah");
    expect(normalizeName("José")).toBe(normalizeName("José"));
  });
});

describe("resolveEmail", () => {
  it("prefers the people map and never searches", async () => {
    const { deps, queries } = setup({ people: { "20435": "rayhan@madhani.id" } });
    await expect(resolveEmail(deps, person("20435", "Rayhan"))).resolves.toEqual({
      kind: "resolved",
      email: "rayhan@madhani.id",
    });
    expect(queries).toEqual([]);
  });

  it("uses the cache before searching", async () => {
    const { deps, store, queries } = setup();
    store.saveIdentity("20435", "cached@madhani.id", 1);
    await expect(resolveEmail(deps, person("20435", "Rayhan"))).resolves.toEqual({
      kind: "resolved",
      email: "cached@madhani.id",
    });
    expect(queries).toEqual([]);
  });

  it("accepts exactly one exact display-name match and caches it", async () => {
    const { deps, store } = setup({ found: [user("Rayhan Aswiansyah", "u1")] });
    await expect(resolveEmail(deps, person("20435", "rayhan  aswiansyah"))).resolves.toEqual({
      kind: "resolved",
      email: "u1@x.id",
    });
    expect(store.loadIdentity("20435")).toBe("u1@x.id");
  });

  it("does not accept a prefix match", async () => {
    const { deps, store } = setup({ found: [user("Rayhan Aswiansyah", "u1")] });
    await expect(resolveEmail(deps, person("20435", "Rayhan"))).resolves.toEqual({
      kind: "unresolved",
      reason: "no-match",
    });
    expect(store.loadIdentity("20435")).toBeUndefined();
  });

  it("refuses two different people with the same display name", async () => {
    const { deps } = setup({ found: [user("Budi Santoso", "u1"), user("Budi  Santoso", "u2")] });
    await expect(resolveEmail(deps, person("1", "Budi Santoso"))).resolves.toEqual({
      kind: "unresolved",
      reason: "ambiguous",
    });
  });

  it("falls back to the user principal name when there is no mail", async () => {
    const { deps } = setup({ found: [user("Siti", "u3", null)] });
    await expect(resolveEmail(deps, person("1", "Siti"))).resolves.toEqual({
      kind: "resolved",
      email: "u3@upn.x.id",
    });
  });

  it("skips users without a display name and never searches for a deleted GitLab user", async () => {
    const { deps, queries } = setup({ found: [user(null, "u4")] });
    await expect(resolveEmail(deps, person("1", "Siti"))).resolves.toMatchObject({ reason: "no-match" });
    await expect(resolveEmail(deps, person("ghost", "(unknown user)"))).resolves.toMatchObject({
      reason: "no-match",
    });
    expect(queries).toEqual(["Siti"]);
  });

  it("lets a failing search surface so the message can wait", async () => {
    const { deps } = setup({ fail: new TeamsFailure("unavailable", "down") });
    await expect(resolveEmail(deps, person("1", "Siti"))).rejects.toMatchObject({ kind: "unavailable" });
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npx vitest run test/identity.test.ts`
Expected: FAIL — cannot resolve `../src/teams/identity.ts`.

- [ ] **Step 3: Implement `src/teams/identity.ts`**

```ts
import type { Person } from "../domain.ts";
import type { Store } from "../store.ts";
import type { TeamsApi } from "./api.ts";

export type Resolution =
  | { readonly kind: "resolved"; readonly email: string }
  | { readonly kind: "unresolved"; readonly reason: "no-match" | "ambiguous" };

export interface IdentityDeps {
  readonly api: Pick<TeamsApi, "searchUsers">;
  readonly store: Pick<Store, "loadIdentity" | "saveIdentity">;
  readonly people: Readonly<Record<string, string>>;
  readonly now: () => number;
}

const DELETED_USER = "ghost";

export function normalizeName(name: string): string {
  return name.normalize("NFKC").toLowerCase().replace(/\s+/g, " ").trim();
}

/**
 * GitLab gives a display name and an employee ID, never an email. Resolution order: the
 * `teams.people` map, the cache, then a Teams search accepted only when exactly one Teams user has
 * the same display name. A guess would send a message to the wrong person, so anything less
 * certain is "unresolved" and the Owner adds a line to `teams.people`.
 */
export async function resolveEmail(deps: IdentityDeps, person: Person): Promise<Resolution> {
  const mapped = deps.people[person.username];
  if (mapped !== undefined) return { kind: "resolved", email: mapped };
  const cached = deps.store.loadIdentity(person.username);
  if (cached !== undefined) return { kind: "resolved", email: cached };
  if (person.username === DELETED_USER) return { kind: "unresolved", reason: "no-match" };

  const wanted = normalizeName(person.name);
  const found = await deps.api.searchUsers(person.name);
  const matches = found.filter(
    (candidate) => candidate.displayName !== null && normalizeName(candidate.displayName) === wanted,
  );
  const ids = new Set(matches.map((candidate) => candidate.id));
  const [only] = matches;
  if (ids.size === 0 || only === undefined) return { kind: "unresolved", reason: "no-match" };
  if (ids.size > 1) return { kind: "unresolved", reason: "ambiguous" };
  const email = only.mail ?? only.userPrincipalName;
  deps.store.saveIdentity(person.username, email, deps.now());
  return { kind: "resolved", email };
}
```

- [ ] **Step 4: Run the checks**

Run: `npx prettier --write . && npm run check`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: resolve GitLab people to Teams users without guessing"
```

---

### Task 9: Dispatcher (modes, hours, at-most-once)

**Files:**
- Create: `src/teams/dispatch.ts`
- Test: `test/dispatch.test.ts`

**Interfaces:**
- Consumes: `Store` methods from Task 2, `TeamsGateway`/`TeamsApi`/`TeamsFailure`/`TeamsFailureKind`, `resolveEmail`, `Templates`/`renderTemplate`/`Placeholder`, `isWithinWorkingHours`, `clean` from `src/format.ts`, `Config["teams"]`, `Snapshot`, `OutboxRow`.
- Produces: `SendMode`; `DispatchDeps { store; gateway; templates; config: Pick<Config["teams"], "modes" | "workingHours" | "people">; log; now: () => number }`; `DispatchResult { sent: number; failure: TeamsFailureKind | undefined }`; `DeliverOutcome`; `modeFor(kind, config)`; `deliver(deps, api, row, text)`; `dispatchQueued(deps, snapshot)`; `SendPendingOutcome`; `sendPending(deps, id)`; `skipOutbox(store, id, now)`; `retryOutbox(store, id, now)`.

Behaviour: a queued row that is no longer needed (the Reviewer reviewed, the MR is gone or draft) becomes `skipped`; outside working hours rows stay `queued`; `dry-run` and `approval` rows get their rendered text and become `dry-run` / `pending`; `auto` rows are sent. A send first resolves the email (a lookup failure leaves the row as it was and stops the batch), then moves the row to `sending` with compare-and-set, and only then talks to Teams. Any error after that makes the row `failed` and is never retried by code; the batch stops at the first failure so unattempted rows stay `queued`.

- [ ] **Step 1: Write the failing tests**

`test/dispatch.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { createLogger } from "../src/log.ts";
import { openStore } from "../src/store.ts";
import type { Store } from "../src/store.ts";
import { TeamsFailure } from "../src/teams/api.ts";
import type { TeamsApi } from "../src/teams/api.ts";
import {
  dispatchQueued,
  retryOutbox,
  sendPending,
  skipOutbox,
} from "../src/teams/dispatch.ts";
import type { DispatchDeps, SendMode } from "../src/teams/dispatch.ts";
import type { TeamsGateway } from "../src/teams/gateway.ts";
import { DEFAULT_TEMPLATES } from "../src/teams/templates.ts";
import { ME, mr, person, reviewer, snapshot } from "./builders.ts";
import { NOW, intent, teamsPlan } from "./teams-builders.ts";

// Local times: Wednesday 10:00 is inside the default hours, Wednesday 20:00 is not.
const WORKING = new Date(2026, 9, 14, 10, 0).getTime();
const EVENING = new Date(2026, 9, 14, 20, 0).getTime();
const hours = { start: "09:00", end: "17:00", days: [1, 2, 3, 4, 5] };

function setup(options: { mode?: SendMode; now?: number; api?: Partial<TeamsApi> } = {}) {
  const store = openStore(":memory:");
  const sent: { chatId: string; text: string }[] = [];
  const opened: string[] = [];
  let sessions = 0;
  const api: TeamsApi = {
    searchUsers: () =>
      Promise.resolve([
        { displayName: "Bob", userPrincipalName: "bob@upn.x.id", mail: "bob@x.id", id: "u1" },
        { displayName: "Carol", userPrincipalName: "carol@upn.x.id", mail: "carol@x.id", id: "u2" },
      ]),
    openChat: (email) => {
      opened.push(email);
      return Promise.resolve(`chat-${email}`);
    },
    sendMessage: (chatId, text) => {
      sent.push({ chatId, text });
      return Promise.resolve("m1");
    },
    ...options.api,
  };
  const gateway: TeamsGateway = {
    session: (use) => {
      sessions += 1;
      return use(api);
    },
  };
  let now = options.now ?? WORKING;
  const mode = options.mode ?? "auto";
  const deps: DispatchDeps = {
    store,
    gateway,
    templates: DEFAULT_TEMPLATES,
    config: { modes: { nudge: mode, notice: mode }, workingHours: hours, people: {} },
    log: createLogger({ write: () => undefined }),
    now: () => now,
  };
  return {
    deps,
    store,
    sent,
    opened,
    sessions: () => sessions,
    setNow: (value: number) => {
      now = value;
    },
  };
}

const own = (reviewers = [reviewer("bob", "UNREVIEWED", "Bob")]) =>
  snapshot({ authored: [mr(5, { author: ME, title: "Add thing", reviewers })] });

function enqueue(store: Store, ...slots: number[]): number[] {
  store.applyTeamsPlan(
    teamsPlan({ intents: slots.map((slot) => intent(slot, { dedupeKey: `k:${slot}` })) }),
    NOW,
  );
  return store.listOutbox(["queued"]).map((row) => row.id);
}

describe("dispatchQueued", () => {
  it("sends in auto mode with one session, resolving the email and using the template", async () => {
    const h = setup();
    const [id] = enqueue(h.store, 1);
    const result = await dispatchQueued(h.deps, own());
    expect(result).toEqual({ sent: 1, failure: undefined });
    expect(h.sessions()).toBe(1);
    expect(h.opened).toEqual(["bob@x.id"]);
    expect(h.sent).toEqual([
      {
        chatId: "chat-bob@x.id",
        text: "Halo Bob, boleh minta tolong review MR ini? Add thing\nhttps://gitlab.example/g/p/-/merge_requests/5\nTerima kasih!",
      },
    ]);
    expect(h.store.getOutbox(id ?? 0)).toMatchObject({ status: "sent" });
  });

  it("opens one session for several messages", async () => {
    const h = setup();
    enqueue(h.store, 1, 2);
    await dispatchQueued(h.deps, own());
    expect(h.sessions()).toBe(1);
    expect(h.sent).toHaveLength(2);
  });

  it("holds the rendered text for approval and opens no session", async () => {
    const h = setup({ mode: "approval" });
    const [id] = enqueue(h.store, 1);
    await dispatchQueued(h.deps, own());
    expect(h.sessions()).toBe(0);
    expect(h.sent).toEqual([]);
    expect(h.store.getOutbox(id ?? 0)).toMatchObject({ status: "pending" });
    expect(h.store.getOutbox(id ?? 0)?.text).toContain("Halo Bob");
  });

  it("records a dry run with its text and sends nothing", async () => {
    const h = setup({ mode: "dry-run" });
    const [id] = enqueue(h.store, 1);
    await dispatchQueued(h.deps, own());
    expect(h.sessions()).toBe(0);
    expect(h.store.getOutbox(id ?? 0)).toMatchObject({ status: "dry-run" });
    expect(h.store.getOutbox(id ?? 0)?.text).toContain("Halo Bob");
  });

  it("uses the notice mode for notices and the nudge mode for nudges", async () => {
    const h = setup();
    h.deps = {
      ...h.deps,
      config: { ...h.deps.config, modes: { nudge: "approval", notice: "dry-run" } },
    };
    h.store.applyTeamsPlan(
      teamsPlan({
        intents: [
          intent(1),
          intent(2, {
            dedupeKey: "notice:g/p!7:APPROVED:0",
            kind: "notice",
            variant: "notice.approved",
            mr: { key: "g/p!7", iid: 7, projectPath: "g/p", title: "Fix it", url: "https://gitlab.example/g/p/-/merge_requests/7" },
          }),
        ],
      }),
      NOW,
    );
    const both = snapshot({
      authored: [mr(5, { author: ME, reviewers: [reviewer("bob", "UNREVIEWED", "Bob")] })],
      reviewRequested: [mr(7, { reviewers: [reviewer("me", "APPROVED")] })],
    });
    await dispatchQueued(h.deps, both);
    expect(h.store.listOutbox(["pending"]).map((row) => row.kind)).toEqual(["nudge"]);
    expect(h.store.listOutbox(["dry-run"]).map((row) => row.kind)).toEqual(["notice"]);
  });

  it("keeps rows queued outside working hours and sends them once the hours begin", async () => {
    const h = setup({ now: EVENING });
    const [id] = enqueue(h.store, 1);
    await dispatchQueued(h.deps, own());
    expect(h.sessions()).toBe(0);
    expect(h.store.getOutbox(id ?? 0)).toMatchObject({ status: "queued" });
    h.setNow(WORKING + 24 * 3_600_000);
    await dispatchQueued(h.deps, own());
    expect(h.sent).toHaveLength(1);
  });

  it("skips a nudge when the Reviewer has reviewed in the meantime, or the MR is gone", async () => {
    const h = setup();
    const [first] = enqueue(h.store, 1);
    await dispatchQueued(h.deps, own([reviewer("bob", "APPROVED", "Bob")]));
    expect(h.store.getOutbox(first ?? 0)).toMatchObject({ status: "skipped", detail: "obsolete" });
    const [second] = enqueue(h.store, 2);
    await dispatchQueued(h.deps, snapshot());
    expect(h.store.getOutbox(second ?? 0)).toMatchObject({ status: "skipped" });
    expect(h.sent).toEqual([]);
  });

  it("sends a notice only while the MR is still waiting for the Owner's review", async () => {
    const h = setup();
    h.store.applyTeamsPlan(
      teamsPlan({
        intents: [
          intent(1, {
            dedupeKey: "notice:g/p!7:APPROVED:0",
            kind: "notice",
            variant: "notice.approved",
            mr: { key: "g/p!7", iid: 7, projectPath: "g/p", title: "Fix it", url: "https://gitlab.example/g/p/-/merge_requests/7" },
            recipient: person("bob", "Bob"),
          }),
        ],
      }),
      NOW,
    );
    const theirs = snapshot({ reviewRequested: [mr(7, { reviewers: [reviewer("me", "APPROVED")] })] });
    await dispatchQueued(h.deps, theirs);
    expect(h.sent[0]?.text).toContain("sudah saya review dan saya approve");
  });

  it("marks unresolved people without sending", async () => {
    const h = setup({ api: { searchUsers: () => Promise.resolve([]) } });
    const [id] = enqueue(h.store, 1);
    const result = await dispatchQueued(h.deps, own());
    expect(result.sent).toBe(0);
    expect(h.sent).toEqual([]);
    expect(h.store.getOutbox(id ?? 0)).toMatchObject({ status: "unresolved", detail: "no-match" });
  });

  it("sanitises values substituted into the text", async () => {
    const h = setup();
    h.store.applyTeamsPlan(
      teamsPlan({
        intents: [
          intent(1, {
            mr: { key: "g/p!5", iid: 5, projectPath: "g/p", title: "-evil\nsecond‮line", url: "https://gitlab.example/x" },
          }),
        ],
      }),
      NOW,
    );
    await dispatchQueued(h.deps, own());
    expect(h.sent[0]?.text).toContain("evil second line");
    expect(h.sent[0]?.text).not.toContain("‮");
  });
});

describe("failures", () => {
  it("leaves the row queued when the lookup fails, and reports it", async () => {
    const h = setup({
      api: { searchUsers: () => Promise.reject(new TeamsFailure("unavailable", "down")) },
    });
    const [id] = enqueue(h.store, 1);
    const result = await dispatchQueued(h.deps, own());
    expect(result).toEqual({ sent: 0, failure: "unavailable" });
    expect(h.store.getOutbox(id ?? 0)).toMatchObject({ status: "queued" });
  });

  it("reports a Teams server that cannot start and leaves everything queued", async () => {
    const h = setup();
    h.deps = {
      ...h.deps,
      gateway: { session: () => Promise.reject(new TeamsFailure("unavailable", "no server")) },
    };
    const [id] = enqueue(h.store, 1);
    expect(await dispatchQueued(h.deps, own())).toEqual({ sent: 0, failure: "unavailable" });
    expect(h.store.getOutbox(id ?? 0)).toMatchObject({ status: "queued" });
  });
});

describe("at most once", () => {
  it("a failed send is final: the row is failed, later passes do not resend it, and the rest of the batch waits", async () => {
    let calls = 0;
    const h = setup({
      api: {
        sendMessage: (chatId, text) => {
          calls += 1;
          if (calls === 1) return Promise.reject(new TeamsFailure("error", "403"));
          h.sent.push({ chatId, text });
          return Promise.resolve("m2");
        },
      },
    });
    const [first, second] = enqueue(h.store, 1, 2);
    const firstPass = await dispatchQueued(h.deps, own());
    expect(firstPass).toEqual({ sent: 0, failure: "error" });
    expect(h.store.getOutbox(first ?? 0)).toMatchObject({ status: "failed", detail: "error" });
    expect(h.store.getOutbox(second ?? 0)).toMatchObject({ status: "queued" });

    const secondPass = await dispatchQueued(h.deps, own());
    expect(secondPass).toEqual({ sent: 1, failure: undefined });
    expect(calls).toBe(2);
    expect(h.store.getOutbox(first ?? 0)).toMatchObject({ status: "failed" });
    expect(h.store.getOutbox(second ?? 0)).toMatchObject({ status: "sent" });
  });

  it("a row stuck in 'sending' (a crash) is never picked up again", async () => {
    const h = setup();
    const [id] = enqueue(h.store, 1);
    h.store.transitionOutbox(id ?? 0, "queued", "sending", { text: "halo" }, NOW);
    await dispatchQueued(h.deps, own());
    expect(h.sent).toEqual([]);
    expect(await sendPending(h.deps, id ?? 0)).toEqual({ status: "not-pending" });
  });

  it("two simultaneous sends of the same pending row result in one message", async () => {
    const h = setup({ mode: "approval" });
    const [id] = enqueue(h.store, 1);
    await dispatchQueued(h.deps, own());
    const outcomes = await Promise.all([sendPending(h.deps, id ?? 0), sendPending(h.deps, id ?? 0)]);
    expect(outcomes.map((o) => o.status).sort()).toEqual(["busy", "sent"]);
    expect(h.sent).toHaveLength(1);
  });

  it("switching a flow from approval to auto does not send rows that are already pending", async () => {
    const h = setup({ mode: "approval" });
    enqueue(h.store, 1);
    await dispatchQueued(h.deps, own());
    h.deps = { ...h.deps, config: { ...h.deps.config, modes: { nudge: "auto", notice: "auto" } } };
    await dispatchQueued(h.deps, own());
    expect(h.sent).toEqual([]);
    expect(h.store.listOutbox(["pending"])).toHaveLength(1);
  });
});

describe("owner actions", () => {
  it("sends a pending row on request and reports unknown ids", async () => {
    const h = setup({ mode: "approval" });
    const [id] = enqueue(h.store, 1);
    await dispatchQueued(h.deps, own());
    expect(await sendPending(h.deps, id ?? 0)).toEqual({ status: "sent" });
    expect(await sendPending(h.deps, 9999)).toEqual({ status: "not-found" });
    expect(h.sent).toHaveLength(1);
  });

  it("keeps a pending row pending when Teams is unreachable", async () => {
    const h = setup({ mode: "approval" });
    const [id] = enqueue(h.store, 1);
    await dispatchQueued(h.deps, own());
    h.deps = {
      ...h.deps,
      gateway: { session: () => Promise.reject(new TeamsFailure("unavailable", "down")) },
    };
    expect(await sendPending(h.deps, id ?? 0)).toEqual({ status: "retry-later", failure: "unavailable" });
    expect(h.store.getOutbox(id ?? 0)).toMatchObject({ status: "pending" });
  });

  it("skips pending, unresolved and queued rows but never a sent one, and retries only unresolved rows", async () => {
    const h = setup({ api: { searchUsers: () => Promise.resolve([]) } });
    const [id] = enqueue(h.store, 1);
    await dispatchQueued(h.deps, own());
    expect(h.store.getOutbox(id ?? 0)).toMatchObject({ status: "unresolved" });
    expect(retryOutbox(h.store, id ?? 0, NOW)).toBe(true);
    expect(h.store.getOutbox(id ?? 0)).toMatchObject({ status: "queued" });
    expect(retryOutbox(h.store, id ?? 0, NOW)).toBe(false);
    expect(skipOutbox(h.store, id ?? 0, NOW)).toBe(true);
    expect(skipOutbox(h.store, id ?? 0, NOW)).toBe(false);
  });
});
```


- [ ] **Step 2: Run to verify it fails**

Run: `npx vitest run test/dispatch.test.ts`
Expected: FAIL — cannot resolve `../src/teams/dispatch.ts`.

- [ ] **Step 3: Implement `src/teams/dispatch.ts`**

```ts
import type { Config } from "../config.ts";
import { UNREVIEWED } from "../domain.ts";
import type { Snapshot } from "../domain.ts";
import { clean } from "../format.ts";
import type { Logger } from "../log.ts";
import type { Store } from "../store.ts";
import { TeamsFailure } from "./api.ts";
import type { TeamsApi, TeamsFailureKind } from "./api.ts";
import type { TeamsGateway } from "./gateway.ts";
import { isWithinWorkingHours } from "./hours.ts";
import { resolveEmail } from "./identity.ts";
import type { Resolution } from "./identity.ts";
import { renderTemplate } from "./templates.ts";
import type { Placeholder, Templates } from "./templates.ts";
import type { OutboxKind, OutboxRow } from "./types.ts";

type TeamsStore = Pick<
  Store,
  "listOutbox" | "getOutbox" | "transitionOutbox" | "loadIdentity" | "saveIdentity"
>;

export type SendMode = Config["teams"]["modes"]["nudge"];

export interface DispatchDeps {
  readonly store: TeamsStore;
  readonly gateway: TeamsGateway;
  readonly templates: Templates;
  readonly config: Pick<Config["teams"], "modes" | "workingHours" | "people">;
  readonly log: Logger;
  readonly now: () => number;
}

export interface DispatchResult {
  readonly sent: number;
  readonly failure: TeamsFailureKind | undefined;
}

export type DeliverOutcome =
  | { readonly status: "sent" | "unresolved" | "busy" }
  | { readonly status: "failed" | "retry-later"; readonly failure: TeamsFailureKind };

export type SendPendingOutcome = DeliverOutcome | { readonly status: "not-found" | "not-pending" };

const TITLE_MAX = 120;
const NAME_MAX = 60;

export function modeFor(kind: OutboxKind, config: Pick<Config["teams"], "modes">): SendMode {
  return kind === "notice" ? config.modes.notice : config.modes.nudge;
}

function failureKind(error: unknown): TeamsFailureKind {
  return error instanceof TeamsFailure ? error.kind : "error";
}

/** Is the message still worth sending now? Re-checked at send time, not only when it was queued. */
function stillNeeded(row: OutboxRow, snapshot: Snapshot): boolean {
  if (row.kind === "notice") {
    return snapshot.reviewRequested.some((mr) => mr.key === row.mrKey && !mr.draft);
  }
  const mr = snapshot.authored.find((candidate) => candidate.key === row.mrKey);
  if (mr === undefined || mr.draft) return false;
  return mr.reviewers.some(
    (reviewer) => reviewer.username === row.recipient && reviewer.state === UNREVIEWED,
  );
}

function valuesFor(row: OutboxRow, ownerName: string): Record<Placeholder, string> {
  return {
    "mr.title": clean(row.mrTitle, TITLE_MAX),
    "mr.url": row.mrUrl,
    "mr.iid": String(row.mrIid),
    "mr.project": row.mrProject,
    "person.name": clean(row.recipientName, NAME_MAX),
    "owner.name": clean(ownerName, NAME_MAX),
  };
}

/**
 * Sends one row, which must currently be `queued` or `pending`. The row moves to `sending`
 * (compare-and-set) before anything that can deliver a message, and from there it can only end
 * as `sent` or `failed`: no code path sends a row twice.
 */
export async function deliver(
  deps: DispatchDeps,
  api: TeamsApi,
  row: OutboxRow,
  text: string,
): Promise<DeliverOutcome> {
  const from = row.status;
  let resolution: Resolution;
  try {
    resolution = await resolveEmail(
      { api, store: deps.store, people: deps.config.people, now: deps.now },
      { username: row.recipient, name: row.recipientName },
    );
  } catch (error) {
    // Nothing has been sent yet, so the row simply stays as it is.
    return { status: "retry-later", failure: failureKind(error) };
  }
  if (resolution.kind === "unresolved") {
    deps.store.transitionOutbox(row.id, from, "unresolved", { detail: resolution.reason, text }, deps.now());
    return { status: "unresolved" };
  }
  if (!deps.store.transitionOutbox(row.id, from, "sending", { text }, deps.now())) {
    return { status: "busy" };
  }
  try {
    const chatId = await api.openChat(resolution.email);
    await api.sendMessage(chatId, text);
  } catch (error) {
    const kind = failureKind(error);
    deps.store.transitionOutbox(row.id, "sending", "failed", { detail: kind }, deps.now());
    return { status: "failed", failure: kind };
  }
  deps.store.transitionOutbox(row.id, "sending", "sent", {}, deps.now());
  return { status: "sent" };
}

async function sendBatch(
  deps: DispatchDeps,
  batch: readonly { readonly row: OutboxRow; readonly text: string }[],
): Promise<DispatchResult> {
  let sent = 0;
  let failure: TeamsFailureKind | undefined;
  try {
    await deps.gateway.session(async (api) => {
      for (const { row, text } of batch) {
        const outcome = await deliver(deps, api, row, text);
        if (outcome.status === "sent") sent += 1;
        if (outcome.status === "failed" || outcome.status === "retry-later") {
          // Stop: the rows after this one were never attempted and stay queued.
          failure = outcome.failure;
          return;
        }
      }
    });
  } catch (error) {
    failure = failureKind(error);
  }
  return { sent, failure };
}

/** Turns `queued` rows into pending / dry-run / sent according to each flow's mode. */
export async function dispatchQueued(deps: DispatchDeps, snapshot: Snapshot): Promise<DispatchResult> {
  const rows = deps.store.listOutbox(["queued"]);
  const nowMs = deps.now();
  const inHours = isWithinWorkingHours(new Date(nowMs), deps.config.workingHours);
  const automatic: { row: OutboxRow; text: string }[] = [];

  for (const row of rows) {
    if (!stillNeeded(row, snapshot)) {
      deps.store.transitionOutbox(row.id, "queued", "skipped", { detail: "obsolete" }, nowMs);
      continue;
    }
    if (!inHours) continue;
    let text: string;
    try {
      text = renderTemplate(deps.templates[row.variant], valuesFor(row, snapshot.me.name));
    } catch {
      deps.store.transitionOutbox(row.id, "queued", "failed", { detail: "template" }, nowMs);
      continue;
    }
    const mode = modeFor(row.kind, deps.config);
    if (mode === "dry-run") {
      deps.store.transitionOutbox(row.id, "queued", "dry-run", { text }, nowMs);
      deps.log.info("dry-run message recorded", { kind: row.kind });
    } else if (mode === "approval") {
      deps.store.transitionOutbox(row.id, "queued", "pending", { text }, nowMs);
    } else {
      automatic.push({ row, text });
    }
  }
  if (automatic.length === 0) return { sent: 0, failure: undefined };
  return sendBatch(deps, automatic);
}

/** `mra send <id>`: sends one row that is waiting for the Owner's approval. */
export async function sendPending(deps: DispatchDeps, id: number): Promise<SendPendingOutcome> {
  const row = deps.store.getOutbox(id);
  if (row === undefined) return { status: "not-found" };
  if (row.status !== "pending" || row.text === null) return { status: "not-pending" };
  const text = row.text;
  try {
    return await deps.gateway.session((api) => deliver(deps, api, row, text));
  } catch (error) {
    return { status: "retry-later", failure: failureKind(error) };
  }
}

/** `mra skip <id>`: true when a pending, unresolved or queued row was skipped. */
export function skipOutbox(store: Pick<Store, "transitionOutbox">, id: number, now: number): boolean {
  return (["pending", "unresolved", "queued"] as const).some((from) =>
    store.transitionOutbox(id, from, "skipped", { detail: "skipped by owner" }, now),
  );
}

/** `mra retry <id>`: puts an unresolved row back in the queue after the Owner fixed `teams.people`. */
export function retryOutbox(store: Pick<Store, "transitionOutbox">, id: number, now: number): boolean {
  return store.transitionOutbox(id, "unresolved", "queued", { detail: "" }, now);
}
```

- [ ] **Step 4: Run the checks**

Run: `npx prettier --write . && npm run check`
Expected: all pass. The "two simultaneous sends" test relies on both calls awaiting the email resolution before either reaches the compare-and-set; if it flakes, the code is wrong (the compare-and-set must be the only gate), not the test.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: dispatch queued messages by mode, hours and the at-most-once rule"
```

---

### Task 10: Poll-cycle wiring and the Teams service

**Files:**
- Create: `src/teams/service.ts`
- Modify (replace whole file): `src/failures.ts`, `src/poller.ts`, `src/runtime.ts`
- Test: `test/service.test.ts`, `test/poller-teams.test.ts`

**Interfaces:**
- Consumes: everything above; Plan 1's `reportFailure`/`reportStateFailure` pattern.
- Produces: `TeamsHooks { plan(snapshot, previous): void; dispatch(snapshot): Promise<{ failure: TeamsFailureKind | undefined }> }` (declared in `poller.ts`, optional `teams?: TeamsHooks` on `PollDeps`); `TeamsService extends TeamsHooks { sendPending(id): Promise<SendPendingOutcome>; list(all: boolean): OutboxRow[]; skip(id): boolean; retry(id): boolean; selfTest(): Promise<void> }`; `createTeamsService(deps: ServiceDeps): TeamsService`; failure kinds `"teams-unavailable"` (reported after 2 consecutive failures) and `"teams-error"` (immediately); `Runtime.teams: TeamsService | undefined`.

Ordering rule, deliberately different from the Owner notifications: Teams planning runs only **after** the state commit succeeded (so a failing commit can never inflate the nudge counters) and the dispatch runs last. A Teams failure never changes the poll status.

- [ ] **Step 1: Write the failing tests**

`test/service.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { createLogger } from "../src/log.ts";
import { openStore } from "../src/store.ts";
import { TeamsFailure } from "../src/teams/api.ts";
import type { TeamsApi } from "../src/teams/api.ts";
import { createTeamsService } from "../src/teams/service.ts";
import type { ServiceDeps } from "../src/teams/service.ts";
import { DEFAULT_TEMPLATES } from "../src/teams/templates.ts";
import { ME, mr, previous, reviewer, snapshot } from "./builders.ts";

const WORKING = new Date(2026, 9, 14, 10, 0).getTime();
const teamsConfig: ServiceDeps["config"] = {
  enabled: true,
  startTimeoutSeconds: 30,
  callTimeoutSeconds: 60,
  modes: { nudge: "approval", notice: "approval" },
  workingHours: { start: "09:00", end: "17:00", days: [1, 2, 3, 4, 5] },
  reminderAfterHours: 24,
  noticeDebounceMinutes: 10,
  maxMessagesPerReviewer: 2,
  people: {},
};

function setup(overrides: Partial<ServiceDeps> = {}) {
  const store = openStore(":memory:");
  const sent: string[] = [];
  const api: TeamsApi = {
    searchUsers: () => Promise.resolve([]),
    openChat: () => Promise.resolve("chat"),
    sendMessage: (_chat, text) => {
      sent.push(text);
      return Promise.resolve("m");
    },
  };
  const service = createTeamsService({
    store,
    gateway: { session: (use) => use(api) },
    templates: DEFAULT_TEMPLATES,
    config: teamsConfig,
    log: createLogger({ write: () => undefined }),
    now: () => WORKING,
    ...overrides,
  });
  return { service, store, sent };
}

const withNewReviewer = snapshot({
  authored: [mr(5, { author: ME, reviewers: [reviewer("bob", "UNREVIEWED", "Bob")] })],
});

describe("createTeamsService", () => {
  it("plans a nudge for a new Reviewer and holds it for approval", async () => {
    const { service, store } = setup();
    // Teams baseline first (nothing is announced), then a Reviewer appears.
    service.plan(snapshot(), previous());
    service.plan(withNewReviewer, previous());
    expect(store.listOutbox(["queued"])).toHaveLength(1);
    const result = await service.dispatch(withNewReviewer);
    expect(result).toEqual({ failure: undefined });
    expect(service.list(false).map((row) => [row.status, row.kind])).toEqual([["pending", "nudge"]]);
  });

  it("lists only rows that need attention unless asked for all", async () => {
    const { service } = setup();
    service.plan(snapshot(), previous());
    service.plan(withNewReviewer, previous());
    expect(service.list(false)).toHaveLength(0);
    expect(service.list(true)).toHaveLength(1);
    await service.dispatch(withNewReviewer);
    expect(service.list(false)).toHaveLength(1);
  });

  it("sends a pending row on request, and skips or retries rows", async () => {
    const { service, sent } = setup({
      gateway: {
        session: (use) =>
          use({
            searchUsers: () =>
              Promise.resolve([
                { displayName: "Bob", userPrincipalName: "b@x", mail: "b@x", id: "1" },
              ]),
            openChat: () => Promise.resolve("chat"),
            sendMessage: (_c, text) => {
              sent.push(text);
              return Promise.resolve("m");
            },
          }),
      },
    });
    service.plan(snapshot(), previous());
    service.plan(withNewReviewer, previous());
    await service.dispatch(withNewReviewer);
    const id = service.list(false)[0]?.id ?? 0;
    expect(await service.sendPending(id)).toEqual({ status: "sent" });
    expect(sent).toHaveLength(1);
    expect(service.skip(id)).toBe(false);
    expect(service.retry(id)).toBe(false);
  });

  it("turns an unexpected crash while dispatching into a reported failure instead of throwing", async () => {
    const { service } = setup({
      store: { ...openStore(":memory:"), listOutbox: () => { throw new Error("disk"); } },
    });
    await expect(service.dispatch(withNewReviewer)).resolves.toEqual({ failure: "error" });
  });

  it("reports an unreachable Teams as 'unavailable'", async () => {
    const { service } = setup({
      config: { ...teamsConfig, modes: { nudge: "auto", notice: "auto" } },
      gateway: { session: () => Promise.reject(new TeamsFailure("unavailable", "down")) },
    });
    service.plan(snapshot(), previous());
    service.plan(withNewReviewer, previous());
    await expect(service.dispatch(withNewReviewer)).resolves.toEqual({ failure: "unavailable" });
  });

  it("sends a connection test to the Owner's own notes chat", async () => {
    const calls: string[] = [];
    const { service } = setup({
      gateway: {
        session: (use) =>
          use({
            searchUsers: () => Promise.resolve([]),
            openChat: () => Promise.resolve("never"),
            sendMessage: (chatId) => {
              calls.push(chatId);
              return Promise.resolve("m");
            },
          }),
      },
    });
    await service.selfTest();
    expect(calls).toEqual(["48:notes"]);
  });
});
```

`test/poller-teams.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import type { Snapshot } from "../src/domain.ts";
import type { PreviousState } from "../src/events.ts";
import { createFailureTracker } from "../src/failures.ts";
import type { Notification } from "../src/format.ts";
import { createLogger } from "../src/log.ts";
import type { Notifier } from "../src/notifier.ts";
import { pollOnce } from "../src/poller.ts";
import type { PollDeps, TeamsHooks } from "../src/poller.ts";
import { openStore } from "../src/store.ts";
import type { Store } from "../src/store.ts";
import type { TeamsFailureKind } from "../src/teams/api.ts";
import { mr, reviewer, snapshot } from "./builders.ts";

const config: PollDeps["config"] = {
  gitlab: { hostname: "gitlab.example", glabPath: "glab", timeoutSeconds: 60 },
  notifications: { summaryThreshold: 4, ignoreAuthors: [] },
};

function harness(options: { planThrows?: boolean } = {}) {
  const realStore = openStore(":memory:");
  const sent: Notification[] = [];
  const events: string[] = [];
  const planned: PreviousState[] = [];
  let dispatchFailure: TeamsFailureKind | undefined;
  let commitError: Error | undefined;
  let current: Snapshot = snapshot();
  const store: Store = {
    ...realStore,
    commit: (next) => {
      if (commitError !== undefined) throw commitError;
      events.push("commit");
      realStore.commit(next);
    },
  };
  const notifier: Notifier = {
    notify: (notification) => {
      sent.push(notification);
      return Promise.resolve();
    },
  };
  const teams: TeamsHooks = {
    plan: (_snapshot, previous) => {
      events.push("plan");
      planned.push(previous);
      if (options.planThrows === true) throw new Error("db");
    },
    dispatch: () => {
      events.push("dispatch");
      return Promise.resolve({ failure: dispatchFailure });
    },
  };
  const deps: PollDeps = {
    fetchSnapshot: () => Promise.resolve(current),
    store,
    notifier,
    failures: createFailureTracker(),
    log: createLogger({ write: () => undefined }),
    config,
    teams,
  };
  return {
    sent,
    events,
    planned,
    poll: () => pollOnce(deps),
    setSnapshot: (next: Snapshot) => {
      current = next;
    },
    setDispatchFailure: (value: TeamsFailureKind | undefined) => {
      dispatchFailure = value;
    },
    setCommitError: (value: Error | undefined) => {
      commitError = value;
    },
  };
}

describe("pollOnce with Teams", () => {
  it("plans and dispatches after the state commit, with the state from before the poll", async () => {
    const h = harness();
    expect(await h.poll()).toBe("ok");
    expect(h.events).toEqual(["commit", "plan", "dispatch"]);
    expect(h.planned[0]?.baselineDone).toBe(false);
  });

  it("does nothing for Teams when the state commit fails, so counters cannot be inflated", async () => {
    const h = harness();
    h.setCommitError(new Error("busy"));
    expect(await h.poll()).toBe("failed");
    expect(h.events).toEqual([]);
  });

  it("reports an unavailable Teams only after two polls in a row, and never changes the poll status", async () => {
    const h = harness();
    h.setDispatchFailure("unavailable");
    expect(await h.poll()).toBe("ok");
    expect(h.sent.map((n) => n.title)).toEqual([]);
    expect(await h.poll()).toBe("ok");
    expect(h.sent.map((n) => n.title)).toEqual(["Teams tidak terhubung"]);
    expect(await h.poll()).toBe("ok");
    expect(h.sent).toHaveLength(1);
  });

  it("reports a Teams error at once, and again only after it has recovered", async () => {
    const h = harness();
    h.setDispatchFailure("error");
    await h.poll();
    await h.poll();
    expect(h.sent.map((n) => n.title)).toEqual(["Teams mengembalikan error"]);
    h.setDispatchFailure(undefined);
    await h.poll();
    h.setDispatchFailure("error");
    await h.poll();
    expect(h.sent).toHaveLength(2);
  });

  it("still delivers Owner notifications and commits when planning fails, and reports the state problem once", async () => {
    const h = harness({ planThrows: true });
    h.setSnapshot(snapshot({ reviewRequested: [mr(1, { reviewers: [reviewer("me", "UNREVIEWED")] })] }));
    expect(await h.poll()).toBe("ok");
    expect(h.sent.map((n) => n.title)).toContain("MR Review Assistant aktif");
    expect(h.sent.map((n) => n.title)).toContain("Penyimpanan state bermasalah");
    expect(h.events).toEqual(["commit", "plan"]);
  });
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `npx vitest run test/service.test.ts test/poller-teams.test.ts`
Expected: FAIL — cannot resolve `../src/teams/service.ts`; `TeamsHooks` is not exported by the poller.

- [ ] **Step 3: Replace `src/failures.ts`**

```ts
import type { Notification } from "./format.ts";
import type { GitlabFailureKind } from "./gitlab.ts";

export type TeamsFailureReportKind = "teams-unavailable" | "teams-error";
export type FailureKind = GitlabFailureKind | "notifier" | "state" | TeamsFailureReportKind;

export interface FailureTracker {
  /** Records a failure and returns how many polls in a row have now failed with this kind. */
  fail(kind: FailureKind): number;
  /** Clears a failure; true when it was failing. */
  recover(kind: FailureKind): boolean;
}

export function createFailureTracker(): FailureTracker {
  const streaks = new Map<FailureKind, number>();
  return {
    fail(kind) {
      const streak = (streaks.get(kind) ?? 0) + 1;
      streaks.set(kind, streak);
      return streak;
    },
    recover: (kind) => streaks.delete(kind),
  };
}

/**
 * How many consecutive failures of a kind before the Owner is told. A network that is not up yet
 * right after the Mac wakes is normal, so "unreachable" kinds need a second failure to be believed.
 */
export const NOTIFY_AFTER: Readonly<Record<FailureKind, number>> = {
  "glab-missing": 1,
  "gitlab-auth": 1,
  "gitlab-unreachable": 2,
  "gitlab-error": 1,
  notifier: 1,
  state: 1,
  "teams-unavailable": 2,
  "teams-error": 1,
};

export const STATE_FAILURE_NOTIFICATION: Notification = {
  title: "Penyimpanan state bermasalah",
  body: "MR Review Assistant tidak bisa menyimpan state. Alert bisa terulang; lihat log untuk detailnya.",
};

export function teamsFailureNotification(kind: TeamsFailureReportKind): Notification {
  return kind === "teams-unavailable"
    ? {
        title: "Teams tidak terhubung",
        body: "Pesan Teams menunggu dan akan dicoba lagi; pesan yang sudah gagal terkirim tidak diulang.",
      }
    : {
        title: "Teams mengembalikan error",
        body: "Jika login kedaluwarsa, jalankan ulang sh scripts/login.sh di repo teams-mcp-login.",
      };
}

export function failureNotification(kind: GitlabFailureKind, hostname: string): Notification {
  switch (kind) {
    case "glab-missing":
      return {
        title: "glab tidak ditemukan",
        body: "Pasang glab atau perbaiki PATH-nya supaya polling GitLab jalan lagi.",
      };
    case "gitlab-auth":
      return {
        title: "Login GitLab gagal",
        body: `Jalankan: glab auth login --hostname ${hostname}`,
      };
    case "gitlab-unreachable":
      return {
        title: "GitLab tidak terjangkau",
        body: "Akan dicoba lagi otomatis dengan jeda yang makin panjang.",
      };
    case "gitlab-error":
      return {
        title: "GitLab mengembalikan error",
        body: "Lihat log MR Review Assistant untuk detailnya.",
      };
  }
}
```

If Plan 1's `src/failures.ts` already exports `STATE_FAILURE_NOTIFICATION` and `NOTIFY_AFTER` (it does after the review fixes), this replacement keeps them and only adds the Teams kinds.

- [ ] **Step 4: Replace `src/poller.ts`**

```ts
import type { Config } from "./config.ts";
import type { Snapshot } from "./domain.ts";
import { countPendingReviews, detectEvents } from "./events.ts";
import type { PreviousState } from "./events.ts";
import { execFailure } from "./exec.ts";
import {
  NOTIFY_AFTER,
  STATE_FAILURE_NOTIFICATION,
  failureNotification,
  teamsFailureNotification,
} from "./failures.ts";
import type { FailureKind, FailureTracker, TeamsFailureReportKind } from "./failures.ts";
import type { Notification } from "./format.ts";
import { baselineNotifications, buildNotifications } from "./format.ts";
import { FetchFailure } from "./gitlab.ts";
import type { GitlabFailureKind } from "./gitlab.ts";
import type { Logger } from "./log.ts";
import type { Notifier } from "./notifier.ts";
import type { Store } from "./store.ts";
import type { TeamsFailureKind } from "./teams/api.ts";

/** What the poll cycle needs from the Teams feature; absent when `teams.enabled` is false. */
export interface TeamsHooks {
  /** Queues messages for this snapshot. `previous` is the state from before the poll. May throw. */
  plan(snapshot: Snapshot, previous: PreviousState): void;
  /** Sends or holds queued messages. Never throws; reports what went wrong. */
  dispatch(snapshot: Snapshot): Promise<{ readonly failure: TeamsFailureKind | undefined }>;
}

export interface PollDeps {
  readonly fetchSnapshot: () => Promise<Snapshot>;
  readonly store: Store;
  readonly notifier: Notifier;
  readonly failures: FailureTracker;
  readonly log: Logger;
  readonly config: Pick<Config, "gitlab" | "notifications">;
  readonly teams?: TeamsHooks;
}

export type PollStatus = "ok" | "paused" | "failed";

const GITLAB_FAILURE_KINDS: readonly GitlabFailureKind[] = [
  "glab-missing",
  "gitlab-auth",
  "gitlab-unreachable",
  "gitlab-error",
];
const TEAMS_FAILURE_KINDS: readonly TeamsFailureReportKind[] = ["teams-unavailable", "teams-error"];

/** Tells the Owner exactly once per failure streak, when the streak reaches the kind's threshold. */
async function reportFailure(
  deps: PollDeps,
  kind: FailureKind,
  notification: Notification | undefined,
  attributes: Readonly<Record<string, string | number>>,
): Promise<void> {
  const streak = deps.failures.fail(kind);
  if (streak !== NOTIFY_AFTER[kind]) {
    deps.log.debug("poll failure not reported", { kind, streak });
    return;
  }
  deps.log.error("poll failed", { kind, ...attributes });
  if (notification === undefined) return;
  try {
    await deps.notifier.notify(notification);
  } catch {
    // The notifier itself is broken; the error log above is the only channel left.
    deps.log.error("failure notification not delivered", { kind });
  }
}

async function reportFetchFailure(deps: PollDeps, error: unknown): Promise<void> {
  const kind: GitlabFailureKind = error instanceof FetchFailure ? error.kind : "gitlab-error";
  const reason = error instanceof FetchFailure ? error.message : "unexpected error";
  await reportFailure(deps, kind, failureNotification(kind, deps.config.gitlab.hostname), {
    reason,
  });
}

async function reportStateFailure(deps: PollDeps, error: unknown): Promise<void> {
  // The database error text can name files; log only the error class.
  await reportFailure(deps, "state", STATE_FAILURE_NOTIFICATION, {
    reason: error instanceof Error ? error.name : "unknown",
  });
}

/** Runs after the state commit; a Teams problem never changes the poll status. */
async function runTeams(deps: PollDeps, snapshot: Snapshot, previous: PreviousState): Promise<void> {
  const { teams } = deps;
  if (teams === undefined) return;
  try {
    teams.plan(snapshot, previous);
  } catch (error) {
    await reportStateFailure(deps, error);
    return;
  }
  const { failure } = await teams.dispatch(snapshot);
  if (failure === undefined) {
    for (const kind of TEAMS_FAILURE_KINDS) deps.failures.recover(kind);
    return;
  }
  const kind: TeamsFailureReportKind = failure === "unavailable" ? "teams-unavailable" : "teams-error";
  await reportFailure(deps, kind, teamsFailureNotification(kind), {});
}

/**
 * One poll cycle. Order matters: events are delivered first and state is committed next, so a
 * failed delivery is retried on the next poll instead of being marked as seen. The exception is a
 * partial delivery: once at least one notification went out, the state is committed anyway so the
 * delivered ones are never sent again on every following poll. Teams runs last, after the commit.
 */
export async function pollOnce(deps: PollDeps): Promise<PollStatus> {
  const { store, notifier, failures, log, config } = deps;
  if (store.isPaused()) {
    log.debug("polling paused");
    return "paused";
  }

  let snapshot: Snapshot;
  try {
    snapshot = await deps.fetchSnapshot();
  } catch (error) {
    await reportFetchFailure(deps, error);
    return "failed";
  }
  for (const kind of GITLAB_FAILURE_KINDS) failures.recover(kind);

  let previous: PreviousState;
  try {
    previous = store.load();
  } catch (error) {
    await reportStateFailure(deps, error);
    return "failed";
  }
  const notifications = previous.baselineDone
    ? buildNotifications(
        detectEvents(snapshot, previous, {
          ignoreAuthors: new Set(config.notifications.ignoreAuthors),
        }),
        config.notifications.summaryThreshold,
      )
    : baselineNotifications(countPendingReviews(snapshot));

  let delivered = 0;
  try {
    for (const notification of notifications) {
      await notifier.notify(notification);
      delivered += 1;
    }
  } catch (error) {
    if (failures.fail("notifier") === NOTIFY_AFTER.notifier) {
      // Never log the error message: process errors embed the notification text.
      log.error("notification delivery failed", {
        code: String(execFailure(error).code ?? "unknown"),
        delivered,
        total: notifications.length,
      });
    }
    if (delivered === 0) return "failed";
  }
  const complete = delivered === notifications.length;
  if (complete) failures.recover("notifier");

  try {
    store.commit(snapshot);
  } catch (error) {
    await reportStateFailure(deps, error);
    return "failed";
  }
  failures.recover("state");
  await runTeams(deps, snapshot, previous);
  log.debug("poll complete", {
    review_requested: snapshot.reviewRequested.length,
    authored: snapshot.authored.length,
    notifications: notifications.length,
    baseline: !previous.baselineDone,
  });
  return complete ? "ok" : "failed";
}
```

- [ ] **Step 5: Create `src/teams/service.ts`**

```ts
import type { Config } from "../config.ts";
import type { Snapshot } from "../domain.ts";
import type { PreviousState } from "../events.ts";
import type { Logger } from "../log.ts";
import type { TeamsHooks } from "../poller.ts";
import type { Store } from "../store.ts";
import type { TeamsFailureKind } from "./api.ts";
import { dispatchQueued, retryOutbox, sendPending, skipOutbox } from "./dispatch.ts";
import type { DispatchDeps, SendPendingOutcome } from "./dispatch.ts";
import type { TeamsGateway } from "./gateway.ts";
import { planTeams } from "./plan.ts";
import type { Templates } from "./templates.ts";
import { ATTENTION_STATUSES, OUTBOX_STATUSES } from "./types.ts";
import type { OutboxRow } from "./types.ts";

export interface TeamsService extends TeamsHooks {
  sendPending(id: number): Promise<SendPendingOutcome>;
  /** Rows that need attention, or every row when `all` is true. */
  list(all: boolean): OutboxRow[];
  skip(id: number): boolean;
  retry(id: number): boolean;
  /** Sends a fixed test line to the Owner's own notes chat; proves the MCP path end to end. */
  selfTest(): Promise<void>;
}

export interface ServiceDeps {
  readonly store: Store;
  readonly gateway: TeamsGateway;
  readonly templates: Templates;
  readonly config: Config["teams"];
  readonly log: Logger;
  readonly now: () => number;
}

const HOUR_MS = 3_600_000;
const MINUTE_MS = 60_000;
const SELF_CHAT_ID = "48:notes";
const SELF_TEST_TEXT = "MR Review Assistant: tes koneksi Teams berhasil.";

export function createTeamsService(deps: ServiceDeps): TeamsService {
  const dispatchDeps: DispatchDeps = {
    store: deps.store,
    gateway: deps.gateway,
    templates: deps.templates,
    config: deps.config,
    log: deps.log,
    now: deps.now,
  };
  return {
    plan(snapshot: Snapshot, previous: PreviousState): void {
      const now = deps.now();
      const plan = planTeams({
        snapshot,
        previous,
        state: deps.store.loadTeams(),
        now,
        config: {
          maxMessagesPerReviewer: deps.config.maxMessagesPerReviewer,
          reminderAfterMs: deps.config.reminderAfterHours * HOUR_MS,
          noticeDebounceMs: deps.config.noticeDebounceMinutes * MINUTE_MS,
        },
      });
      const created = deps.store.applyTeamsPlan(plan, now);
      if (created > 0) deps.log.info("teams messages queued", { count: created });
    },

    async dispatch(snapshot: Snapshot): Promise<{ failure: TeamsFailureKind | undefined }> {
      try {
        const result = await dispatchQueued(dispatchDeps, snapshot);
        if (result.sent > 0) deps.log.info("teams messages sent", { count: result.sent });
        return { failure: result.failure };
      } catch (error) {
        deps.log.error("teams dispatch crashed", {
          reason: error instanceof Error ? error.name : "unknown",
        });
        return { failure: "error" };
      }
    },

    sendPending: (id) => sendPending(dispatchDeps, id),
    list: (all) => deps.store.listOutbox(all ? OUTBOX_STATUSES : ATTENTION_STATUSES),
    skip: (id) => skipOutbox(deps.store, id, deps.now()),
    retry: (id) => retryOutbox(deps.store, id, deps.now()),
    selfTest: () =>
      deps.gateway.session(async (api) => {
        await api.sendMessage(SELF_CHAT_ID, SELF_TEST_TEXT);
      }),
  };
}
```

- [ ] **Step 6: Replace `src/runtime.ts`**

```ts
import { homedir } from "node:os";
import { join } from "node:path";
import { defaultStatePath, loadConfig } from "./config.ts";
import type { Config } from "./config.ts";
import { createFailureTracker } from "./failures.ts";
import { fetchSnapshot, glabRunner } from "./gitlab.ts";
import { createLogger } from "./log.ts";
import type { Logger } from "./log.ts";
import { createNotifier } from "./notifier.ts";
import { pollOnce } from "./poller.ts";
import type { PollDeps, PollStatus } from "./poller.ts";
import { openStore } from "./store.ts";
import type { Store } from "./store.ts";
import { createTeamsGateway } from "./teams/gateway.ts";
import { createTeamsService } from "./teams/service.ts";
import type { TeamsService } from "./teams/service.ts";
import { defaultTemplatesPath, loadTemplates } from "./teams/templates.ts";

export interface Runtime {
  readonly config: Config;
  readonly store: Store;
  readonly log: Logger;
  /** Undefined when `teams.enabled` is false. */
  readonly teams: TeamsService | undefined;
  poll(): Promise<PollStatus>;
}

const MS_PER_SECOND = 1000;

function defaultTeamsCommand(): string {
  return join(homedir(), ".config", "teams-mcp", "run.sh");
}

export function createRuntime(configPath: string): Runtime {
  const log = createLogger();
  const config = loadConfig(configPath);
  const store = openStore(config.statePath ?? defaultStatePath());
  const run = glabRunner(config.gitlab);

  // A bad template stops startup (TemplateError) instead of producing broken messages later.
  const teams = config.teams.enabled
    ? createTeamsService({
        store,
        gateway: createTeamsGateway({
          command: config.teams.command ?? defaultTeamsCommand(),
          startTimeoutMs: config.teams.startTimeoutSeconds * MS_PER_SECOND,
          callTimeoutMs: config.teams.callTimeoutSeconds * MS_PER_SECOND,
        }),
        templates: loadTemplates(config.teams.templatesPath ?? defaultTemplatesPath()),
        config: config.teams,
        log,
        now: Date.now,
      })
    : undefined;

  const deps: PollDeps = {
    fetchSnapshot: () => fetchSnapshot(run),
    store,
    notifier: createNotifier(),
    failures: createFailureTracker(),
    log,
    config,
    ...(teams === undefined ? {} : { teams }),
  };
  return { config, store, log, teams, poll: () => pollOnce(deps) };
}
```

- [ ] **Step 7: Run the checks**

Run: `npx prettier --write . && npm run check`
Expected: all pass, including every Plan 1 poller test (the poller's behaviour without `teams` is unchanged), the 6 service tests and the 5 poller-teams tests. In `test/service.test.ts` the "unexpected crash" test builds a store with a throwing `listOutbox`; if TypeScript rejects the inline `throw` in an arrow body, write it as `listOutbox: () => { throw new Error("disk"); }` on separate lines (prettier will format it).

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: run Teams planning and dispatch after the state commit"
```

---

### Task 11: CLI commands

**Files:**
- Create: `src/teams/format-outbox.ts`
- Modify (replace whole file): `src/cli.ts`
- Test: `test/format-outbox.test.ts`

**Interfaces:**
- Consumes: `OutboxRow`, `TeamsService`, `Runtime`.
- Produces: `formatOutbox(rows: readonly OutboxRow[]): string`; CLI commands `pending [--all]`, `send <id>`, `skip <id>`, `retry <id>`, `selftest`, and a `status` that also shows outbox counts.

- [ ] **Step 1: Write the failing test**

`test/format-outbox.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { formatOutbox } from "../src/teams/format-outbox.ts";
import type { OutboxRow } from "../src/teams/types.ts";

const row = (overrides: Partial<OutboxRow> = {}): OutboxRow => ({
  id: 12,
  dedupeKey: "k",
  kind: "nudge",
  variant: "nudge",
  mrKey: "g/p!5",
  mrIid: 5,
  mrProject: "g/p",
  mrTitle: "Add thing",
  mrUrl: "https://gitlab.example/g/p/-/merge_requests/5",
  recipient: "bob",
  recipientName: "Bob",
  status: "pending",
  detail: "",
  text: "Halo Bob,\nboleh minta tolong review?",
  createdAt: 1,
  updatedAt: 1,
  ...overrides,
});

describe("formatOutbox", () => {
  it("says so when there is nothing to show", () => {
    expect(formatOutbox([])).toBe("no messages\n");
  });

  it("shows a pending message with its full text, indented", () => {
    expect(formatOutbox([row()])).toBe(
      [
        "#12 [pending] nudge → Bob · g/p!5",
        "    Halo Bob,",
        "    boleh minta tolong review?",
        "",
      ].join("\n"),
    );
  });

  it("explains unresolved, failed and sending rows", () => {
    const text = formatOutbox([
      row({ id: 1, status: "unresolved", detail: "no-match", text: null }),
      row({ id: 2, status: "failed", detail: "error", text: null }),
      row({ id: 3, status: "sending", text: null }),
    ]);
    expect(text).toContain("#1 [unresolved] nudge → Bob · g/p!5 (no-match: add the person to teams.people, then `mra retry 1`)");
    expect(text).toContain("#2 [failed] nudge → Bob · g/p!5 (error: not retried automatically)");
    expect(text).toContain("#3 [sending] nudge → Bob · g/p!5 (may have been sent: check Teams)");
  });

  it("shows only the first line of text for rows that are not waiting for a decision", () => {
    const text = formatOutbox([row({ status: "sent" })]);
    expect(text).toBe("#12 [sent] nudge → Bob · g/p!5\n");
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npx vitest run test/format-outbox.test.ts`
Expected: FAIL — cannot resolve `../src/teams/format-outbox.ts`.

- [ ] **Step 3: Implement `src/teams/format-outbox.ts`**

```ts
import type { OutboxRow } from "./types.ts";

function hint(row: OutboxRow): string {
  switch (row.status) {
    case "unresolved":
      return ` (${row.detail}: add the person to teams.people, then \`mra retry ${row.id}\`)`;
    case "failed":
      return ` (${row.detail}: not retried automatically)`;
    case "sending":
      return " (may have been sent: check Teams)";
    default:
      return row.detail === "" ? "" : ` (${row.detail})`;
  }
}

/** Terminal listing for the Owner. It prints names and titles, so it is never logged. */
export function formatOutbox(rows: readonly OutboxRow[]): string {
  if (rows.length === 0) return "no messages\n";
  const lines: string[] = [];
  for (const row of rows) {
    lines.push(`#${row.id} [${row.status}] ${row.kind} → ${row.recipientName} · ${row.mrKey}${hint(row)}`);
    if (row.status === "pending" && row.text !== null) {
      for (const line of row.text.split("\n")) lines.push(`    ${line}`);
    }
  }
  return `${lines.join("\n")}\n`;
}
```

- [ ] **Step 4: Replace `src/cli.ts`**

```ts
import { defaultConfigPath } from "./config.ts";
import { createRuntime } from "./runtime.ts";
import type { Runtime } from "./runtime.ts";
import { formatOutbox } from "./teams/format-outbox.ts";
import { OUTBOX_STATUSES } from "./teams/types.ts";

const USAGE =
  "usage: mra <once|status|pause|resume|pending [--all]|send <id>|skip <id>|retry <id>|selftest>\n";
const TEAMS_DISABLED = "teams is disabled: set teams.enabled to true in the config\n";
const SHOWN_WITH_ALL = 50;

const SIMPLE = new Set(["once", "status", "pause", "resume", "selftest", "pending"]);
const WITH_ID = new Set(["send", "skip", "retry"]);

function parseId(value: string | undefined): number | undefined {
  return value !== undefined && /^\d+$/.test(value) ? Number(value) : undefined;
}

async function run(runtime: Runtime, command: string, argv: readonly string[]): Promise<number> {
  const { teams } = runtime;
  switch (command) {
    case "once": {
      const status = await runtime.poll();
      process.stdout.write(`poll: ${status}\n`);
      return status === "failed" ? 1 : 0;
    }
    case "status": {
      const state = runtime.store.load();
      const lines = [
        `paused: ${runtime.store.isPaused() ? "yes" : "no"}`,
        `baseline: ${state.baselineDone ? "done" : "pending"}`,
        `tracked authored MRs: ${state.trackedAuthored.size}`,
        `review-requested MRs known: ${state.myReviewStates.size}`,
      ];
      if (teams !== undefined) {
        const rows = teams.list(true);
        const counts = OUTBOX_STATUSES.map(
          (status) => `${status} ${rows.filter((row) => row.status === status).length}`,
        );
        lines.push(`teams outbox: ${counts.join(", ")}`);
      }
      process.stdout.write(`${lines.join("\n")}\n`);
      return 0;
    }
    case "pause":
      runtime.store.setPaused(true);
      process.stdout.write("paused\n");
      return 0;
    case "resume":
      runtime.store.setPaused(false);
      process.stdout.write("resumed\n");
      return 0;
  }

  if (teams === undefined) {
    process.stderr.write(TEAMS_DISABLED);
    return 1;
  }
  switch (command) {
    case "pending": {
      const all = argv.includes("--all");
      const rows = teams.list(all);
      process.stdout.write(formatOutbox(all ? rows.slice(-SHOWN_WITH_ALL) : rows));
      return 0;
    }
    case "selftest":
      await teams.selfTest();
      process.stdout.write("sent a test line to your own Teams notes chat\n");
      return 0;
    default: {
      const id = parseId(argv[1]);
      if (id === undefined) {
        process.stderr.write(USAGE);
        return 2;
      }
      if (command === "send") {
        const outcome = await teams.sendPending(id);
        process.stdout.write(`send #${id}: ${outcome.status}\n`);
        return outcome.status === "sent" ? 0 : 1;
      }
      const done = command === "skip" ? teams.skip(id) : teams.retry(id);
      process.stdout.write(`${command} #${id}: ${done ? "done" : "nothing to do"}\n`);
      return done ? 0 : 1;
    }
  }
}

async function main(argv: readonly string[]): Promise<number> {
  const command = argv[0];
  if (command === undefined || (!SIMPLE.has(command) && !WITH_ID.has(command))) {
    process.stderr.write(USAGE);
    return 2;
  }
  const runtime = createRuntime(defaultConfigPath());
  try {
    return await run(runtime, command, argv);
  } finally {
    runtime.store.close();
  }
}

main(process.argv.slice(2)).then(
  (code) => {
    process.exitCode = code;
  },
  (error: unknown) => {
    process.stderr.write(`mra: ${error instanceof Error ? error.message : "unknown error"}\n`);
    process.exitCode = 1;
  },
);
```

- [ ] **Step 5: Run the checks**

Run: `npx prettier --write . && npm run check`
Expected: all pass. `cli.ts` has no unit test (it only wires tested parts); Task 12's smoke test exercises it.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: add the pending, send, skip, retry and selftest commands"
```

---

### Task 12: Documentation and the manual smoke test

**Files:**
- Modify: `README.md`, `docs/superpowers/specs/2026-10-14-mr-review-assistant-design.md` (one line)

**Interfaces:**
- Consumes: the whole program.

- [ ] **Step 1: Update `README.md`**

Make these changes:

1. In the intro, replace "This is Plan 1 of three; Teams chats and agent reviews come in later plans." with "Plan 1 (alerts) and Plan 2 (Teams chats) are implemented; agent reviews come in Plan 3." and replace "It only reads from GitLab. It never posts, approves or changes anything there." with "It only reads from GitLab. It never posts, approves or changes anything there. With Teams enabled it also chats colleagues as you, from fixed templates."
2. Add to the configuration table the keys of the `teams` section with their defaults (copy them from the `teams` schema in `src/config.ts`): `teams.enabled` (false), `teams.command` (`~/.config/teams-mcp/run.sh`), `teams.startTimeoutSeconds` (30), `teams.callTimeoutSeconds` (60), `teams.modes.nudge` and `teams.modes.notice` (`approval`; `auto` / `approval` / `dry-run`), `teams.workingHours.start|end|days` (`09:00`, `17:00`, Monday–Friday as 1–5), `teams.reminderAfterHours` (24), `teams.noticeDebounceMinutes` (10), `teams.maxMessagesPerReviewer` (2), `teams.templatesPath` (`~/.config/mr-review-assistant/templates`), `teams.people` (GitLab username → email).
3. Add a "Teams" section:
   - what each flow sends and when (Reviewer Nudge on a new or re-requested Reviewer, one reminder after 24 hours, Review Notice to the Author 10 minutes after you finish reviewing);
   - the send modes and their default; messages only go out in working hours (Mac local time) and wait otherwise;
   - the commands `mra pending [--all]`, `mra send <id>`, `mra skip <id>`, `mra retry <id>`, `mra selftest`, and what each status in `mra pending` means (`pending` waits for you, `unresolved` needs a `teams.people` line then `mra retry`, `failed` is final, `sending` may have been delivered);
   - template files: names `nudge.txt`, `reminder.txt`, `notice.approved.txt`, `notice.changes.txt`, `notice.comments.txt` in the templates folder, the six placeholders (`{{mr.title}}`, `{{mr.url}}`, `{{mr.iid}}`, `{{mr.project}}`, `{{person.name}}`, `{{owner.name}}`), and that an unknown placeholder stops startup;
   - how people are found: `teams.people`, then a cache, then an exact display-name match in Teams; anything uncertain is left for you.
4. Under "Known limits" add: a message is sent at most once, so a failed or interrupted send is never repeated automatically; an MR is announced to the Author only once per round of your review; Teams planning starts from the moment Teams is enabled (older history is never announced); the Agent Review flow is not implemented yet.

In `docs/superpowers/specs/2026-10-14-mr-review-assistant-design.md`, in the "Delivery in three plans" list, change item 2 to start with `**Plan 2 — Teams (flows B and C), implemented.**`.

- [ ] **Step 2: Run the checks**

Run: `npx prettier --write . && npm run check`
Expected: all pass.

- [ ] **Step 3: Smoke test, part 1 — connection and dry run (safe: nothing is sent to anyone but yourself)**

Add to `~/.config/mr-review-assistant/config.yaml`:

```yaml
teams:
  enabled: true
  modes:
    nudge: dry-run
    notice: dry-run
```

Then:

```bash
scripts/mra selftest
```

Expected: `sent a test line to your own Teams notes chat`, and the line "MR Review Assistant: tes koneksi Teams berhasil." appears in your own Teams notes chat. If it fails with a timeout, the Teams MCP is not connecting: stop and tell the Owner.

```bash
scripts/mra once
scripts/mra once
scripts/mra pending --all
```

Expected: `poll: ok` twice and `no messages` (the first poll only seeds the Teams baseline; nothing is announced for history).

- [ ] **Step 4: Smoke test, part 2 — see a rendered message without sending it**

Simulate "a Reviewer was added" on one of your own MRs by forgetting one Reviewer who is still `UNREVIEWED`:

```bash
sqlite3 ~/Library/Application\ Support/mr-review-assistant/state.db \
  "DELETE FROM reviewer_state WHERE rowid = (SELECT rowid FROM reviewer_state WHERE state = 'UNREVIEWED' LIMIT 1); SELECT changes();"
scripts/mra once
scripts/mra pending --all
```

Expected: `1` from the SQL (if it prints `0`, none of your MRs has an `UNREVIEWED` Reviewer — skip to the end of this step), then one `[dry-run] nudge → <name> · <project>!<iid>` line. Working hours apply: outside Monday–Friday 09:00–17:00 the row stays `[queued]` and becomes `dry-run` on the first poll inside the hours. Read the rendered text with `sqlite3 ... "SELECT text FROM outbox ORDER BY id DESC LIMIT 1"`: it must be the Indonesian nudge with the MR title and link and no stray `{{...}}`.

- [ ] **Step 5: Smoke test, part 3 — real messages (ONLY with the Owner's explicit confirmation in chat)**

Do not run this step on your own. A real nudge goes to a real colleague. If, and only if, the Owner says yes:

```bash
scripts/mra pause
```

change `teams.modes.nudge` to `approval`, run `scripts/mra resume`, repeat the SQL from Step 4 for another Reviewer, run `scripts/mra once`, show the Owner the `[pending]` message from `scripts/mra pending`, and only after the Owner approves that exact text run `scripts/mra send <id>`. Expected: `send #<id>: sent`, and the message is visible in the Owner's Teams. A second `scripts/mra send <id>` must print `not-pending`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "docs: document Teams chats and the approval workflow"
```

---

## What the next plan needs from this one

- **Plan 3 (Agent Review)** adds a template variant `notice.agent` to `TEMPLATE_NAMES` and `DEFAULT_TEMPLATES`, a trigger that writes an intent with `kind: "notice"` and `variant: "notice.agent"` through `store.applyTeamsPlan` (so it inherits the outbox, modes, working hours and at-most-once rule), and reuses `Store.isPaused` as the kill switch. Its `review-requested` trigger is the existing Plan 1 event.
- `SCHEMA_VERSION` is now 2; Plan 3's tables go in a `SCHEMA_V3` with the same `if (version < 3)` pattern in `initSchema`.
- Real sends to colleagues still need the Owner's explicit confirmation in chat; Plan 3's first real post to GitLab does too.

## Self-review

- **Spec coverage:** flow B (nudge on added / re-requested Reviewer, one reminder after 1 working day — implemented as 24 hours that only fire inside working hours —, max 2 per MR per Reviewer, working hours only, never to a Reviewer who already reviewed): Tasks 4, 9. Flow C (debounced notice with approved / changes / comments variants): Tasks 3, 4, 5. Agent-review variant: deferred to Plan 3 (declared above). Send modes `auto` / `approval` / `dry-run` per flow with `approval` default: Tasks 1, 9. Approval CLI `mra pending|send|skip`: Tasks 10, 11 (plus `retry` and `selftest`). Templates as files in the config folder, Indonesian default, unknown placeholder stops startup: Tasks 5, 10. Identity by display name via `search_users`, exactly one match, else tell the Owner to add a mapping: Task 8 (the mapping lives in `teams.people` in the config file rather than a separate mapping file). State written before sending, at most once: Tasks 2, 9. Teams sends never retried: Task 9. Teams via the existing MCP: Tasks 6, 7.
- **Deliberate differences from the spec text:** (1) no official MCP SDK, an in-house client instead (17 transitive packages avoided); (2) the people mapping is the `teams.people` config key; (3) "1 working day" is 24 elapsed hours combined with the working-hours gate, not a working-day calendar.
- **Placeholder scan:** the only intentionally incomplete snippet is the drafting stub in Task 9's test list, which the plan itself replaces in the same step; no other TBD/TODO text.
- **Type consistency:** `TeamsFailureKind` (`"unavailable" | "error"`) is produced in `api.ts`/`gateway.ts`, consumed in `dispatch.ts`, `service.ts` and `poller.ts`; `OutboxRow`/`OutboxStatus` come from `types.ts` and are used by the store, dispatcher, service and CLI; `Store` additions are listed once in Task 2 and consumed by name in Tasks 8–11; `TeamsHooks` is declared in `poller.ts` and implemented by `TeamsService`.
