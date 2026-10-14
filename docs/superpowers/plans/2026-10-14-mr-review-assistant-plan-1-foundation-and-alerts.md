# MR Review Assistant — Plan 1: Foundation, Review Requests and Activity Alerts

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A launchd-run agent on the Owner's Mac that polls GitLab and shows a macOS notification when someone requests the Owner's review (flow A) and when someone reviews or comments on the Owner's own MRs (flow D). Read-only toward GitLab. No Teams, no language model.

**Architecture:** One poll cycle fetches a `Snapshot` (review-requested MRs + authored MRs with their recent notes) with a single `glab api graphql` call, compares it with the state stored in SQLite to produce `ActivityEvent`s, turns events into notifications, delivers them, and only then commits the new state. The comparison (`events.ts`), the wording (`format.ts`) and the scheduling arithmetic (`scheduler.ts`) are pure functions; process spawning, SQLite and the clock sit behind small interfaces so every layer is testable without GitLab or a desktop.

**Tech Stack:** Node 24 with native TypeScript type stripping (no build step), `node:sqlite`, `yaml` and `zod`, vitest, eslint + prettier, `glab` (already logged in), `osascript` or `terminal-notifier`, launchd.

**Spec:** `docs/superpowers/specs/2026-10-14-mr-review-assistant-design.md` (vocabulary: `CONTEXT.md`). Plan 2 (Teams) and Plan 3 (Agent Review) are written after this plan is implemented; see "What the next plans need from this one" at the end.

## Global Constraints

- Node `>=24`; scripts run with `node src/<file>.ts`. Because Node strips types without compiling: relative imports end in `.ts`, and only erasable TypeScript syntax is allowed (no `enum`, no class parameter properties, no `namespace`). `tsconfig` sets `erasableSyntaxOnly`.
- Madhani TypeScript standard: `tsconfig.base.json` copied verbatim from the plugin reference (`strict`, `noUncheckedIndexedAccess`, `exactOptionalPropertyTypes`, `verbatimModuleSyntax`); typescript-eslint `recommendedTypeChecked` + prettier; named exports only (default exports only in `*.config.*`); no `as any`, `as unknown as`, `!`, `@ts-ignore`; external input parsed with zod; no `console.log`; `import type` for type-only imports.
- Dependencies are pinned to exact versions looked up on 2026-10-14: `yaml 2.9.1`, `zod 3.25.76`, `vitest 3.2.7`, `typescript 5.9.3`, `@types/node 24.19.2`, `eslint 9.39.5`, `@eslint/js 9.39.5`, `typescript-eslint 8.71.2`, `eslint-config-prettier 10.1.8`, `prettier 3.9.10`. None appears in `npm-banned-versions.tsv` (checked 2026-10-14). Install with `npm install --ignore-scripts` the first time, scan the lockfile with the banned-version scanner, then use `npm ci` from then on.
- GitLab is read-only in this plan: the only call is `glab api graphql` with a `query`, never a mutation and never a REST write.
- Every external process call has a timeout (`Exec` takes `timeoutMs`; `glab` 60 s default, notifier 10 s, `ioreg` 5 s).
- Logs: JSON lines on stdout with `timestamp` (ISO 8601 UTC), `level`, `message`, `service_name`, `environment`; extra context only inside `attributes`, `snake_case`; `message` is English, constant and has no interpolated data; no employee IDs (GitLab usernames), no display names, no MR titles, no comment text, no process arguments. An MR may be referred to by its key (`<project path>!<iid>`) only.
- Language: code, comments, commit messages, MR text, logs and docs are English. Strings shown to the Owner (notification titles and bodies) are Indonesian.
- Git: default branch `trunk`; no direct commits to `trunk`; branch `feat/no-ticket-<description>` (no planner task exists for this work; `no-ticket` is the allowed key); MR title `[no-ticket] feat: <description>`; never `--no-verify`.
- Polling defaults: 120 s active, 300 s idle, idle after 300 s without input, failure backoff capped at 900 s; summary notification when more than 4 notifications are produced in one poll. All configurable.
- The first poll after a fresh state database is a silent baseline plus one summary notification; it never alerts about history.

## Review Focus

Input classes the spec implies but a straightforward implementation would miss; each has a named test.

1. **Hostile or odd MR text in notifications** — a title or display name with newlines, control characters, a leading `-` (would be read as a flag by `terminal-notifier`), quotes, emoji or 10 000 characters must produce a short, single-line, flag-safe notification and must never reach AppleScript source. Tests: `clean` cases in `test/format.test.ts`, argv-passing case in `test/notifier.test.ts`.
2. **Incomplete GitLab payloads** — `author: null` (deleted user), `reviewState: null`, `mergeRequestInteraction: null`, a non-`http(s)` `webUrl` (e.g. `javascript:`), GraphQL `errors`, `currentUser: null`. Expected: placeholder person / `UNREVIEWED` / a typed `FetchFailure`, never a crash and never a URL handed to `-open`. Tests: `test/gitlab.test.ts`.
3. **More than 100 open MRs** — pagination is not implemented; the poll must fail loudly (`gitlab-error` notification) instead of silently watching only the first page. Test: `test/gitlab.test.ts`.
4. **Mac wakes after hours with many changes at once** — one summary notification, not a burst; and a delivery failure must not mark events as seen. Tests: `test/poller.test.ts` ("wake catch-up", "notifier failure keeps state uncommitted").
5. **Draft to ready, and newly tracked MRs** — a draft MR that becomes ready is a new Review Request; comments that already exist on an MR when it first becomes tracked are recorded silently, not alerted. Tests: `test/events.test.ts`.

## File Structure

Repository: `mr-review-assistant` (GitLab `20433/mr-review-assistant`, local `~/repo.madhani.one/mr-review-assistant`).

| File | Responsibility |
|---|---|
| `src/util.ts` | `errorMessage` helper |
| `src/log.ts` | JSON logger (Madhani fields, level filter) |
| `src/domain.ts` | Types: `Person`, `Reviewer`, `Note`, `MergeRequest`, `Snapshot`, `ReviewState`, `UNREVIEWED` |
| `src/config.ts` | YAML config schema, loader, default paths |
| `src/exec.ts` | `Exec` abstraction over `execFile`, `execFailure` narrowing |
| `src/gitlab.ts` | GraphQL query, response parsing to `Snapshot`, `glab` runner, failure classification |
| `src/events.ts` | Pure diff `Snapshot` + `PreviousState` → `ActivityEvent[]` |
| `src/format.ts` | Pure: events → Indonesian `Notification`s, text cleaning, summary |
| `src/notifier.ts` | macOS delivery (`terminal-notifier`, fallback `osascript`) |
| `src/store.ts` | SQLite persistence of everything `events.ts` needs |
| `src/failures.ts` | Once-per-failure-kind tracker and failure notification texts |
| `src/poller.ts` | One poll cycle, wiring the above |
| `src/idle.ts` | Idle detection via `ioreg` |
| `src/scheduler.ts` | Pure delay arithmetic (active/idle/backoff) |
| `src/daemon.ts` | Endless loop with abortable sleep |
| `src/runtime.ts` | Builds real dependencies |
| `src/main.ts` | Daemon entry point (launchd) |
| `src/cli.ts` | `mra once|status|pause|resume` |
| `scripts/mra`, `scripts/install-launchagent.sh`, `scripts/uninstall-launchagent.sh`, `launchd/com.madhani.mr-review-assistant.plist.template` | Packaging |
| `test/*.test.ts`, `test/builders.ts` | Tests and shared builders |

---

### Task 1: Repository, tooling and logger

**Files:**
- Create: `package.json`, `tsconfig.json`, `tsconfig.base.json` (copied), `eslint.config.js` (copied + one edit), `.prettierrc.json`, `.prettierignore`, `.gitignore`, `.nvmrc`, `vitest.config.ts`
- Create: `src/util.ts`, `src/log.ts`
- Test: `test/log.test.ts`

**Interfaces:**
- Produces: `errorMessage(error: unknown): string`; `createLogger(overrides?: Partial<LoggerOptions>): Logger` where `Logger` has `debug|info|warn|error(message: string, attributes?: LogAttributes): void`; `LogAttributes = Readonly<Record<string, string | number | boolean | null>>`.

- [ ] **Step 1: Create the repository (needs the Owner's explicit confirmation first)**

Ask the Owner to confirm creating a private project `20433/mr-review-assistant` on `repo.madhani.one`, initialised with a README so `trunk` exists and is the default branch. Prefer the GitLab UI; if using the CLI, read `glab repo create --help` first and use only flags it lists. Then:

```bash
git clone ssh://git@repo.madhani.one:2222/20433/mr-review-assistant.git ~/repo.madhani.one/mr-review-assistant
cd ~/repo.madhani.one/mr-review-assistant
git switch -c feat/no-ticket-polling-foundation
```

Copy `CONTEXT.md` and the `docs/superpowers/` folder (spec and this plan) from the folder this plan came from into the repository root.

- [ ] **Step 2: Write the tooling files**

`package.json`:

```json
{
  "name": "mr-review-assistant",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "engines": { "node": ">=24" },
  "scripts": {
    "start": "node src/main.ts",
    "typecheck": "tsc --noEmit",
    "lint": "eslint .",
    "format": "prettier --check .",
    "test": "vitest run",
    "check": "npm run typecheck && npm run lint && npm run format && npm test"
  },
  "dependencies": {
    "yaml": "2.9.1",
    "zod": "3.25.76"
  },
  "devDependencies": {
    "@eslint/js": "9.39.5",
    "@types/node": "24.19.2",
    "eslint": "9.39.5",
    "eslint-config-prettier": "10.1.8",
    "prettier": "3.9.10",
    "typescript": "5.9.3",
    "typescript-eslint": "8.71.2",
    "vitest": "3.2.7"
  }
}
```

`tsconfig.json`:

```json
{
  "extends": "./tsconfig.base.json",
  "compilerOptions": {
    "module": "nodenext",
    "moduleResolution": "nodenext",
    "lib": ["ES2023"],
    "types": ["node"],
    "noEmit": true,
    "allowImportingTsExtensions": true,
    "erasableSyntaxOnly": true
  },
  "include": ["src", "test", "vitest.config.ts"]
}
```

`vitest.config.ts`:

```ts
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: { include: ["test/**/*.test.ts"] },
});
```

`.prettierrc.json`: `{ "printWidth": 100, "trailingComma": "all" }`

`.prettierignore`:

```
package-lock.json
*.md
*.plist.template
coverage
```

`.gitignore`:

```
node_modules/
coverage/
*.log
```

`.nvmrc`: `24`

Copy the Madhani baselines, then make the one edit:

```bash
REF=$(ls -d ~/.claude/plugins/cache/madhani/madhani/*/skills/madhani-ts-coding-standard/references | tail -1)
cp "$REF/tsconfig.base.json" "$REF/eslint.config.js" .
```

In `eslint.config.js` change `{ ignores: ["dist/**",` to `{ ignores: ["eslint.config.js", "dist/**",` (the config file itself is not part of the TypeScript project).

- [ ] **Step 3: Check the banned list, install, scan**

```bash
SC=$(ls -d ~/.claude/plugins/cache/madhani/madhani/*/skills/madhani-secure-coding | tail -1)
grep -E "^(yaml|zod|vitest|typescript|@types/node|eslint|@eslint/js|typescript-eslint|eslint-config-prettier|prettier)[[:space:]]" "$SC/references/npm-banned-versions.tsv"
npm install --ignore-scripts
python3 "$SC/scripts/scan-banned-npm-versions.py" .
```

Expected: the `grep` prints nothing; the scanner's last line is `RESULT: CLEAN` (exit code 0). If the scanner reports any `HIT`, stop and follow the "a banned or compromised version is found" workflow in `madhani-secure-coding`. If vitest later fails with an esbuild binary error, run `npm rebuild esbuild` once (the install ran with `--ignore-scripts`). Read the `package-lock.json` diff before committing.

- [ ] **Step 4: Write the failing logger test**

`test/log.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { createLogger } from "../src/log.ts";

function capture(overrides: Parameters<typeof createLogger>[0] = {}): {
  lines: string[];
  log: ReturnType<typeof createLogger>;
} {
  const lines: string[] = [];
  const log = createLogger({
    serviceName: "mra",
    environment: "test",
    minLevel: "debug",
    write: (line) => lines.push(line),
    now: () => new Date("2026-10-14T01:02:03.000Z"),
    ...overrides,
  });
  return { lines, log };
}

describe("createLogger", () => {
  it("writes one JSON line with the mandatory fields and nested attributes", () => {
    const { lines, log } = capture();
    log.info("poll complete", { review_requested: 2 });
    expect(lines).toHaveLength(1);
    const parsed: unknown = JSON.parse(lines[0] ?? "");
    expect(parsed).toEqual({
      timestamp: "2026-10-14T01:02:03.000Z",
      level: "info",
      message: "poll complete",
      service_name: "mra",
      environment: "test",
      attributes: { review_requested: 2 },
    });
  });

  it("omits attributes when none are given", () => {
    const { lines, log } = capture();
    log.warn("polling paused");
    const parsed: unknown = JSON.parse(lines[0] ?? "");
    expect(parsed).not.toHaveProperty("attributes");
  });

  it("drops entries below the minimum level", () => {
    const { lines, log } = capture({ minLevel: "warn" });
    log.debug("quiet");
    log.info("quiet");
    log.error("loud");
    expect(lines).toHaveLength(1);
  });
});
```

- [ ] **Step 5: Run it to verify it fails**

Run: `npx vitest run test/log.test.ts`
Expected: FAIL — cannot resolve `../src/log.ts`.

- [ ] **Step 6: Write the implementation**

`src/util.ts`:

```ts
export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
```

`src/log.ts`:

```ts
export type LogLevel = "debug" | "info" | "warn" | "error";
export type LogAttributes = Readonly<Record<string, string | number | boolean | null>>;

export interface Logger {
  debug(message: string, attributes?: LogAttributes): void;
  info(message: string, attributes?: LogAttributes): void;
  warn(message: string, attributes?: LogAttributes): void;
  error(message: string, attributes?: LogAttributes): void;
}

export interface LoggerOptions {
  readonly serviceName: string;
  readonly environment: string;
  readonly minLevel: LogLevel;
  readonly write: (line: string) => void;
  readonly now: () => Date;
}

const SERVICE_NAME = "mr-review-assistant";
const LEVEL_ORDER: Readonly<Record<LogLevel, number>> = { debug: 0, info: 1, warn: 2, error: 3 };

function writeToStdout(line: string): void {
  process.stdout.write(`${line}\n`);
}

function levelFromEnv(): LogLevel {
  const value = process.env["MRA_LOG_LEVEL"];
  return value === "debug" || value === "info" || value === "warn" || value === "error"
    ? value
    : "info";
}

export function createLogger(overrides: Partial<LoggerOptions> = {}): Logger {
  const options: LoggerOptions = {
    serviceName: SERVICE_NAME,
    environment: process.env["MRA_ENV"] ?? "local",
    minLevel: levelFromEnv(),
    write: writeToStdout,
    now: () => new Date(),
    ...overrides,
  };

  const emit = (level: LogLevel, message: string, attributes?: LogAttributes): void => {
    if (LEVEL_ORDER[level] < LEVEL_ORDER[options.minLevel]) return;
    options.write(
      JSON.stringify({
        timestamp: options.now().toISOString(),
        level,
        message,
        service_name: options.serviceName,
        environment: options.environment,
        ...(attributes === undefined ? {} : { attributes }),
      }),
    );
  };

  return {
    debug: (message, attributes) => {
      emit("debug", message, attributes);
    },
    info: (message, attributes) => {
      emit("info", message, attributes);
    },
    warn: (message, attributes) => {
      emit("warn", message, attributes);
    },
    error: (message, attributes) => {
      emit("error", message, attributes);
    },
  };
}
```

- [ ] **Step 7: Run the checks**

Run: `npx prettier --write . && npm run check`
Expected: typecheck, lint, format and the 3 logger tests all pass. Fix any lint finding in the new code rather than disabling a rule.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: scaffold repository tooling and JSON logger"
```

---

### Task 2: Domain types and configuration

**Files:**
- Create: `src/domain.ts`, `src/config.ts`
- Test: `test/config.test.ts`

**Interfaces:**
- Consumes: `errorMessage` from `src/util.ts`.
- Produces: types `Person {username, name}`, `Reviewer extends Person {state}`, `Note {id, system, author: Person}`, `MergeRequest`, `Snapshot {me, reviewRequested, authored}`, `ReviewState = string`, constant `UNREVIEWED`; `Config`, `ConfigError`, `parseConfig(text): Config`, `loadConfig(path): Config`, `defaultConfigPath(): string`, `defaultStatePath(): string`.

- [ ] **Step 1: Write the failing config test**

`test/config.test.ts`:

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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `npx vitest run test/config.test.ts`
Expected: FAIL — cannot resolve `../src/config.ts`.

- [ ] **Step 3: Write the domain types**

`src/domain.ts`:

```ts
/** GitLab reviewer state. Observed values: UNREVIEWED, APPROVED, UNAPPROVED; others may exist. */
export type ReviewState = string;

export const UNREVIEWED: ReviewState = "UNREVIEWED";

export interface Person {
  readonly username: string;
  readonly name: string;
}

export interface Reviewer extends Person {
  readonly state: ReviewState;
}

export interface Note {
  readonly id: string;
  readonly system: boolean;
  readonly author: Person;
}

export interface MergeRequest {
  /** `<project path>!<iid>`, stable and safe to log. */
  readonly key: string;
  readonly projectPath: string;
  readonly iid: number;
  readonly title: string;
  readonly url: string;
  readonly draft: boolean;
  readonly author: Person;
  readonly reviewers: readonly Reviewer[];
  /** Most recent notes only; empty for MRs fetched without notes. */
  readonly notes: readonly Note[];
}

export interface Snapshot {
  readonly me: Person;
  /** Open MRs where the Owner is a Reviewer. */
  readonly reviewRequested: readonly MergeRequest[];
  /** Open MRs the Owner authored. */
  readonly authored: readonly MergeRequest[];
}
```

- [ ] **Step 4: Write the config module**

`src/config.ts`:

```ts
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { parse } from "yaml";
import { z } from "zod";
import { errorMessage } from "./util.ts";

const positiveInt = z.number().int().positive();

const configSchema = z
  .object({
    gitlab: z
      .object({
        hostname: z.string().min(1),
        glabPath: z.string().min(1).default("glab"),
        timeoutSeconds: positiveInt.default(60),
      })
      .strict(),
    polling: z
      .object({
        activeSeconds: positiveInt.default(120),
        idleSeconds: positiveInt.default(300),
        idleAfterSeconds: positiveInt.default(300),
        maxBackoffSeconds: positiveInt.default(900),
      })
      .strict()
      .default({}),
    notifications: z
      .object({
        summaryThreshold: positiveInt.default(4),
        ignoreAuthors: z.array(z.string()).default([]),
      })
      .strict()
      .default({}),
    statePath: z.string().min(1).optional(),
  })
  .strict();

export type Config = z.infer<typeof configSchema>;

export class ConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ConfigError";
  }
}

export function parseConfig(text: string): Config {
  let raw: unknown;
  try {
    raw = parse(text);
  } catch (error) {
    throw new ConfigError(`config is not valid YAML: ${errorMessage(error)}`);
  }
  const result = configSchema.safeParse(raw);
  if (!result.success) {
    const problems = result.error.issues.map(
      (issue) => `${issue.path.join(".") || "(root)"}: ${issue.message}`,
    );
    throw new ConfigError(`invalid config: ${problems.join("; ")}`);
  }
  return result.data;
}

export function loadConfig(path: string): Config {
  let text: string;
  try {
    text = readFileSync(path, "utf8");
  } catch (error) {
    throw new ConfigError(`cannot read config at ${path}: ${errorMessage(error)}`);
  }
  return parseConfig(text);
}

export function defaultConfigPath(): string {
  return (
    process.env["MRA_CONFIG"] ?? join(homedir(), ".config", "mr-review-assistant", "config.yaml")
  );
}

export function defaultStatePath(): string {
  return join(homedir(), "Library", "Application Support", "mr-review-assistant", "state.db");
}
```

- [ ] **Step 5: Run the checks**

Run: `npx prettier --write . && npm run check`
Expected: all pass, 6 new config tests green.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: add domain types and YAML configuration"
```

---

### Task 3: GitLab snapshot via glab

**Files:**
- Create: `src/exec.ts`, `src/gitlab.ts`
- Test: `test/gitlab.test.ts`

**Interfaces:**
- Consumes: `Config["gitlab"]`, domain types, `errorMessage`.
- Produces: `Exec`, `ExecResult`, `defaultExec`, `ExecFailure`, `execFailure(error): ExecFailure`; `GitlabFailureKind = "glab-missing" | "gitlab-auth" | "gitlab-unreachable" | "gitlab-error"`; `FetchFailure extends Error { kind: GitlabFailureKind }`; `GraphqlRunner = (query: string) => Promise<unknown>`; `glabRunner(config, exec?): GraphqlRunner`; `parseSnapshot(raw: unknown): Snapshot`; `fetchSnapshot(run: GraphqlRunner): Promise<Snapshot>`; `SNAPSHOT_QUERY`.

The query was run against `repo.madhani.one` on 2026-10-14 (read-only) and returned no `errors`; `iid` arrives as a string.

- [ ] **Step 1: Write the failing tests**

`test/gitlab.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import type { Exec } from "../src/exec.ts";
import { FetchFailure, glabRunner, parseSnapshot } from "../src/gitlab.ts";

const config = { hostname: "gitlab.example", glabPath: "glab", timeoutSeconds: 60 };

function reviewerNode(username: string, state: string | null): Record<string, unknown> {
  return {
    username,
    name: `Name ${username}`,
    mergeRequestInteraction: state === null ? null : { reviewState: state },
  };
}

function node(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    iid: "7",
    title: "Add thing",
    webUrl: "https://gitlab.example/g/p/-/merge_requests/7",
    draft: false,
    project: { fullPath: "g/p" },
    author: { username: "alice", name: "Alice" },
    reviewers: { nodes: [reviewerNode("me", "UNREVIEWED")] },
    ...overrides,
  };
}

function payload(
  parts: { reviewRequested?: unknown[]; authored?: unknown[]; hasNext?: boolean } = {},
): unknown {
  return {
    data: {
      currentUser: {
        username: "me",
        name: "Nata",
        reviewRequestedMergeRequests: {
          pageInfo: { hasNextPage: parts.hasNext ?? false },
          nodes: parts.reviewRequested ?? [],
        },
        authoredMergeRequests: {
          pageInfo: { hasNextPage: false },
          nodes: parts.authored ?? [],
        },
      },
    },
  };
}

function kindOf(fn: () => unknown): string {
  try {
    fn();
  } catch (error) {
    if (error instanceof FetchFailure) return error.kind;
    throw error;
  }
  return "no-failure";
}

describe("parseSnapshot", () => {
  it("maps review-requested and authored MRs", () => {
    const snapshot = parseSnapshot(
      payload({
        reviewRequested: [node()],
        authored: [
          node({
            iid: "9",
            notes: {
              nodes: [{ id: "gid://gitlab/Note/1", system: true, author: { username: "bob", name: "Bob" } }],
            },
          }),
        ],
      }),
    );
    expect(snapshot.me).toEqual({ username: "me", name: "Nata" });
    expect(snapshot.reviewRequested[0]).toMatchObject({
      key: "g/p!7",
      iid: 7,
      title: "Add thing",
      draft: false,
      author: { username: "alice", name: "Alice" },
      reviewers: [{ username: "me", state: "UNREVIEWED" }],
      notes: [],
    });
    expect(snapshot.authored[0]?.notes).toEqual([
      { id: "gid://gitlab/Note/1", system: true, author: { username: "bob", name: "Bob" } },
    ]);
  });

  it("survives a deleted author, a null review state and a null interaction", () => {
    const snapshot = parseSnapshot(
      payload({
        reviewRequested: [
          node({
            author: null,
            reviewers: { nodes: [reviewerNode("me", null), reviewerNode("x", "APPROVED")] },
            notes: { nodes: [{ id: "n1", system: false, author: null }] },
          }),
        ],
      }),
    );
    const found = snapshot.reviewRequested[0];
    expect(found?.author.username).toBe("ghost");
    expect(found?.reviewers.map((r) => r.state)).toEqual(["UNREVIEWED", "APPROVED"]);
    expect(found?.notes[0]?.author.username).toBe("ghost");
  });

  it("fails loudly when there is another page instead of silently truncating", () => {
    expect(kindOf(() => parseSnapshot(payload({ hasNext: true })))).toBe("gitlab-error");
  });

  it("fails on GraphQL errors, a missing current user and a malformed payload", () => {
    expect(kindOf(() => parseSnapshot({ errors: [{ message: "boom" }] }))).toBe("gitlab-error");
    expect(kindOf(() => parseSnapshot({ data: { currentUser: null } }))).toBe("gitlab-auth");
    expect(kindOf(() => parseSnapshot({ data: "nope" }))).toBe("gitlab-error");
  });

  it("refuses a web URL that is not http(s)", () => {
    expect(
      kindOf(() => parseSnapshot(payload({ reviewRequested: [node({ webUrl: "javascript:alert(1)" })] }))),
    ).toBe("gitlab-error");
  });
});

describe("glabRunner", () => {
  const failing =
    (error: object): Exec =>
    () =>
      Promise.reject(Object.assign(new Error("exec failed"), error));

  async function kindOfRun(exec: Exec): Promise<string> {
    try {
      await glabRunner(config, exec)("query { x }");
    } catch (error) {
      if (error instanceof FetchFailure) return error.kind;
      throw error;
    }
    return "no-failure";
  }

  it("passes the host and the query to glab and parses the JSON output", async () => {
    const calls: string[][] = [];
    const run = glabRunner(config, (file, args) => {
      calls.push([file, ...args]);
      return Promise.resolve({ stdout: '{"ok":true}', stderr: "" });
    });
    await expect(run("query { x }")).resolves.toEqual({ ok: true });
    expect(calls).toEqual([
      ["glab", "api", "graphql", "--hostname", "gitlab.example", "-f", "query=query { x }"],
    ]);
  });

  it("classifies failures", async () => {
    expect(await kindOfRun(failing({ code: "ENOENT" }))).toBe("glab-missing");
    expect(await kindOfRun(failing({ killed: true }))).toBe("gitlab-unreachable");
    expect(await kindOfRun(failing({ code: 1, stderr: "dial tcp: lookup gitlab.example: no such host" }))).toBe(
      "gitlab-unreachable",
    );
    expect(await kindOfRun(failing({ code: 1, stderr: "HTTP 401 Unauthorized" }))).toBe("gitlab-auth");
    expect(await kindOfRun(failing({ code: 1, stderr: "something odd" }))).toBe("gitlab-error");
  });

  it("treats non-JSON output as a GitLab error", async () => {
    expect(await kindOfRun(() => Promise.resolve({ stdout: "<html>", stderr: "" }))).toBe("gitlab-error");
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npx vitest run test/gitlab.test.ts`
Expected: FAIL — cannot resolve `../src/exec.ts` / `../src/gitlab.ts`.

- [ ] **Step 3: Write `src/exec.ts`**

```ts
import { execFile } from "node:child_process";
import { promisify } from "node:util";

export interface ExecResult {
  readonly stdout: string;
  readonly stderr: string;
}

export interface ExecOptions {
  readonly timeoutMs: number;
}

export type Exec = (
  file: string,
  args: readonly string[],
  options: ExecOptions,
) => Promise<ExecResult>;

const execFileAsync = promisify(execFile);
const MAX_BUFFER_BYTES = 16 * 1024 * 1024;

export const defaultExec: Exec = async (file, args, options) => {
  const { stdout, stderr } = await execFileAsync(file, [...args], {
    timeout: options.timeoutMs,
    maxBuffer: MAX_BUFFER_BYTES,
    encoding: "utf8",
  });
  return { stdout, stderr };
};

export interface ExecFailure {
  code?: string | number;
  killed?: boolean;
  stderr?: string;
}

/** Narrows the error thrown by `execFile` without trusting its shape. */
export function execFailure(error: unknown): ExecFailure {
  const failure: ExecFailure = {};
  if (typeof error !== "object" || error === null) return failure;
  if ("code" in error && (typeof error.code === "string" || typeof error.code === "number")) {
    failure.code = error.code;
  }
  if ("killed" in error && typeof error.killed === "boolean") failure.killed = error.killed;
  if ("stderr" in error && typeof error.stderr === "string") failure.stderr = error.stderr;
  return failure;
}
```

- [ ] **Step 4: Write `src/gitlab.ts`**

```ts
import { z } from "zod";
import type { Config } from "./config.ts";
import { UNREVIEWED } from "./domain.ts";
import type { MergeRequest, Person, Snapshot } from "./domain.ts";
import { defaultExec, execFailure } from "./exec.ts";
import type { Exec, ExecFailure } from "./exec.ts";

export type GitlabFailureKind =
  | "glab-missing"
  | "gitlab-auth"
  | "gitlab-unreachable"
  | "gitlab-error";

export class FetchFailure extends Error {
  readonly kind: GitlabFailureKind;

  constructor(kind: GitlabFailureKind, message: string) {
    super(message);
    this.name = "FetchFailure";
    this.kind = kind;
  }
}

export type GraphqlRunner = (query: string) => Promise<unknown>;

const PAGE_SIZE = 100;
const NOTES_WINDOW = 50;

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
      nodes {
        ...MrFields
        notes(last: ${NOTES_WINDOW}) { nodes { id system author { username name } } }
      }
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
}
`;

const GHOST: Person = { username: "ghost", name: "(unknown user)" };

const personSchema = z.object({ username: z.string(), name: z.string() });
const reviewerSchema = personSchema.extend({
  mergeRequestInteraction: z.object({ reviewState: z.string().nullable() }).nullable(),
});
const noteSchema = z.object({
  id: z.string(),
  system: z.boolean(),
  author: personSchema.nullable(),
});
const httpUrlSchema = z.string().refine((url) => /^https?:\/\//.test(url), "must be an http(s) URL");
const mrSchema = z.object({
  iid: z.coerce.number().int(),
  title: z.string(),
  webUrl: httpUrlSchema,
  draft: z.boolean(),
  project: z.object({ fullPath: z.string() }),
  author: personSchema.nullable(),
  reviewers: z.object({ nodes: z.array(reviewerSchema) }),
  notes: z.object({ nodes: z.array(noteSchema) }).optional(),
});
const connectionSchema = z.object({
  pageInfo: z.object({ hasNextPage: z.boolean() }),
  nodes: z.array(mrSchema),
});
const responseSchema = z.object({
  data: z
    .object({
      currentUser: z
        .object({
          username: z.string(),
          name: z.string(),
          reviewRequestedMergeRequests: connectionSchema,
          authoredMergeRequests: connectionSchema,
        })
        .nullable(),
    })
    .nullable()
    .optional(),
  errors: z.array(z.object({ message: z.string() })).optional(),
});

function toMergeRequest(node: z.infer<typeof mrSchema>): MergeRequest {
  return {
    key: `${node.project.fullPath}!${node.iid}`,
    projectPath: node.project.fullPath,
    iid: node.iid,
    title: node.title,
    url: node.webUrl,
    draft: node.draft,
    author: node.author ?? GHOST,
    reviewers: node.reviewers.nodes.map((reviewer) => ({
      username: reviewer.username,
      name: reviewer.name,
      state: reviewer.mergeRequestInteraction?.reviewState ?? UNREVIEWED,
    })),
    notes: (node.notes?.nodes ?? []).map((note) => ({
      id: note.id,
      system: note.system,
      author: note.author ?? GHOST,
    })),
  };
}

export function parseSnapshot(raw: unknown): Snapshot {
  const parsed = responseSchema.safeParse(raw);
  if (!parsed.success) throw new FetchFailure("gitlab-error", "unexpected GraphQL response shape");
  const { data, errors } = parsed.data;
  if (errors !== undefined && errors.length > 0) {
    throw new FetchFailure("gitlab-error", "GraphQL response contained errors");
  }
  const user = data?.currentUser;
  if (user === null || user === undefined) {
    throw new FetchFailure("gitlab-auth", "GraphQL response has no current user");
  }
  if (
    user.reviewRequestedMergeRequests.pageInfo.hasNextPage ||
    user.authoredMergeRequests.pageInfo.hasNextPage
  ) {
    throw new FetchFailure(
      "gitlab-error",
      `more than ${PAGE_SIZE} open merge requests; pagination is not supported`,
    );
  }
  return {
    me: { username: user.username, name: user.name },
    reviewRequested: user.reviewRequestedMergeRequests.nodes.map(toMergeRequest),
    authored: user.authoredMergeRequests.nodes.map(toMergeRequest),
  };
}

const UNREACHABLE_PATTERN =
  /timed out|timeout|no such host|connection refused|dial tcp|network is unreachable|could not resolve/;
const AUTH_PATTERN = /401|unauthorized|not logged in|authenticat/;

export function classifyFailure(failure: ExecFailure): GitlabFailureKind {
  if (failure.code === "ENOENT") return "glab-missing";
  const text = (failure.stderr ?? "").toLowerCase();
  if (failure.killed === true || UNREACHABLE_PATTERN.test(text)) return "gitlab-unreachable";
  if (AUTH_PATTERN.test(text)) return "gitlab-auth";
  return "gitlab-error";
}

export function glabRunner(config: Config["gitlab"], exec: Exec = defaultExec): GraphqlRunner {
  return async (query) => {
    let stdout: string;
    try {
      ({ stdout } = await exec(
        config.glabPath,
        ["api", "graphql", "--hostname", config.hostname, "-f", `query=${query}`],
        { timeoutMs: config.timeoutSeconds * 1000 },
      ));
    } catch (error) {
      const failure = execFailure(error);
      throw new FetchFailure(
        classifyFailure(failure),
        failure.code === "ENOENT"
          ? "glab executable not found"
          : `glab failed with code ${String(failure.code ?? "unknown")}`,
      );
    }
    try {
      const output: unknown = JSON.parse(stdout);
      return output;
    } catch {
      throw new FetchFailure("gitlab-error", "glab output was not JSON");
    }
  };
}

export async function fetchSnapshot(run: GraphqlRunner): Promise<Snapshot> {
  return parseSnapshot(await run(SNAPSHOT_QUERY));
}
```

- [ ] **Step 5: Run the checks**

Run: `npx prettier --write . && npm run check`
Expected: all pass. If lint reports `no-unnecessary-condition` or similar on a line above, adjust the code, not the rule.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: fetch review-requested and authored MRs through glab"
```

---

### Task 4: Event detection

**Files:**
- Create: `src/events.ts`
- Create: `test/builders.ts`
- Test: `test/events.test.ts`

**Interfaces:**
- Consumes: domain types.
- Produces: `PreviousState {baselineDone, trackedAuthored: ReadonlySet<string>, myReviewStates: ReadonlyMap<string, ReviewState>, reviewerStates: ReadonlyMap<string, ReviewState>, seenNotes: ReadonlySet<string>}`; `ActivityEvent` (union: `review-requested` | `reviewer-state` | `comment`); `DetectOptions {ignoreAuthors: ReadonlySet<string>}`; `reviewerKey(mrKey, username)`; `myReviewState(snapshot, mr)`; `countPendingReviews(snapshot)`; `detectEvents(snapshot, previous, options): ActivityEvent[]`. Test builders `ME`, `person`, `reviewer`, `note`, `mr`, `snapshot`, `previous` are reused by later tasks.

- [ ] **Step 1: Write the shared test builders**

`test/builders.ts`:

```ts
import type { MergeRequest, Note, Person, Reviewer, Snapshot } from "../src/domain.ts";
import type { PreviousState } from "../src/events.ts";

export const ME: Person = { username: "me", name: "Nata" };

export function person(username: string, name = username): Person {
  return { username, name };
}

export function reviewer(username: string, state: string, name = username): Reviewer {
  return { username, name, state };
}

export function note(id: string, author: Person, system = false): Note {
  return { id, system, author };
}

export function mr(
  iid: number,
  overrides: Partial<Omit<MergeRequest, "iid" | "key">> = {},
): MergeRequest {
  const projectPath = overrides.projectPath ?? "g/p";
  return {
    key: `${projectPath}!${iid}`,
    projectPath,
    iid,
    title: `MR ${iid}`,
    url: `https://gitlab.example/${projectPath}/-/merge_requests/${iid}`,
    draft: false,
    author: person("author", "Author"),
    reviewers: [],
    notes: [],
    ...overrides,
  };
}

export function snapshot(
  parts: { reviewRequested?: MergeRequest[]; authored?: MergeRequest[] } = {},
): Snapshot {
  return { me: ME, reviewRequested: parts.reviewRequested ?? [], authored: parts.authored ?? [] };
}

export function previous(overrides: Partial<PreviousState> = {}): PreviousState {
  return {
    baselineDone: true,
    trackedAuthored: new Set(),
    myReviewStates: new Map(),
    reviewerStates: new Map(),
    seenNotes: new Set(),
    ...overrides,
  };
}
```

- [ ] **Step 2: Write the failing events tests**

`test/events.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import type { MergeRequest } from "../src/domain.ts";
import { countPendingReviews, detectEvents, reviewerKey } from "../src/events.ts";
import type { DetectOptions, PreviousState } from "../src/events.ts";
import { ME, mr, note, person, previous, reviewer, snapshot } from "./builders.ts";

const options: DetectOptions = { ignoreAuthors: new Set(["ci-bot"]) };
const mine = (state: string) => [reviewer("me", state)];

describe("review requests (flow A)", () => {
  it("emits nothing before the baseline is recorded", () => {
    const current = snapshot({ reviewRequested: [mr(1, { reviewers: mine("UNREVIEWED") })] });
    expect(detectEvents(current, previous({ baselineDone: false }), options)).toEqual([]);
  });

  it("emits for a newly seen MR where the Owner is UNREVIEWED", () => {
    const request = mr(1, { reviewers: mine("UNREVIEWED") });
    expect(detectEvents(snapshot({ reviewRequested: [request] }), previous(), options)).toEqual([
      { kind: "review-requested", mr: request },
    ]);
  });

  it("does not repeat for an MR that is already known as UNREVIEWED", () => {
    const request = mr(1, { reviewers: mine("UNREVIEWED") });
    const known = previous({ myReviewStates: new Map([[request.key, "UNREVIEWED"]]) });
    expect(detectEvents(snapshot({ reviewRequested: [request] }), known, options)).toEqual([]);
  });

  it("emits again when the Owner is asked to review again", () => {
    const request = mr(1, { reviewers: mine("UNREVIEWED") });
    const known = previous({ myReviewStates: new Map([[request.key, "APPROVED"]]) });
    expect(detectEvents(snapshot({ reviewRequested: [request] }), known, options)).toHaveLength(1);
  });

  it("stays quiet when the Owner has already reviewed a newly seen MR", () => {
    const request = mr(1, { reviewers: mine("APPROVED") });
    expect(detectEvents(snapshot({ reviewRequested: [request] }), previous(), options)).toEqual([]);
  });

  it("ignores drafts, and a draft that becomes ready is a new request", () => {
    const draft = mr(1, { draft: true, reviewers: mine("UNREVIEWED") });
    expect(detectEvents(snapshot({ reviewRequested: [draft] }), previous(), options)).toEqual([]);
    const ready = mr(1, { draft: false, reviewers: mine("UNREVIEWED") });
    expect(detectEvents(snapshot({ reviewRequested: [ready] }), previous(), options)).toHaveLength(1);
  });

  it("counts pending reviews for the baseline summary", () => {
    const current = snapshot({
      reviewRequested: [
        mr(1, { reviewers: mine("UNREVIEWED") }),
        mr(2, { reviewers: mine("APPROVED") }),
        mr(3, { draft: true, reviewers: mine("UNREVIEWED") }),
      ],
    });
    expect(countPendingReviews(current)).toBe(1);
  });
});

describe("activity on the Owner's MRs (flow D)", () => {
  const bob = person("bob", "Bob");
  const base = (overrides: Partial<MergeRequest> = {}): MergeRequest =>
    mr(5, { author: ME, reviewers: [reviewer("bob", "UNREVIEWED")], ...overrides });
  const tracked = (state = "UNREVIEWED", extra: Partial<PreviousState> = {}): PreviousState =>
    previous({
      trackedAuthored: new Set(["g/p!5"]),
      reviewerStates: new Map([[reviewerKey("g/p!5", "bob"), state]]),
      ...extra,
    });

  it("emits when a Reviewer's state changes to something other than UNREVIEWED", () => {
    const current = snapshot({ authored: [base({ reviewers: [reviewer("bob", "APPROVED")] })] });
    expect(detectEvents(current, tracked(), options)).toEqual([
      { kind: "reviewer-state", mr: current.authored[0], reviewer: person("bob"), to: "APPROVED" },
    ]);
  });

  it("does not emit when the Owner re-requests review (state goes back to UNREVIEWED)", () => {
    const current = snapshot({ authored: [base()] });
    expect(detectEvents(current, tracked("APPROVED"), options)).toEqual([]);
  });

  it("does not emit for a Reviewer who was just added", () => {
    const current = snapshot({ authored: [base({ reviewers: [reviewer("carol", "APPROVED")] })] });
    expect(detectEvents(current, tracked(), options)).toEqual([]);
  });

  it("emits for new comments from other people", () => {
    const comment = note("n1", bob);
    const current = snapshot({ authored: [base({ notes: [comment] })] });
    expect(detectEvents(current, tracked(), options)).toEqual([
      { kind: "comment", mr: current.authored[0], noteId: "n1", author: bob },
    ]);
  });

  it("ignores own notes, system notes, ignored authors and notes already seen", () => {
    const current = snapshot({
      authored: [
        base({
          notes: [
            note("a", ME),
            note("b", bob, true),
            note("c", person("ci-bot")),
            note("d", bob),
          ],
        }),
      ],
    });
    expect(detectEvents(current, tracked("UNREVIEWED", { seenNotes: new Set(["d"]) }), options)).toEqual([]);
  });

  it("records an MR silently the first time it is tracked, even if it already has comments", () => {
    const current = snapshot({
      authored: [base({ notes: [note("old", bob)], reviewers: [reviewer("bob", "APPROVED")] })],
    });
    expect(detectEvents(current, previous(), options)).toEqual([]);
  });

  it("ignores draft MRs of the Owner", () => {
    const current = snapshot({ authored: [base({ draft: true, notes: [note("n", bob)] })] });
    expect(detectEvents(current, tracked(), options)).toEqual([]);
  });
});
```

- [ ] **Step 3: Run to verify it fails**

Run: `npx vitest run test/events.test.ts`
Expected: FAIL — cannot resolve `../src/events.ts`.

- [ ] **Step 4: Write `src/events.ts`**

```ts
import { UNREVIEWED } from "./domain.ts";
import type { MergeRequest, Person, ReviewState, Snapshot } from "./domain.ts";

/** Everything the diff needs to know about the previous poll. */
export interface PreviousState {
  readonly baselineDone: boolean;
  /** Keys of the Owner's non-draft MRs seen in the previous poll. */
  readonly trackedAuthored: ReadonlySet<string>;
  /** MR key -> the Owner's own review state, for non-draft MRs where the Owner is a Reviewer. */
  readonly myReviewStates: ReadonlyMap<string, ReviewState>;
  /** `reviewerKey(mrKey, username)` -> state, for the Owner's MRs. */
  readonly reviewerStates: ReadonlyMap<string, ReviewState>;
  readonly seenNotes: ReadonlySet<string>;
}

export type ActivityEvent =
  | { readonly kind: "review-requested"; readonly mr: MergeRequest }
  | {
      readonly kind: "reviewer-state";
      readonly mr: MergeRequest;
      readonly reviewer: Person;
      readonly to: ReviewState;
    }
  | {
      readonly kind: "comment";
      readonly mr: MergeRequest;
      readonly noteId: string;
      readonly author: Person;
    };

export interface DetectOptions {
  readonly ignoreAuthors: ReadonlySet<string>;
}

export function reviewerKey(mrKey: string, username: string): string {
  return `${mrKey}|${username}`;
}

export function myReviewState(snapshot: Snapshot, mr: MergeRequest): ReviewState {
  return mr.reviewers.find((r) => r.username === snapshot.me.username)?.state ?? UNREVIEWED;
}

export function countPendingReviews(snapshot: Snapshot): number {
  return snapshot.reviewRequested.filter(
    (mr) => !mr.draft && myReviewState(snapshot, mr) === UNREVIEWED,
  ).length;
}

function reviewRequestEvents(snapshot: Snapshot, previous: PreviousState): ActivityEvent[] {
  const events: ActivityEvent[] = [];
  for (const mr of snapshot.reviewRequested) {
    if (mr.draft) continue;
    const isWaiting = myReviewState(snapshot, mr) === UNREVIEWED;
    if (isWaiting && previous.myReviewStates.get(mr.key) !== UNREVIEWED) {
      events.push({ kind: "review-requested", mr });
    }
  }
  return events;
}

function authoredEvents(
  snapshot: Snapshot,
  previous: PreviousState,
  options: DetectOptions,
): ActivityEvent[] {
  const events: ActivityEvent[] = [];
  for (const mr of snapshot.authored) {
    // A draft is ignored; an MR seen for the first time is only recorded, so its history never alerts.
    if (mr.draft || !previous.trackedAuthored.has(mr.key)) continue;
    for (const reviewer of mr.reviewers) {
      if (reviewer.username === snapshot.me.username) continue;
      const before = previous.reviewerStates.get(reviewerKey(mr.key, reviewer.username));
      if (before !== undefined && before !== reviewer.state && reviewer.state !== UNREVIEWED) {
        events.push({
          kind: "reviewer-state",
          mr,
          reviewer: { username: reviewer.username, name: reviewer.name },
          to: reviewer.state,
        });
      }
    }
    for (const note of mr.notes) {
      const ignored =
        note.system ||
        note.author.username === snapshot.me.username ||
        options.ignoreAuthors.has(note.author.username) ||
        previous.seenNotes.has(note.id);
      if (!ignored) events.push({ kind: "comment", mr, noteId: note.id, author: note.author });
    }
  }
  return events;
}

export function detectEvents(
  snapshot: Snapshot,
  previous: PreviousState,
  options: DetectOptions,
): ActivityEvent[] {
  if (!previous.baselineDone) return [];
  return [...reviewRequestEvents(snapshot, previous), ...authoredEvents(snapshot, previous, options)];
}
```

- [ ] **Step 5: Run the checks**

Run: `npx prettier --write . && npm run check`
Expected: all pass, 14 new events tests green.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: detect review requests and activity on own MRs"
```

---

### Task 5: Notification wording and macOS delivery

**Files:**
- Create: `src/format.ts`, `src/notifier.ts`
- Test: `test/format.test.ts`, `test/notifier.test.ts`

**Interfaces:**
- Consumes: `ActivityEvent` from `src/events.ts`; `Exec`, `defaultExec`, `execFailure` from `src/exec.ts`.
- Produces: `Notification {title, body, url?}`; `clean(text, maxLength?)`; `buildNotifications(events, summaryThreshold): Notification[]`; `baselineNotifications(pending: number): Notification[]`; `Notifier {notify(n): Promise<void>}`; `createNotifier(exec?)`.

- [ ] **Step 1: Write the failing format tests**

`test/format.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import type { ActivityEvent } from "../src/events.ts";
import { baselineNotifications, buildNotifications, clean } from "../src/format.ts";
import { mr, person } from "./builders.ts";

describe("clean", () => {
  it("flattens newlines and control characters", () => {
    expect(clean("a\nb\u0007c")).toBe("a b c");
  });

  it("removes leading dashes so the text can never be read as a command-line flag", () => {
    expect(clean("--open evil")).toBe("open evil");
  });

  it("truncates by code points without splitting an emoji", () => {
    expect(clean("x".repeat(200), 10)).toBe(`${"x".repeat(9)}…`);
    expect(clean("😀".repeat(5), 3)).toBe("😀😀…");
  });
});

describe("buildNotifications", () => {
  it("describes a review request with the Author and project", () => {
    const events: ActivityEvent[] = [
      {
        kind: "review-requested",
        mr: mr(7, { title: "Add thing", author: person("alice", "Alice"), projectPath: "g/p" }),
      },
    ];
    expect(buildNotifications(events, 4)).toEqual([
      {
        title: "Diminta review: Add thing",
        body: "Alice · g/p",
        url: "https://gitlab.example/g/p/-/merge_requests/7",
      },
    ]);
  });

  it("merges all activity on one MR into a single notification", () => {
    const target = mr(7, { title: "Add thing" });
    const events: ActivityEvent[] = [
      { kind: "reviewer-state", mr: target, reviewer: person("bob", "Bob"), to: "APPROVED" },
      { kind: "comment", mr: target, noteId: "1", author: person("carol", "Carol") },
      { kind: "comment", mr: target, noteId: "2", author: person("dave", "Dave") },
    ];
    expect(buildNotifications(events, 4)).toEqual([
      {
        title: "!7: Add thing",
        body: "Bob menyetujui; 2 komentar baru dari Carol, Dave",
        url: target.url,
      },
    ]);
  });

  it("falls back to a generic phrase for an unknown review state", () => {
    const events: ActivityEvent[] = [
      { kind: "reviewer-state", mr: mr(1), reviewer: person("bob", "Bob"), to: "SOMETHING_NEW" },
    ];
    expect(buildNotifications(events, 4)[0]?.body).toBe("Bob mengubah status review ke SOMETHING_NEW");
  });

  it("collapses a burst into one summary above the threshold, but not at the threshold", () => {
    const requests = (count: number): ActivityEvent[] =>
      Array.from({ length: count }, (_, index) => ({
        kind: "review-requested" as const,
        mr: mr(index + 1),
      }));
    expect(buildNotifications(requests(4), 4)).toHaveLength(4);
    const summary = buildNotifications(requests(5), 4);
    expect(summary).toEqual([
      {
        title: "5 aktivitas MR baru",
        body: "Diminta review: MR 1 | Diminta review: MR 2 | Diminta review: MR 3 +2 lainnya",
      },
    ]);
    expect(summary[0]).not.toHaveProperty("url");
  });

  it("neutralises hostile titles and names", () => {
    const events: ActivityEvent[] = [
      {
        kind: "review-requested",
        mr: mr(1, { title: "--evil\nsecond line", author: person("x", "-n Mallory") }),
      },
    ];
    const [only] = buildNotifications(events, 4);
    expect(only?.title).toBe("Diminta review: evil second line");
    expect(only?.body).toBe("n Mallory · g/p");
    expect(only?.title).not.toContain("\n");
  });
});

describe("baselineNotifications", () => {
  it("is silent when nothing is waiting and summarises otherwise", () => {
    expect(baselineNotifications(0)).toEqual([]);
    expect(baselineNotifications(3)).toEqual([
      { title: "MR Review Assistant aktif", body: "3 MR menunggu review-mu" },
    ]);
  });
});
```

Note on the hostile-title case: `clean` is applied to each untrusted field on its own, before any fixed prefix is added, so a title or author name that starts with dashes loses them (`--evil` becomes `evil`, `-n Mallory` becomes `n Mallory`). The result can never be read as a flag, whichever field `terminal-notifier` receives it in.

- [ ] **Step 2: Write the failing notifier tests**

`test/notifier.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import type { Exec } from "../src/exec.ts";
import { createNotifier } from "../src/notifier.ts";

function recordingExec(options: { terminalNotifierMissing?: boolean; failWith?: object } = {}): {
  calls: string[][];
  exec: Exec;
} {
  const calls: string[][] = [];
  const exec: Exec = (file, args) => {
    calls.push([file, ...args]);
    if (options.failWith !== undefined) {
      return Promise.reject(Object.assign(new Error("exec failed"), options.failWith));
    }
    if (file === "terminal-notifier" && options.terminalNotifierMissing === true) {
      return Promise.reject(Object.assign(new Error("spawn ENOENT"), { code: "ENOENT" }));
    }
    return Promise.resolve({ stdout: "", stderr: "" });
  };
  return { calls, exec };
}

describe("createNotifier", () => {
  it("uses terminal-notifier and opens the URL on click", async () => {
    const { calls, exec } = recordingExec();
    await createNotifier(exec).notify({ title: "T", body: "B", url: "https://x/y" });
    expect(calls).toEqual([
      ["terminal-notifier", "-title", "T", "-message", "B", "-open", "https://x/y"],
    ]);
  });

  it("omits -open when there is no URL", async () => {
    const { calls, exec } = recordingExec();
    await createNotifier(exec).notify({ title: "T", body: "B" });
    expect(calls[0]).toEqual(["terminal-notifier", "-title", "T", "-message", "B"]);
  });

  it("falls back to osascript and passes the text as arguments, never as script source", async () => {
    const { calls, exec } = recordingExec({ terminalNotifierMissing: true });
    await createNotifier(exec).notify({ title: 'T"; do shell script "x', body: "B" });
    const fallback = calls[1] ?? [];
    expect(fallback[0]).toBe("osascript");
    expect(fallback.slice(-2)).toEqual(['T"; do shell script "x', "B"]);
    const script = fallback.slice(1, -2).join("\n");
    expect(script).not.toContain("do shell script");
  });

  it("propagates failures other than a missing terminal-notifier", async () => {
    const { calls, exec } = recordingExec({ failWith: { code: 1 } });
    await expect(createNotifier(exec).notify({ title: "T", body: "B" })).rejects.toThrow();
    expect(calls).toHaveLength(1);
  });
});
```

- [ ] **Step 3: Run to verify both fail**

Run: `npx vitest run test/format.test.ts test/notifier.test.ts`
Expected: FAIL — cannot resolve `../src/format.ts` / `../src/notifier.ts`.

- [ ] **Step 4: Write `src/format.ts`**

```ts
import type { ActivityEvent } from "./events.ts";
import type { MergeRequest, ReviewState } from "./domain.ts";

export interface Notification {
  readonly title: string;
  readonly body: string;
  readonly url?: string;
}

const TITLE_MAX = 80;
const NAME_MAX = 40;
const BODY_MAX = 160;
const SUMMARY_PREVIEW = 3;

const STATE_PHRASES: Readonly<Record<string, string>> = {
  APPROVED: "menyetujui",
  UNAPPROVED: "membatalkan persetujuan",
  REQUESTED_CHANGES: "meminta perubahan",
  REVIEWED: "memberi review",
};

/** Single line, no control characters, never starting with `-`, at most `maxLength` code points. */
export function clean(text: string, maxLength = 120): string {
  const flat = text
    .replace(/\p{Cc}+/gu, " ")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/^-+\s*/, "");
  const characters = [...flat];
  return characters.length <= maxLength ? flat : `${characters.slice(0, maxLength - 1).join("")}…`;
}

function describeState(state: ReviewState): string {
  return STATE_PHRASES[state] ?? `mengubah status review ke ${state}`;
}

function reviewRequestNotifications(events: readonly ActivityEvent[]): Notification[] {
  const result: Notification[] = [];
  for (const event of events) {
    if (event.kind !== "review-requested") continue;
    result.push({
      title: `Diminta review: ${clean(event.mr.title, TITLE_MAX)}`,
      body: clean(`${event.mr.author.name} · ${event.mr.projectPath}`, BODY_MAX),
      url: event.mr.url,
    });
  }
  return result;
}

interface AuthoredGroup {
  readonly mr: MergeRequest;
  readonly stateChanges: string[];
  readonly commenters: Set<string>;
  comments: number;
}

function authoredNotifications(events: readonly ActivityEvent[]): Notification[] {
  const groups = new Map<string, AuthoredGroup>();
  const groupFor = (mr: MergeRequest): AuthoredGroup => {
    const existing = groups.get(mr.key);
    if (existing !== undefined) return existing;
    const created: AuthoredGroup = { mr, stateChanges: [], commenters: new Set(), comments: 0 };
    groups.set(mr.key, created);
    return created;
  };
  for (const event of events) {
    if (event.kind === "reviewer-state") {
      groupFor(event.mr).stateChanges.push(
        `${clean(event.reviewer.name, NAME_MAX)} ${describeState(event.to)}`,
      );
    } else if (event.kind === "comment") {
      const group = groupFor(event.mr);
      group.comments += 1;
      group.commenters.add(clean(event.author.name, NAME_MAX));
    }
  }
  return [...groups.values()].map((group) => {
    const parts = [...group.stateChanges];
    if (group.comments > 0) {
      parts.push(`${group.comments} komentar baru dari ${[...group.commenters].join(", ")}`);
    }
    return {
      title: `!${group.mr.iid}: ${clean(group.mr.title, TITLE_MAX)}`,
      body: clean(parts.join("; "), BODY_MAX),
      url: group.mr.url,
    };
  });
}

function summarise(notifications: readonly Notification[]): Notification {
  const shown = notifications
    .slice(0, SUMMARY_PREVIEW)
    .map((notification) => notification.title)
    .join(" | ");
  const rest = notifications.length - SUMMARY_PREVIEW;
  return {
    title: `${notifications.length} aktivitas MR baru`,
    body: rest > 0 ? `${shown} +${rest} lainnya` : shown,
  };
}

export function buildNotifications(
  events: readonly ActivityEvent[],
  summaryThreshold: number,
): Notification[] {
  const notifications = [...reviewRequestNotifications(events), ...authoredNotifications(events)];
  return notifications.length > summaryThreshold ? [summarise(notifications)] : notifications;
}

export function baselineNotifications(pending: number): Notification[] {
  return pending === 0
    ? []
    : [{ title: "MR Review Assistant aktif", body: `${pending} MR menunggu review-mu` }];
}
```

- [ ] **Step 5: Write `src/notifier.ts`**

```ts
import { defaultExec, execFailure } from "./exec.ts";
import type { Exec } from "./exec.ts";
import type { Notification } from "./format.ts";

export interface Notifier {
  notify(notification: Notification): Promise<void>;
}

const NOTIFY_TIMEOUT_MS = 10_000;

/**
 * `terminal-notifier` when installed (a click opens the MR), otherwise `osascript`
 * (no click-through). Text always travels as process arguments, never inside script source.
 */
export function createNotifier(exec: Exec = defaultExec): Notifier {
  return {
    async notify(notification) {
      const { title, body, url } = notification;
      try {
        await exec(
          "terminal-notifier",
          ["-title", title, "-message", body, ...(url === undefined ? [] : ["-open", url])],
          { timeoutMs: NOTIFY_TIMEOUT_MS },
        );
        return;
      } catch (error) {
        if (execFailure(error).code !== "ENOENT") throw error;
      }
      await exec(
        "osascript",
        [
          "-e",
          "on run argv",
          "-e",
          "display notification (item 2 of argv) with title (item 1 of argv)",
          "-e",
          "end run",
          title,
          body,
        ],
        { timeoutMs: NOTIFY_TIMEOUT_MS },
      );
    },
  };
}
```

- [ ] **Step 6: Run the checks**

Run: `npx prettier --write . && npm run check`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: build Indonesian notifications and deliver them on macOS"
```

---

### Task 6: SQLite state store

**Files:**
- Create: `src/store.ts`
- Test: `test/store.test.ts`

**Interfaces:**
- Consumes: `PreviousState`, `reviewerKey`, `myReviewState` from `src/events.ts`; `Snapshot`.
- Produces: `Store { load(): PreviousState; commit(snapshot: Snapshot): void; isPaused(): boolean; setPaused(paused: boolean): void; close(): void }`; `openStore(path: string): Store` (`":memory:"` allowed).

Risk to check in Step 2: `node:sqlite` is a prefix-only built-in. If vitest cannot resolve it, add `test: { server: { deps: { external: [/^node:/] } } }` to `vitest.config.ts` and re-run before changing any code.

- [ ] **Step 1: Write the failing tests**

`test/store.test.ts`:

```ts
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, describe, expect, it } from "vitest";
import { reviewerKey } from "../src/events.ts";
import { openStore } from "../src/store.ts";
import { ME, mr, note, person, reviewer, snapshot } from "./builders.ts";

const folders: string[] = [];
function tempDb(): string {
  const folder = mkdtempSync(join(tmpdir(), "mra-store-"));
  folders.push(folder);
  return join(folder, "state.db");
}
afterEach(() => {
  for (const folder of folders.splice(0)) rmSync(folder, { recursive: true, force: true });
});

const bob = person("bob", "Bob");

describe("openStore", () => {
  it("starts empty and not yet baselined", () => {
    const store = openStore(":memory:");
    expect(store.load()).toEqual({
      baselineDone: false,
      trackedAuthored: new Set(),
      myReviewStates: new Map(),
      reviewerStates: new Map(),
      seenNotes: new Set(),
    });
    expect(store.isPaused()).toBe(false);
  });

  it("commits exactly what the next diff needs, leaving drafts out", () => {
    const store = openStore(":memory:");
    store.commit(
      snapshot({
        reviewRequested: [
          mr(1, { reviewers: [reviewer("me", "UNREVIEWED")] }),
          mr(2, { draft: true, reviewers: [reviewer("me", "UNREVIEWED")] }),
        ],
        authored: [
          mr(5, {
            author: ME,
            reviewers: [reviewer("bob", "APPROVED")],
            notes: [note("n1", bob)],
          }),
          mr(6, { author: ME, draft: true, notes: [note("n2", bob)] }),
        ],
      }),
    );
    expect(store.load()).toEqual({
      baselineDone: true,
      trackedAuthored: new Set(["g/p!5"]),
      myReviewStates: new Map([["g/p!1", "UNREVIEWED"]]),
      reviewerStates: new Map([[reviewerKey("g/p!5", "bob"), "APPROVED"]]),
      seenNotes: new Set(["n1"]),
    });
  });

  it("replaces state on every commit so closed MRs and old notes are pruned", () => {
    const store = openStore(":memory:");
    store.commit(snapshot({ authored: [mr(5, { author: ME, notes: [note("n1", bob)] })] }));
    store.commit(snapshot());
    const state = store.load();
    expect(state.trackedAuthored.size).toBe(0);
    expect(state.seenNotes.size).toBe(0);
    expect(state.baselineDone).toBe(true);
  });

  it("persists across reopening and keeps the pause flag", () => {
    const path = tempDb();
    const first = openStore(path);
    first.commit(snapshot({ reviewRequested: [mr(1, { reviewers: [reviewer("me", "UNREVIEWED")] })] }));
    first.setPaused(true);
    first.close();
    const second = openStore(path);
    expect(second.load().myReviewStates.get("g/p!1")).toBe("UNREVIEWED");
    expect(second.isPaused()).toBe(true);
    second.setPaused(false);
    expect(second.isPaused()).toBe(false);
    second.close();
  });

  it("refuses a database written by a newer version", () => {
    const path = tempDb();
    const raw = new DatabaseSync(path);
    raw.exec("PRAGMA user_version = 99");
    raw.close();
    expect(() => openStore(path)).toThrow(/newer/);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npx vitest run test/store.test.ts`
Expected: FAIL — cannot resolve `../src/store.ts`. (A different failure about `node:sqlite` means apply the vitest config note above.)

- [ ] **Step 3: Write `src/store.ts`**

```ts
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { DatabaseSync } from "node:sqlite";
import type { Snapshot } from "./domain.ts";
import { myReviewState, reviewerKey } from "./events.ts";
import type { PreviousState } from "./events.ts";

export interface Store {
  load(): PreviousState;
  /** Replaces the stored state with `snapshot` in one transaction and marks the baseline as done. */
  commit(snapshot: Snapshot): void;
  isPaused(): boolean;
  setPaused(paused: boolean): void;
  close(): void;
}

const SCHEMA_VERSION = 1;
const SCHEMA = `
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS tracked_authored (mr_key TEXT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS my_review_state (mr_key TEXT PRIMARY KEY, state TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS reviewer_state (
  mr_key TEXT NOT NULL,
  username TEXT NOT NULL,
  state TEXT NOT NULL,
  PRIMARY KEY (mr_key, username)
);
CREATE TABLE IF NOT EXISTS seen_note (note_id TEXT PRIMARY KEY);
`;
const META_BASELINE = "baseline_done";
const META_PAUSED = "paused";
const DIRECTORY_MODE = 0o700;
const BUSY_TIMEOUT_MS = 5000;

type Row = Record<string, unknown>;

function text(row: Row, column: string): string {
  const value = row[column];
  if (typeof value !== "string") throw new Error(`column ${column} is not text`);
  return value;
}

function initSchema(db: DatabaseSync): void {
  const found = db.prepare("PRAGMA user_version").get()?.["user_version"];
  const version = typeof found === "number" ? found : 0;
  if (version > SCHEMA_VERSION) {
    throw new Error(`state database schema ${version} is newer than supported ${SCHEMA_VERSION}`);
  }
  if (version === 0) {
    db.exec(SCHEMA);
    db.exec(`PRAGMA user_version = ${SCHEMA_VERSION}`);
  }
}

export function openStore(path: string): Store {
  if (path !== ":memory:") mkdirSync(dirname(path), { recursive: true, mode: DIRECTORY_MODE });
  const db = new DatabaseSync(path);
  try {
    db.exec(`PRAGMA journal_mode = WAL; PRAGMA busy_timeout = ${BUSY_TIMEOUT_MS};`);
    initSchema(db);
  } catch (error) {
    db.close();
    throw error;
  }

  const rows = (sql: string): Row[] => db.prepare(sql).all();
  const metaValue = (key: string): string | undefined => {
    const row = db.prepare("SELECT value FROM meta WHERE key = ?").get(key);
    return row === undefined ? undefined : text(row, "value");
  };
  const setMeta = (key: string, value: string): void => {
    db.prepare(
      "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
    ).run(key, value);
  };

  return {
    load() {
      return {
        baselineDone: metaValue(META_BASELINE) === "1",
        trackedAuthored: new Set(
          rows("SELECT mr_key FROM tracked_authored").map((row) => text(row, "mr_key")),
        ),
        myReviewStates: new Map(
          rows("SELECT mr_key, state FROM my_review_state").map(
            (row) => [text(row, "mr_key"), text(row, "state")] as const,
          ),
        ),
        reviewerStates: new Map(
          rows("SELECT mr_key, username, state FROM reviewer_state").map(
            (row) =>
              [reviewerKey(text(row, "mr_key"), text(row, "username")), text(row, "state")] as const,
          ),
        ),
        seenNotes: new Set(rows("SELECT note_id FROM seen_note").map((row) => text(row, "note_id"))),
      };
    },

    commit(snapshot) {
      const insertTracked = db.prepare("INSERT OR REPLACE INTO tracked_authored (mr_key) VALUES (?)");
      const insertMine = db.prepare("INSERT OR REPLACE INTO my_review_state (mr_key, state) VALUES (?, ?)");
      const insertReviewer = db.prepare(
        "INSERT OR REPLACE INTO reviewer_state (mr_key, username, state) VALUES (?, ?, ?)",
      );
      const insertNote = db.prepare("INSERT OR REPLACE INTO seen_note (note_id) VALUES (?)");
      db.exec("BEGIN IMMEDIATE");
      try {
        db.exec(
          "DELETE FROM tracked_authored; DELETE FROM my_review_state; DELETE FROM reviewer_state; DELETE FROM seen_note;",
        );
        for (const mr of snapshot.reviewRequested) {
          if (!mr.draft) insertMine.run(mr.key, myReviewState(snapshot, mr));
        }
        for (const mr of snapshot.authored) {
          if (mr.draft) continue;
          insertTracked.run(mr.key);
          for (const reviewer of mr.reviewers) insertReviewer.run(mr.key, reviewer.username, reviewer.state);
          for (const note of mr.notes) insertNote.run(note.id);
        }
        setMeta(META_BASELINE, "1");
        db.exec("COMMIT");
      } catch (error) {
        db.exec("ROLLBACK");
        throw error;
      }
    },

    isPaused: () => metaValue(META_PAUSED) === "1",
    setPaused: (paused) => {
      setMeta(META_PAUSED, paused ? "1" : "0");
    },
    close: () => {
      db.close();
    },
  };
}
```

- [ ] **Step 4: Run the checks**

Run: `npx prettier --write . && npm run check`
Expected: all pass, 5 new store tests green.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: persist poll state in SQLite"
```

---

### Task 7: Failure tracker and poll cycle

**Files:**
- Create: `src/failures.ts`, `src/poller.ts`
- Test: `test/poller.test.ts`

**Interfaces:**
- Consumes: `Store`, `Notifier`, `Notification`, `Logger`, `Config`, `Snapshot`, `FetchFailure`/`GitlabFailureKind`, `detectEvents`/`countPendingReviews`, `buildNotifications`/`baselineNotifications`, `execFailure`.
- Produces: `FailureKind = GitlabFailureKind | "notifier"`; `FailureTracker { fail(kind): boolean; recover(kind): boolean }`; `createFailureTracker()`; `failureNotification(kind: GitlabFailureKind, hostname: string): Notification`; `PollDeps {fetchSnapshot, store, notifier, failures, log, config: Pick<Config, "gitlab" | "notifications">}`; `PollStatus = "ok" | "paused" | "failed"`; `pollOnce(deps): Promise<PollStatus>`.

- [ ] **Step 1: Write the failing poller tests**

`test/poller.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { createFailureTracker } from "../src/failures.ts";
import type { Notification } from "../src/format.ts";
import { FetchFailure } from "../src/gitlab.ts";
import { createLogger } from "../src/log.ts";
import type { Notifier } from "../src/notifier.ts";
import { pollOnce } from "../src/poller.ts";
import type { PollDeps } from "../src/poller.ts";
import { openStore } from "../src/store.ts";
import type { MergeRequest, Snapshot } from "../src/domain.ts";
import { ME, mr, note, person, reviewer, snapshot } from "./builders.ts";

const config: PollDeps["config"] = {
  gitlab: { hostname: "gitlab.example", glabPath: "glab", timeoutSeconds: 60 },
  notifications: { summaryThreshold: 4, ignoreAuthors: [] },
};

function harness() {
  const store = openStore(":memory:");
  const sent: Notification[] = [];
  const logs: string[] = [];
  let failing = false;
  let current: Snapshot = snapshot();
  let fetchError: Error | undefined;
  let fetchCount = 0;
  const notifier: Notifier = {
    notify: (notification) => {
      if (failing) return Promise.reject(new Error("boom"));
      sent.push(notification);
      return Promise.resolve();
    },
  };
  const deps: PollDeps = {
    fetchSnapshot: () => {
      fetchCount += 1;
      return fetchError === undefined ? Promise.resolve(current) : Promise.reject(fetchError);
    },
    store,
    notifier,
    failures: createFailureTracker(),
    log: createLogger({ write: (line) => logs.push(line), minLevel: "debug" }),
    config,
  };
  return {
    store,
    sent,
    logs,
    poll: () => pollOnce(deps),
    fetchCount: () => fetchCount,
    setSnapshot: (next: Snapshot) => {
      current = next;
    },
    setFetchError: (error: Error | undefined) => {
      fetchError = error;
    },
    setNotifierFailing: (value: boolean) => {
      failing = value;
    },
  };
}

const waiting = (iid: number) => mr(iid, { reviewers: [reviewer("me", "UNREVIEWED")] });

describe("pollOnce", () => {
  it("records a silent baseline with one summary, then stays quiet", async () => {
    const h = harness();
    h.setSnapshot(snapshot({ reviewRequested: [waiting(1), waiting(2)] }));
    expect(await h.poll()).toBe("ok");
    expect(h.sent).toEqual([{ title: "MR Review Assistant aktif", body: "2 MR menunggu review-mu" }]);
    expect(await h.poll()).toBe("ok");
    expect(h.sent).toHaveLength(1);
  });

  it("notifies about a review request that appears after the baseline", async () => {
    const h = harness();
    await h.poll();
    h.setSnapshot(snapshot({ reviewRequested: [waiting(3)] }));
    await h.poll();
    expect(h.sent).toEqual([
      {
        title: "Diminta review: MR 3",
        body: "Author · g/p",
        url: "https://gitlab.example/g/p/-/merge_requests/3",
      },
    ]);
  });

  it("alerts about activity on the Owner's own MR", async () => {
    const h = harness();
    const own = (overrides: Partial<MergeRequest> = {}): MergeRequest =>
      mr(5, { author: ME, reviewers: [reviewer("bob", "UNREVIEWED", "Bob")], ...overrides });
    h.setSnapshot(snapshot({ authored: [own()] }));
    await h.poll();
    h.setSnapshot(
      snapshot({
        authored: [
          own({
            reviewers: [reviewer("bob", "APPROVED", "Bob")],
            notes: [note("n1", person("bob", "Bob"))],
          }),
        ],
      }),
    );
    await h.poll();
    expect(h.sent).toHaveLength(1);
    expect(h.sent[0]?.body).toBe("Bob menyetujui; 1 komentar baru dari Bob");
  });

  it("wake catch-up: many changes at once become one summary", async () => {
    const h = harness();
    await h.poll();
    h.setSnapshot(snapshot({ reviewRequested: [1, 2, 3, 4, 5, 6].map(waiting) }));
    await h.poll();
    expect(h.sent).toHaveLength(1);
    expect(h.sent[0]?.title).toBe("6 aktivitas MR baru");
  });

  it("notifier failure keeps state uncommitted so the events are retried, and never logs the text", async () => {
    const h = harness();
    h.setSnapshot(snapshot({ reviewRequested: [mr(1, { title: "Secret title", reviewers: [reviewer("me", "UNREVIEWED")] })] }));
    h.setNotifierFailing(true);
    expect(await h.poll()).toBe("failed");
    expect(h.store.load().baselineDone).toBe(false);
    expect(h.logs.join("\n")).not.toContain("Secret title");
    h.setNotifierFailing(false);
    expect(await h.poll()).toBe("ok");
    expect(h.sent).toHaveLength(1);
  });

  it("tells the Owner about a GitLab failure once, and again only after recovery", async () => {
    const h = harness();
    h.setFetchError(new FetchFailure("gitlab-auth", "no current user"));
    expect(await h.poll()).toBe("failed");
    expect(await h.poll()).toBe("failed");
    expect(h.sent).toHaveLength(1);
    expect(h.sent[0]?.title).toBe("Login GitLab gagal");
    h.setFetchError(undefined);
    expect(await h.poll()).toBe("ok");
    h.setFetchError(new FetchFailure("gitlab-auth", "no current user"));
    await h.poll();
    expect(h.sent).toHaveLength(2);
  });

  it("does not touch GitLab while paused", async () => {
    const h = harness();
    h.store.setPaused(true);
    expect(await h.poll()).toBe("paused");
    expect(h.fetchCount()).toBe(0);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npx vitest run test/poller.test.ts`
Expected: FAIL — cannot resolve `../src/failures.ts`.

- [ ] **Step 3: Write `src/failures.ts`**

```ts
import type { Notification } from "./format.ts";
import type { GitlabFailureKind } from "./gitlab.ts";

export type FailureKind = GitlabFailureKind | "notifier";

export interface FailureTracker {
  /** Records a failure; true when this kind was not already failing (tell the Owner once). */
  fail(kind: FailureKind): boolean;
  /** Clears a failure; true when it was failing. */
  recover(kind: FailureKind): boolean;
}

export function createFailureTracker(): FailureTracker {
  const active = new Set<FailureKind>();
  return {
    fail(kind) {
      const isNew = !active.has(kind);
      active.add(kind);
      return isNew;
    },
    recover: (kind) => active.delete(kind),
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

- [ ] **Step 4: Write `src/poller.ts`**

```ts
import type { Config } from "./config.ts";
import type { Snapshot } from "./domain.ts";
import { countPendingReviews, detectEvents } from "./events.ts";
import { execFailure } from "./exec.ts";
import { failureNotification } from "./failures.ts";
import type { FailureTracker } from "./failures.ts";
import { baselineNotifications, buildNotifications } from "./format.ts";
import { FetchFailure } from "./gitlab.ts";
import type { GitlabFailureKind } from "./gitlab.ts";
import type { Logger } from "./log.ts";
import type { Notifier } from "./notifier.ts";
import type { Store } from "./store.ts";

export interface PollDeps {
  readonly fetchSnapshot: () => Promise<Snapshot>;
  readonly store: Store;
  readonly notifier: Notifier;
  readonly failures: FailureTracker;
  readonly log: Logger;
  readonly config: Pick<Config, "gitlab" | "notifications">;
}

export type PollStatus = "ok" | "paused" | "failed";

const GITLAB_FAILURE_KINDS: readonly GitlabFailureKind[] = [
  "glab-missing",
  "gitlab-auth",
  "gitlab-unreachable",
  "gitlab-error",
];

async function reportFetchFailure(deps: PollDeps, error: unknown): Promise<void> {
  const kind: GitlabFailureKind = error instanceof FetchFailure ? error.kind : "gitlab-error";
  const reason = error instanceof FetchFailure ? error.message : "unexpected error";
  if (!deps.failures.fail(kind)) {
    deps.log.warn("gitlab poll still failing", { kind });
    return;
  }
  deps.log.error("gitlab poll failed", { kind, reason });
  try {
    await deps.notifier.notify(failureNotification(kind, deps.config.gitlab.hostname));
  } catch {
    // The notifier itself is broken; the error log above is the only channel left.
    deps.log.error("failure notification not delivered", { kind });
  }
}

/**
 * One poll cycle. Order matters: events are delivered first and state is committed last, so a
 * failed delivery is retried on the next poll instead of being marked as seen.
 */
export async function pollOnce(deps: PollDeps): Promise<PollStatus> {
  const { store, notifier, failures, log, config } = deps;
  if (store.isPaused()) {
    log.info("polling paused");
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

  const previous = store.load();
  const notifications = previous.baselineDone
    ? buildNotifications(
        detectEvents(snapshot, previous, {
          ignoreAuthors: new Set(config.notifications.ignoreAuthors),
        }),
        config.notifications.summaryThreshold,
      )
    : baselineNotifications(countPendingReviews(snapshot));

  try {
    for (const notification of notifications) await notifier.notify(notification);
  } catch (error) {
    if (failures.fail("notifier")) {
      // Never log the error message: process errors embed the notification text.
      log.error("notification delivery failed", {
        code: String(execFailure(error).code ?? "unknown"),
      });
    }
    return "failed";
  }
  failures.recover("notifier");

  store.commit(snapshot);
  log.debug("poll complete", {
    review_requested: snapshot.reviewRequested.length,
    authored: snapshot.authored.length,
    notifications: notifications.length,
    baseline: !previous.baselineDone,
  });
  return "ok";
}
```

- [ ] **Step 5: Run the checks**

Run: `npx prettier --write . && npm run check`
Expected: all pass, 7 new poller tests green.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: add the poll cycle with once-per-kind failure reporting"
```

---

### Task 8: Scheduling, daemon and CLI

**Files:**
- Create: `src/idle.ts`, `src/scheduler.ts`, `src/daemon.ts`, `src/runtime.ts`, `src/main.ts`, `src/cli.ts`, `scripts/mra`
- Test: `test/idle.test.ts`, `test/scheduler.test.ts`, `test/daemon.test.ts`

**Interfaces:**
- Consumes: `Config`, `PollStatus`, `pollOnce`, `openStore`, `createNotifier`, `glabRunner`/`fetchSnapshot`, `createFailureTracker`, `createLogger`, `Exec`.
- Produces: `parseIdleSeconds(text): number | null`, `readIdleSeconds(exec?): Promise<number>`; `nextDelaySeconds({idleSeconds, failureStreak, polling}): number`; `abortableSleep(ms, signal)`, `runDaemon(deps)`; `createRuntime(configPath): Runtime { config, store, log, poll() }`; `src/main.ts` (daemon) and `src/cli.ts` (`once|status|pause|resume`).

- [ ] **Step 1: Write the failing tests**

`test/idle.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { parseIdleSeconds, readIdleSeconds } from "../src/idle.ts";

describe("parseIdleSeconds", () => {
  it("converts nanoseconds from ioreg output to seconds", () => {
    expect(parseIdleSeconds('    | |   "HIDIdleTime" = 4500000000\n')).toBe(4.5);
  });

  it("returns null when the field is absent", () => {
    expect(parseIdleSeconds("nothing here")).toBeNull();
  });
});

describe("readIdleSeconds", () => {
  it("treats a failing ioreg as 'active' so polling stays at the fast interval", async () => {
    await expect(readIdleSeconds(() => Promise.reject(new Error("no ioreg")))).resolves.toBe(0);
  });
});
```

`test/scheduler.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { nextDelaySeconds } from "../src/scheduler.ts";

const polling = { activeSeconds: 120, idleSeconds: 300, idleAfterSeconds: 300, maxBackoffSeconds: 900 };

describe("nextDelaySeconds", () => {
  it("uses the active interval while the Owner is around", () => {
    expect(nextDelaySeconds({ idleSeconds: 10, failureStreak: 0, polling })).toBe(120);
  });

  it("switches to the idle interval at the idle threshold", () => {
    expect(nextDelaySeconds({ idleSeconds: 299, failureStreak: 0, polling })).toBe(120);
    expect(nextDelaySeconds({ idleSeconds: 300, failureStreak: 0, polling })).toBe(300);
  });

  it("doubles per consecutive failure up to the cap", () => {
    const delays = [1, 2, 3, 4].map((failureStreak) =>
      nextDelaySeconds({ idleSeconds: 0, failureStreak, polling }),
    );
    expect(delays).toEqual([240, 480, 900, 900]);
  });

  it("never goes below the base interval even if the cap is smaller", () => {
    expect(
      nextDelaySeconds({ idleSeconds: 999, failureStreak: 3, polling: { ...polling, maxBackoffSeconds: 200 } }),
    ).toBe(300);
  });
});
```

`test/daemon.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { runDaemon } from "../src/daemon.ts";
import { createLogger } from "../src/log.ts";
import type { PollStatus } from "../src/poller.ts";

const polling = { activeSeconds: 120, idleSeconds: 300, idleAfterSeconds: 300, maxBackoffSeconds: 900 };
const log = createLogger({ write: () => undefined });

async function run(options: {
  statuses: (PollStatus | "crash")[];
  idleSeconds?: number;
}): Promise<number[]> {
  const controller = new AbortController();
  const delays: number[] = [];
  let polls = 0;
  await runDaemon({
    poll: () => {
      const status = options.statuses[polls] ?? "ok";
      polls += 1;
      return status === "crash" ? Promise.reject(new Error("bug")) : Promise.resolve(status);
    },
    readIdleSeconds: () => Promise.resolve(options.idleSeconds ?? 0),
    polling,
    sleep: (ms) => {
      delays.push(ms / 1000);
      if (delays.length === options.statuses.length) controller.abort();
      return Promise.resolve();
    },
    log,
    signal: controller.signal,
  });
  return delays;
}

describe("runDaemon", () => {
  it("backs off while polls fail and recovers after a success", async () => {
    expect(await run({ statuses: ["ok", "failed", "failed", "ok"] })).toEqual([120, 240, 480, 120]);
  });

  it("polls less often while the Mac is idle", async () => {
    expect(await run({ statuses: ["ok"], idleSeconds: 600 })).toEqual([300]);
  });

  it("treats a crashing poll as a failure instead of dying", async () => {
    expect(await run({ statuses: ["crash", "ok"] })).toEqual([240, 120]);
  });
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `npx vitest run test/idle.test.ts test/scheduler.test.ts test/daemon.test.ts`
Expected: FAIL — cannot resolve the new modules.

- [ ] **Step 3: Write `src/idle.ts` and `src/scheduler.ts`**

`src/idle.ts`:

```ts
import { defaultExec } from "./exec.ts";
import type { Exec } from "./exec.ts";

const IOREG_TIMEOUT_MS = 5000;
const NANOSECONDS_PER_SECOND = 1e9;

export function parseIdleSeconds(ioregOutput: string): number | null {
  const raw = /"HIDIdleTime"\s*=\s*(\d+)/.exec(ioregOutput)?.[1];
  return raw === undefined ? null : Number(raw) / NANOSECONDS_PER_SECOND;
}

/** Seconds since the last keyboard or mouse input; 0 (active) when it cannot be read. */
export async function readIdleSeconds(exec: Exec = defaultExec): Promise<number> {
  try {
    const { stdout } = await exec("ioreg", ["-c", "IOHIDSystem"], { timeoutMs: IOREG_TIMEOUT_MS });
    return parseIdleSeconds(stdout) ?? 0;
  } catch {
    // Unknown idle time is treated as "active": poll at the faster interval rather than slow down.
    return 0;
  }
}
```

`src/scheduler.ts`:

```ts
import type { Config } from "./config.ts";

export interface DelayInput {
  readonly idleSeconds: number;
  readonly failureStreak: number;
  readonly polling: Config["polling"];
}

export function nextDelaySeconds(input: DelayInput): number {
  const { idleSeconds, failureStreak, polling } = input;
  const base = idleSeconds >= polling.idleAfterSeconds ? polling.idleSeconds : polling.activeSeconds;
  return Math.min(base * 2 ** failureStreak, Math.max(polling.maxBackoffSeconds, base));
}
```

- [ ] **Step 4: Write `src/daemon.ts`**

```ts
import type { Config } from "./config.ts";
import type { Logger } from "./log.ts";
import type { PollStatus } from "./poller.ts";
import { nextDelaySeconds } from "./scheduler.ts";

export interface DaemonDeps {
  readonly poll: () => Promise<PollStatus>;
  readonly readIdleSeconds: () => Promise<number>;
  readonly polling: Config["polling"];
  readonly sleep: (ms: number, signal: AbortSignal) => Promise<void>;
  readonly log: Logger;
  readonly signal: AbortSignal;
}

export function abortableSleep(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    if (signal.aborted) {
      resolve();
      return;
    }
    const finish = (): void => {
      clearTimeout(timer);
      signal.removeEventListener("abort", finish);
      resolve();
    };
    const timer = setTimeout(finish, ms);
    signal.addEventListener("abort", finish, { once: true });
  });
}

async function pollSafely(deps: DaemonDeps): Promise<PollStatus> {
  try {
    return await deps.poll();
  } catch (error) {
    deps.log.error("poll crashed", { reason: error instanceof Error ? error.name : "unknown" });
    return "failed";
  }
}

/**
 * Polls until aborted. After a full sleep the sleeping timer simply fires late, and the next poll
 * catches up from stored state, so no separate wake handling is needed.
 */
export async function runDaemon(deps: DaemonDeps): Promise<void> {
  let failureStreak = 0;
  while (!deps.signal.aborted) {
    failureStreak = (await pollSafely(deps)) === "failed" ? failureStreak + 1 : 0;
    const delaySeconds = nextDelaySeconds({
      idleSeconds: await deps.readIdleSeconds(),
      failureStreak,
      polling: deps.polling,
    });
    deps.log.debug("next poll scheduled", { delay_seconds: delaySeconds });
    await deps.sleep(delaySeconds * 1000, deps.signal);
  }
}
```

- [ ] **Step 5: Write the runtime, daemon entry point and CLI**

`src/runtime.ts`:

```ts
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

export interface Runtime {
  readonly config: Config;
  readonly store: Store;
  readonly log: Logger;
  poll(): Promise<PollStatus>;
}

export function createRuntime(configPath: string): Runtime {
  const log = createLogger();
  const config = loadConfig(configPath);
  const store = openStore(config.statePath ?? defaultStatePath());
  const run = glabRunner(config.gitlab);
  const deps: PollDeps = {
    fetchSnapshot: () => fetchSnapshot(run),
    store,
    notifier: createNotifier(),
    failures: createFailureTracker(),
    log,
    config,
  };
  return { config, store, log, poll: () => pollOnce(deps) };
}
```

`src/main.ts`:

```ts
import { defaultConfigPath } from "./config.ts";
import { abortableSleep, runDaemon } from "./daemon.ts";
import { readIdleSeconds } from "./idle.ts";
import { createLogger } from "./log.ts";
import { createRuntime } from "./runtime.ts";

async function main(): Promise<void> {
  const controller = new AbortController();
  process.once("SIGTERM", () => {
    controller.abort();
  });
  process.once("SIGINT", () => {
    controller.abort();
  });

  const runtime = createRuntime(defaultConfigPath());
  runtime.log.info("daemon started");
  try {
    await runDaemon({
      poll: () => runtime.poll(),
      readIdleSeconds: () => readIdleSeconds(),
      polling: runtime.config.polling,
      sleep: abortableSleep,
      log: runtime.log,
      signal: controller.signal,
    });
  } finally {
    runtime.store.close();
  }
  runtime.log.info("daemon stopped");
}

main().catch((error: unknown) => {
  // Startup failure (bad config, unwritable state): log once and exit non-zero so launchd throttles restarts.
  createLogger().error("startup failed", {
    reason: error instanceof Error ? error.message : "unknown",
  });
  process.exitCode = 1;
});
```

`src/cli.ts`:

```ts
import { defaultConfigPath } from "./config.ts";
import { createRuntime } from "./runtime.ts";

const USAGE = "usage: mra <once|status|pause|resume>\n";

async function main(argv: readonly string[]): Promise<number> {
  const command = argv[0];
  if (command !== "once" && command !== "status" && command !== "pause" && command !== "resume") {
    process.stderr.write(USAGE);
    return 2;
  }
  const runtime = createRuntime(defaultConfigPath());
  try {
    switch (command) {
      case "once": {
        const status = await runtime.poll();
        process.stdout.write(`poll: ${status}\n`);
        return status === "failed" ? 1 : 0;
      }
      case "status": {
        const state = runtime.store.load();
        process.stdout.write(
          [
            `paused: ${runtime.store.isPaused() ? "yes" : "no"}`,
            `baseline: ${state.baselineDone ? "done" : "pending"}`,
            `tracked authored MRs: ${state.trackedAuthored.size}`,
            `review-requested MRs known: ${state.myReviewStates.size}`,
          ].join("\n") + "\n",
        );
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

`scripts/mra`:

```sh
#!/bin/sh
exec node "$(dirname "$0")/../src/cli.ts" "$@"
```

Run `chmod +x scripts/mra`.

- [ ] **Step 6: Run the checks**

Run: `npx prettier --write . && npm run check`
Expected: all pass, 10 new tests green (idle 3, scheduler 4, daemon 3). `main.ts`, `cli.ts` and `runtime.ts` have no unit tests by design: they only wire tested parts together; the typecheck covers them and Task 9's manual smoke test exercises them.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: add idle-aware scheduling, daemon loop and the mra CLI"
```

---

### Task 9: LaunchAgent, README, CI and manual smoke test

**Files:**
- Create: `launchd/com.madhani.mr-review-assistant.plist.template`, `scripts/install-launchagent.sh`, `scripts/uninstall-launchagent.sh`, `README.md`
- Modify: add the standard pipeline via the `madhani-gitlab-ci` skill (creates `.gitlab-ci.yml`)

**Interfaces:**
- Consumes: the whole program.
- Produces: an installable LaunchAgent and the documented smoke-test procedure.

- [ ] **Step 1: Write the plist template**

`launchd/com.madhani.mr-review-assistant.plist.template`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.madhani.mr-review-assistant</string>
  <key>ProgramArguments</key>
  <array>
    <string>__NODE__</string>
    <string>__REPO__/src/main.ts</string>
  </array>
  <key>WorkingDirectory</key><string>__REPO__</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>__HOME__</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>MRA_ENV</key><string>production</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>__HOME__/Library/Logs/mr-review-assistant/stdout.log</string>
  <key>StandardErrorPath</key><string>__HOME__/Library/Logs/mr-review-assistant/stderr.log</string>
</dict>
</plist>
```

- [ ] **Step 2: Write the install and uninstall scripts**

`scripts/install-launchagent.sh`:

```sh
#!/bin/sh
# Renders the LaunchAgent for this checkout and starts it. Re-run after moving the repo or
# switching Node versions: the absolute node path is baked into the plist.
set -eu

LABEL=com.madhani.mr-review-assistant
REPO=$(cd "$(dirname "$0")/.." && pwd)
NODE=$(command -v node)
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/mr-review-assistant"
sed -e "s|__NODE__|$NODE|g" -e "s|__REPO__|$REPO|g" -e "s|__HOME__|$HOME|g" \
  "$REPO/launchd/$LABEL.plist.template" > "$PLIST"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"
echo "installed $PLIST (node: $NODE)"
```

`scripts/uninstall-launchagent.sh`:

```sh
#!/bin/sh
set -eu

LABEL=com.madhani.mr-review-assistant
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
echo "removed $LABEL"
```

Run `chmod +x scripts/install-launchagent.sh scripts/uninstall-launchagent.sh`.

- [ ] **Step 3: Write `README.md`**

Sections, in this order: what it is (two sentences, link to `CONTEXT.md` for vocabulary and to the spec); requirements (Node 24, `glab` logged in to `repo.madhani.one`, optional `terminal-notifier`); setup (`npm ci`; create `~/.config/mr-review-assistant/config.yaml` with `gitlab:\n  hostname: repo.madhani.one`; list every config key from `src/config.ts` with its default); commands (`scripts/mra once|status|pause|resume`); install/uninstall scripts and log location `~/Library/Logs/mr-review-assistant/` (launchd captures stdout; the app does no rotation; at the default settings the log grows only on events and errors); the smoke test below; development (`npm run check`); known limits (the two "Deliberate gaps" from the spec, polling stops while the Mac is fully asleep, `osascript` notifications cannot be clicked).

- [ ] **Step 4: Add CI**

Load the `madhani-gitlab-ci` skill and add the standard pipeline for a Node/TypeScript tooling repo (validate: typecheck, lint, format; test; no deploy). Do not hand-write the YAML. Push the branch and confirm the pipeline is green before opening the MR.

- [ ] **Step 5: Run the checks**

Run: `npx prettier --write . && npm run check`
Expected: all pass.

- [ ] **Step 6: Manual smoke test against the real GitLab (documented as manual, not E2E)**

Run before installing the LaunchAgent, so two processes never poll at once.

```bash
mkdir -p ~/.config/mr-review-assistant
printf 'gitlab:\n  hostname: repo.madhani.one\n' > ~/.config/mr-review-assistant/config.yaml
scripts/mra once
```

Expected: `poll: ok`, and one macOS notification "MR Review Assistant aktif — N MR menunggu review-mu" where N equals the number of non-draft MRs on GitLab where you are a Reviewer and still `UNREVIEWED`. If N is 0, no notification appears.

```bash
scripts/mra once
```

Expected: `poll: ok`, no notification (nothing changed).

```bash
scripts/mra status
```

Expected: `baseline: done` and non-zero `tracked authored MRs` if you have open non-draft MRs.

Simulate a re-request without involving anyone:

```bash
sqlite3 ~/Library/Application\ Support/mr-review-assistant/state.db "UPDATE my_review_state SET state = 'APPROVED'"
scripts/mra once
```

Expected: one notification per waiting MR (a single "N aktivitas MR baru" summary when N is more than 4); the notification title starts with "Diminta review:". Run `scripts/mra once` once more: no notification.

```bash
scripts/mra pause && scripts/mra once && scripts/mra resume
```

Expected: `poll: paused` in the middle.

Break `glab` on purpose: add `  glabPath: /nonexistent/glab` under `gitlab:` in the config, run `scripts/mra once` twice (each run is a separate process, so the once-per-failure rule is checked with the daemon below instead), then remove the line. Expected: `poll: failed` and a "glab tidak ditemukan" notification on each run. To see the once-per-kind behaviour, repeat this with the LaunchAgent installed (next step) and wait for two polls: only one notification appears.

Install and observe:

```bash
scripts/install-launchagent.sh
launchctl print "gui/$(id -u)/com.madhani.mr-review-assistant" | grep -E "state|pid"
sleep 5; cat ~/Library/Logs/mr-review-assistant/stdout.log
```

Expected: `state = running`, and a log line whose `message` is `daemon started`. Look at `stderr.log` after two minutes: it must be empty. If `terminal-notifier` is wanted, ask the Owner to confirm `brew install terminal-notifier` (a download) and re-run the re-request simulation; clicking the notification must open the MR.

- [ ] **Step 7: Commit and open the MR**

```bash
git add -A
git commit -m "feat: package as a LaunchAgent with documentation and CI"
```

Self-review the diff with `madhani-code-review`, push the branch, and open the MR titled `[no-ticket] feat: poll GitLab and alert on review requests and activity`, following `madhani-git-workflow` (body states that `no-ticket` is used because no planner task exists). If the branch has lived more than two days, split it into an MR for Tasks 1–5 and a second one for Tasks 6–9.

---

## What the next plans need from this one

- **Plan 2 (Teams: Reviewer Nudge and Review Notice)** adds new `ActivityEvent` kinds (`reviewer-added` on the Owner's MRs, `own-review-submitted` on others' MRs) next to the existing ones in `src/events.ts`, new tables via a schema version bump (`SCHEMA_VERSION = 2`) in `src/store.ts` (outbox/Pending Messages, sent-message ledger, identity cache), and new config keys under a `teams:` section in `src/config.ts` (the schema is `strict`, so keys must be added deliberately). It reuses `Exec`, `Logger`, `FailureTracker` (add a `teams-auth` kind) and the poll cycle's "deliver first, commit last" rule for Owner notifications — but Teams sends must instead record intent **before** sending (at most once).
- **Plan 3 (Agent Review)** extends `SNAPSHOT_QUERY` with `diffHeadSha`, reuses `review-requested` events as its trigger, and the `mra pause` kill switch (`Store.isPaused`).
- Both plans keep the Global Constraints above, and both need the Owner's explicit confirmation before anything is sent to Teams or posted to GitLab for the first time.
