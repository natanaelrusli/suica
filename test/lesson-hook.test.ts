import { spawn } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  rmSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { LessonReader, NewOccurrence } from "../src/lesson-store.ts";
import { openLessonsReadOnly } from "../src/lesson-store.ts";
import { answerHook, fileSeenStore, readScopeCache, shouldReadStdin } from "../src/lessons/hook.ts";
import type { HookDeps, SeenStore } from "../src/lessons/hook.ts";
import { scanScopes } from "../src/lessons/scopes.ts";
import type { ScopeMap } from "../src/lessons/scopes.ts";
import { openStore } from "../src/store.ts";

const NOW = Date.UTC(2026, 9, 26, 9);
const HOUR = 3_600_000;
const INTRO =
  "Lessons from past code reviews in this folder. More come per file as you read; ask the `suica-lessons` MCP server for others.";

let dir: string;
let scope: string;
let repo: string;
let statePath: string;
let map: ScopeMap;
const readers: LessonReader[] = [];

function occurrence(sourceKey: string, severity: string, iid: number): NewOccurrence {
  return {
    sourceKey,
    source: "review",
    mrKey: `g/app!${String(iid)}`,
    mrTitle: "MR",
    mrUrl: "https://gitlab.example.com/g/app/-/merge_requests/1",
    path: "src/a.go",
    line: 1,
    severity,
    title: "finding title must not leak",
    text: "FINDING TEXT MUST NOT LEAK",
    outcome: "open",
    at: NOW - HOUR,
  };
}

/** Seeds three lessons in `scope`: Go (heaviest), TypeScript, and one for src/new/. */
function seed(path: string, lessonScope: string): { go: number; ts: number; fresh: number } {
  const store = openStore(path);
  const { lessons } = store;
  const make = (title: string, rule: string, globs: string[], severities: string[]): number => {
    const id = lessons.createLesson({ scope: lessonScope, title, rule, topics: [], globs }, NOW);
    const keys = severities.map((_, i) => `review:${title}:${String(i)}`);
    lessons.addOccurrences(keys.map((k, i) => occurrence(k, severities[i] ?? "Minor", 7 + i)));
    lessons.attach(
      keys.map((k) => lessons.occurrenceBySource(k)?.id ?? 0),
      id,
      NOW,
    );
    return id;
  };
  const go = make("Close rows", "Always close sql rows.", ["**/*.go"], ["Blocker", "Blocker"]);
  const ts = make("Await promises", "Never float a promise.", ["**/*.ts"], ["Major"]);
  const fresh = make("New module", "Register new modules.", ["src/new/**"], ["Minor"]);
  store.close();
  return { go, ts, fresh };
}

function memorySeen(): SeenStore & { readonly data: Map<string, Set<number>> } {
  const data = new Map<string, Set<number>>();
  return {
    data,
    get: (id) => data.get(id) ?? new Set(),
    add: (id, ids) => {
      const set = data.get(id) ?? new Set<number>();
      for (const each of ids) set.add(each);
      data.set(id, set);
    },
    reset: (id) => {
      data.delete(id);
    },
  };
}

/** Adds one Major lesson in `lessonScope` matching every file. */
function addLesson(lessonScope: string, title: string): number {
  const store = openStore(statePath);
  const id = store.lessons.createLesson(
    { scope: lessonScope, title, rule: `${title} rule.`, topics: [], globs: ["**"] },
    NOW,
  );
  store.lessons.addOccurrences([occurrence(`review:${title}`, "Major", 9)]);
  store.lessons.attach([store.lessons.occurrenceBySource(`review:${title}`)?.id ?? 0], id, NOW);
  store.close();
  return id;
}

function start(cwd: string, extra: Record<string, unknown> = {}): Record<string, unknown> {
  return { hook_event_name: "SessionStart", session_id: "s1", cwd, ...extra };
}

function deps(extra: Partial<HookDeps> = {}): HookDeps {
  const reader = openLessonsReadOnly(statePath);
  if (reader) readers.push(reader);
  return {
    config: { enabled: true, scopes: [scope], perFile: 5, perSession: 5 },
    hostname: "gitlab.example.com",
    reader,
    seen: memorySeen(),
    now: NOW,
    scan: () => map,
    ...extra,
  };
}

function read(path: string, session = "s1"): Record<string, unknown> {
  return {
    hook_event_name: "PostToolUse",
    session_id: session,
    cwd: repo,
    tool_name: "Read",
    tool_input: { file_path: path },
  };
}

function context(answer: string): string {
  const parsed = JSON.parse(answer) as {
    hookSpecificOutput: { hookEventName: string; additionalContext: string };
  };
  return parsed.hookSpecificOutput.additionalContext;
}

/** Every answer must only ever add context: never a decision of any kind. */
function expectOnlyContext(answer: string, event: string): void {
  if (answer === "") return;
  const parsed = JSON.parse(answer) as Record<string, unknown>;
  expect(Object.keys(parsed)).toEqual(["hookSpecificOutput"]);
  const inner = parsed["hookSpecificOutput"] as Record<string, unknown>;
  expect(Object.keys(inner).sort()).toEqual(["additionalContext", "hookEventName"]);
  expect(inner["hookEventName"]).toBe(event);
  expect(answer).not.toContain("permissionDecision");
  expect(answer).not.toContain('"decision"');
  expect(answer).not.toMatch(/"(deny|ask|block|allow)"/);
}

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "suica-lesson-hook-"));
  scope = join(dir, "work");
  repo = join(scope, "app");
  statePath = join(dir, "state", "state.db");
  map = { repos: [{ scope, dir: repo, project: "g/app" }] };
});
afterEach(() => {
  for (const reader of readers.splice(0)) reader.close();
  rmSync(dir, { recursive: true, force: true });
});

describe("answerHook", () => {
  it("SessionStart in a scope gives the heaviest lessons with the intro line", () => {
    seed(statePath, scope);
    const answer = answerHook(
      { hook_event_name: "SessionStart", session_id: "s1", cwd: join(repo, "src") },
      deps({ config: { enabled: true, scopes: [scope], perFile: 5, perSession: 2 } }),
    );
    expectOnlyContext(answer, "SessionStart");
    expect(context(answer)).toBe(
      [
        INTRO,
        "- Close rows: Always close sql rows. (flagged 2 times, last in g/app !8)",
        "- Await promises: Never float a promise. (flagged 1 time, last in g/app !7)",
      ].join("\n"),
    );
    expect(answer).not.toContain("LEAK");
  });

  it("Read of a matching file gives its lessons", () => {
    seed(statePath, scope);
    const answer = answerHook(read(join(repo, "src", "db", "rows.go")), deps());
    expectOnlyContext(answer, "PostToolUse");
    const text = context(answer);
    expect(text).toContain("- Close rows: Always close sql rows.");
    expect(text).not.toContain("Await promises");
    expect(text).not.toContain("LEAK");
  });

  it("Edit of a new file gives its lessons, as do Write and MultiEdit", () => {
    seed(statePath, scope);
    for (const tool of ["Edit", "Write", "MultiEdit"]) {
      const answer = answerHook(
        {
          hook_event_name: "PreToolUse",
          session_id: "s1",
          cwd: repo,
          tool_name: tool,
          tool_input: { file_path: join(repo, "src", "new", "thing.md") },
        },
        deps(),
      );
      expectOnlyContext(answer, "PreToolUse");
      expect(context(answer)).toContain("- New module: Register new modules.");
    }
  });

  it("other tools and events give nothing", () => {
    seed(statePath, scope);
    const path = join(repo, "src", "a.go");
    const cases = [
      { ...read(path), tool_name: "Bash" },
      { ...read(path), hook_event_name: "PreToolUse" },
      { ...read(path), hook_event_name: "PostToolUse", tool_name: "Edit" },
      { ...read(path), hook_event_name: "Stop" },
    ];
    for (const input of cases) expect(answerHook(input, deps())).toBe("");
  });

  it("a lesson already shown in the session is not shown again", () => {
    const { go } = seed(statePath, scope);
    const shared = deps();
    const path = join(repo, "src", "a.go");
    expect(answerHook(read(path), shared)).not.toBe("");
    expect(answerHook(read(path), shared)).toBe("");
    expect(answerHook(read(join(repo, "b.go")), shared)).toBe("");
    expect([...shared.seen.get("s1")]).toEqual([go]);
    expect(answerHook(read(path, "s2"), shared)).not.toBe("");
  });

  it("SessionStart then Read in one session does not repeat a lesson", () => {
    const { go, ts, fresh } = seed(statePath, scope);
    const shared = deps({ config: { enabled: true, scopes: [scope], perFile: 5, perSession: 2 } });
    const start = { hook_event_name: "SessionStart", session_id: "s1", cwd: repo };
    expect(context(answerHook(start, shared))).toContain("Close rows");
    expect(answerHook(read(join(repo, "a.go")), shared)).toBe("");
    expect(answerHook(read(join(repo, "a.ts")), shared)).toBe("");
    const text = context(answerHook(read(join(repo, "src", "new", "x.go")), shared));
    expect(text).toContain("New module");
    expect(text).not.toContain("Close rows");
    expect([...shared.seen.get("s1")].sort()).toEqual([go, ts, fresh].sort());
  });

  it("a relative path is resolved against cwd", () => {
    seed(statePath, scope);
    const input = { ...read("src/a.go"), cwd: repo };
    expect(context(answerHook(input, deps()))).toContain("Close rows");
    expect(answerHook({ ...read("src/a.go"), cwd: "relative/dir" }, deps())).toBe("");
  });

  it("a path escaping the repo with .. gives nothing", () => {
    seed(statePath, scope);
    expect(answerHook(read(join(repo, "..", "elsewhere", "a.go")), deps())).toBe("");
    expect(answerHook({ ...read("../../a.go"), cwd: repo }, deps())).toBe("");
    expect(answerHook(read(`${repo}/../../a.go`), deps())).toBe("");
  });

  it("SessionStart in a scope folder outside every repo gives the scope's lessons", () => {
    seed(statePath, scope);
    mkdirSync(join(scope, "notes"), { recursive: true });
    for (const cwd of [scope, join(scope, "notes"), `${scope}/`]) {
      const answer = answerHook(start(cwd), deps());
      expectOnlyContext(answer, "SessionStart");
      expect(context(answer).split("\n")[0]).toBe(INTRO);
      expect(context(answer)).toContain("Close rows");
    }
    expect(answerHook(start(`${scope}-other`), deps())).toBe("");
    expect(answerHook(start(dir), deps())).toBe("");
    // File events still need a repo.
    expect(answerHook(read(join(scope, "notes", "a.go")), deps())).toBe("");
  });

  it("SessionStart picks the deepest scope, and a repo's own scope wins", () => {
    const inner = join(scope, "team");
    addLesson(scope, "Outer");
    addLesson(inner, "Inner");
    const config = { enabled: true, scopes: [scope, inner], perFile: 5, perSession: 5 };
    const inTeam = context(answerHook(start(join(inner, "docs")), deps({ config })));
    expect(inTeam).toContain("Inner");
    expect(inTeam).not.toContain("Outer");
    const atTop = context(answerHook(start(scope), deps({ config })));
    expect(atTop).toContain("Outer");
    expect(atTop).not.toContain("Inner");
    // A repo of the inner scope, inside the outer folder: its scope is the inner one.
    const svc = { repos: [{ scope: inner, dir: join(inner, "svc"), project: "g/svc" }] };
    const inRepo = context(
      answerHook(start(join(inner, "svc", "src")), deps({ config, scan: () => svc })),
    );
    expect(inRepo).toContain("Inner");
    expect(inRepo).not.toContain("Outer");
  });

  it("SessionStart after compaction or clear shows lessons again; resume does not", () => {
    seed(statePath, scope);
    const shared = deps();
    expect(answerHook(start(repo), shared)).not.toBe("");
    expect(answerHook(start(repo, { source: "resume" }), shared)).toBe("");
    expect(answerHook(start(repo, { source: "startup" }), shared)).toBe("");
    expect(context(answerHook(start(repo, { source: "compact" }), shared))).toContain("Close rows");
    expect(answerHook(read(join(repo, "a.go")), shared)).toBe("");
    expect(context(answerHook(start(repo, { source: "clear" }), shared))).toContain("Close rows");
  });

  it("a file outside every scope gives nothing", () => {
    seed(statePath, scope);
    expect(answerHook(read(join(dir, "other", "a.go")), deps())).toBe("");
    const start = { hook_event_name: "SessionStart", session_id: "s1", cwd: join(dir, "other") };
    expect(answerHook(start, deps())).toBe("");
  });

  it("a repo without a GitLab origin gives no file lessons", () => {
    seed(statePath, scope);
    const other = join(scope, "mirror");
    mkdirSync(join(other, ".git"), { recursive: true });
    writeFileSync(
      join(other, ".git", "config"),
      '[remote "origin"]\n\turl = git@github.com:g/mirror.git\n',
    );
    const scan = (): ScopeMap => scanScopes([scope], "gitlab.example.com");
    expect(answerHook(read(join(other, "a.go")), deps({ scan }))).toBe("");
    // Outside the scope folder it gets nothing at all; inside it, a session start is served as a
    // folder of the scope.
    const outside = join(dir, "mirror");
    mkdirSync(join(outside, ".git"), { recursive: true });
    expect(answerHook(start(outside), deps({ scan }))).toBe("");
    expect(context(answerHook(start(other), deps({ scan })))).toContain("Close rows");
  });

  it("no database gives nothing", () => {
    expect(answerHook(read(join(repo, "a.go")), deps({ reader: undefined }))).toBe("");
  });

  it("a database from before the lessons tables gives nothing", () => {
    mkdirSync(join(dir, "state"), { recursive: true });
    const db = new DatabaseSync(statePath);
    db.exec("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)");
    db.close();
    expect(openLessonsReadOnly(statePath)).toBeUndefined();
    rmSync(statePath);
    seed(statePath, scope);
    const real = openLessonsReadOnly(statePath);
    if (!real) throw new Error("seeded database did not open");
    readers.push(real);
    const throwing: LessonReader = {
      ...real,
      lessons: () => {
        throw new Error("no such table: lesson");
      },
    };
    expect(answerHook(read(join(repo, "a.go")), deps({ reader: throwing }))).toBe("");
  });

  it("disabled lessons give nothing and touch nothing", () => {
    const untouched = (): never => {
      throw new Error("must not be called");
    };
    const answer = answerHook(read(join(repo, "a.go")), {
      config: { enabled: false, scopes: [scope], perFile: 5, perSession: 5 },
      hostname: "gitlab.example.com",
      reader: undefined,
      seen: { get: untouched, add: untouched, reset: untouched },
      now: NOW,
      scan: untouched,
    });
    expect(answer).toBe("");
  });

  it("garbage input gives nothing", () => {
    seed(statePath, scope);
    const garbage: unknown[] = [
      null,
      undefined,
      "text",
      42,
      [],
      {},
      { hook_event_name: "PostToolUse" },
      { ...read(join(repo, "a.go")), session_id: 5 },
      { ...read(join(repo, "a.go")), cwd: null },
      { ...read(join(repo, "a.go")), tool_input: "a.go" },
      { ...read(join(repo, "a.go")), tool_input: { file_path: 3 } },
      { ...read(join(repo, "a.go")), tool_input: { file_path: "" } },
      { ...read(`${join(repo, "a.go")}\0x`) },
      { hook_event_name: "SessionStart", session_id: "s1" },
    ];
    for (const input of garbage) expect(answerHook(input, deps())).toBe("");
  });

  it("the answer never contains a permission decision", () => {
    seed(statePath, scope);
    const events = [
      { hook_event_name: "SessionStart", session_id: "s1", cwd: repo },
      read(join(repo, "a.go"), "s2"),
      {
        hook_event_name: "PreToolUse",
        session_id: "s3",
        cwd: repo,
        tool_name: "Write",
        tool_input: { file_path: join(repo, "a.ts") },
      },
    ];
    for (const input of events) {
      const answer = answerHook(input, deps());
      expect(answer).not.toBe("");
      expectOnlyContext(answer, String(input.hook_event_name));
    }
  });
});

describe("fileSeenStore", () => {
  it("remembers shown lessons across instances", () => {
    const seenDir = join(dir, "lessons-seen");
    fileSeenStore(seenDir, NOW).add("abc-123", [3, 1]);
    fileSeenStore(seenDir, NOW).add("abc-123", [2, 3]);
    expect([...fileSeenStore(seenDir, NOW).get("abc-123")].sort()).toEqual([1, 2, 3]);
    expect(readdirSync(seenDir)).toEqual(["abc-123.json"]);
  });

  it("an odd session id is not used as a file name", () => {
    const seenDir = join(dir, "state", "lessons-seen");
    for (const id of ["../escape", "a/b", "", "x".repeat(101), "a.b", "~"]) {
      const store = fileSeenStore(seenDir, NOW);
      store.add(id, [1]);
      expect(store.get(id).size).toBe(0);
    }
    expect(existsSync(seenDir) ? readdirSync(seenDir) : []).toEqual([]);
    expect(existsSync(join(dir, "state", "escape.json"))).toBe(false);
  });

  it("reset forgets a session", () => {
    const seenDir = join(dir, "lessons-seen");
    fileSeenStore(seenDir, NOW).add("s1", [1]);
    fileSeenStore(seenDir, NOW).add("s2", [2]);
    fileSeenStore(seenDir, NOW).reset("s1");
    expect(fileSeenStore(seenDir, NOW).get("s1").size).toBe(0);
    expect([...fileSeenStore(seenDir, NOW).get("s2")]).toEqual([2]);
    expect(() => {
      fileSeenStore(seenDir, NOW).reset("../s2");
    }).not.toThrow();
    expect([...fileSeenStore(seenDir, NOW).get("s2")]).toEqual([2]);
  });

  it("removes session files older than a day when opened", () => {
    const seenDir = join(dir, "lessons-seen");
    mkdirSync(seenDir);
    writeFileSync(join(seenDir, "old.json"), "[1]");
    writeFileSync(join(seenDir, "new.json"), "[2]");
    const old = new Date(Date.now() - 25 * HOUR);
    utimesSync(join(seenDir, "old.json"), old, old);
    fileSeenStore(seenDir, Date.now());
    expect(readdirSync(seenDir)).toEqual(["new.json"]);
  });

  it("an unreadable or unwritable store is ignored", () => {
    const seenDir = join(dir, "lessons-seen");
    mkdirSync(seenDir);
    writeFileSync(join(seenDir, "s1.json"), "{not json");
    const store = fileSeenStore(seenDir, NOW);
    expect(store.get("s1").size).toBe(0);
    const blocked = join(dir, "file-not-dir");
    writeFileSync(blocked, "");
    expect(() => {
      fileSeenStore(blocked, NOW).add("s1", [1]);
    }).not.toThrow();
  });
});

describe("shouldReadStdin", () => {
  it("does not wait on a terminal", () => {
    expect(shouldReadStdin({ isTTY: true })).toBe(false);
    expect(shouldReadStdin({ isTTY: false })).toBe(true);
    expect(shouldReadStdin({})).toBe(true);
  });
});

describe("readScopeCache", () => {
  it("reads the map the daemon writes, keeping only configured scopes", () => {
    const path = join(dir, "lesson-scopes.json");
    const gone = { scope: join(dir, "gone"), dir: join(dir, "gone", "x"), project: "g/x" };
    writeFileSync(path, JSON.stringify({ repos: [...map.repos, gone] }));
    expect(readScopeCache(path, [scope])).toEqual(map);
  });

  it("a missing or malformed cache reads as nothing", () => {
    const path = join(dir, "lesson-scopes.json");
    expect(readScopeCache(path, [scope])).toBeUndefined();
    for (const text of ["{", "[]", '{"repos":3}', '{"repos":[{"scope":1}]}', "null"]) {
      writeFileSync(path, text);
      expect(readScopeCache(path, [scope])).toBeUndefined();
    }
  });
});

describe("the hook script", () => {
  let configPath: string;

  function writeRepo(): void {
    mkdirSync(join(repo, ".git"), { recursive: true });
    writeFileSync(
      join(repo, ".git", "config"),
      '[remote "origin"]\n\turl = git@gitlab.example.com:g/app.git\n',
    );
  }

  function writeConfig(enabled = true): void {
    configPath = join(dir, "config.yaml");
    writeFileSync(
      configPath,
      [
        "gitlab:",
        "  hostname: gitlab.example.com",
        `statePath: ${statePath}`,
        "lessons:",
        `  enabled: ${String(enabled)}`,
        "  scopes:",
        `    - ${scope}`,
        "",
      ].join("\n"),
    );
  }

  function runHook(
    stdin: string | Buffer,
  ): Promise<{ code: number | null; stdout: string; ms: number }> {
    return new Promise((done, fail) => {
      const started = performance.now();
      const child = spawn("node", ["src/lessons-hook.ts"], {
        env: { ...process.env, SUICA_CONFIG: configPath },
        stdio: ["pipe", "pipe", "pipe"],
      });
      let stdout = "";
      child.stdout.setEncoding("utf8");
      child.stdout.on("data", (chunk: string) => {
        stdout += chunk;
      });
      child.stdin.on("error", () => undefined);
      child.on("error", fail);
      child.on("close", (code) => {
        done({ code, stdout, ms: performance.now() - started });
      });
      child.stdin.end(stdin);
    });
  }

  it("the hook script answers within 1 second on a seeded database while another connection holds a write transaction", async () => {
    writeRepo();
    seed(statePath, scope);
    writeConfig();
    writeFileSync(join(dirname(statePath), "lesson-scopes.json"), JSON.stringify(map));
    const writer = new DatabaseSync(statePath, { timeout: 5000 });
    writer.exec("BEGIN IMMEDIATE");
    writer.exec("INSERT INTO meta (key, value) VALUES ('hook-test', 'x')");
    try {
      const result = await runHook(JSON.stringify(read(join(repo, "src", "a.go"))));
      expect(result.code).toBe(0);
      expectOnlyContext(result.stdout, "PostToolUse");
      expect(context(result.stdout)).toContain("Close rows");
      expect(result.ms).toBeLessThan(1000);
      // The session memory reached the state folder.
      expect(readdirSync(join(dirname(statePath), "lessons-seen"))).toEqual(["s1.json"]);
      const again = await runHook(JSON.stringify(read(join(repo, "src", "a.go"))));
      expect(again).toMatchObject({ code: 0, stdout: "" });
    } finally {
      writer.exec("ROLLBACK");
      writer.close();
    }
  }, 20_000);

  it("scans the scopes when the daemon's scope cache is missing", async () => {
    writeRepo();
    seed(statePath, scope);
    writeConfig();
    const start = { hook_event_name: "SessionStart", session_id: "s9", cwd: repo };
    const result = await runHook(JSON.stringify(start));
    expect(result.code).toBe(0);
    expect(context(result.stdout).split("\n")[0]).toBe(INTRO);
  }, 20_000);

  it("garbage, oversized stdin and disabled lessons print nothing and exit 0", async () => {
    writeRepo();
    seed(statePath, scope);
    writeConfig();
    writeFileSync(join(dirname(statePath), "lesson-scopes.json"), JSON.stringify(map));
    const valid = read(join(repo, "a.go"));
    expect(await runHook("{not json")).toMatchObject({ code: 0, stdout: "" });
    expect(await runHook("")).toMatchObject({ code: 0, stdout: "" });
    const padded = JSON.stringify({ ...valid, padding: "x".repeat(2_000_000) });
    expect(await runHook(padded)).toMatchObject({ code: 0, stdout: "" });
    writeConfig(false);
    expect(await runHook(JSON.stringify(valid))).toMatchObject({ code: 0, stdout: "" });
    configPath = join(dir, "missing.yaml");
    expect(await runHook(JSON.stringify(valid))).toMatchObject({ code: 0, stdout: "" });
  }, 20_000);
});
