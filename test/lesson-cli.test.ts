import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { LessonStore, NewOccurrence } from "../src/lesson-store.ts";
import { openLessonsReadOnly } from "../src/lesson-store.ts";
import { buildLessonList, buildLessonShow, mergeLessons } from "../src/lessons/owner.ts";
import { buildLessonUsage, fileUsageLog } from "../src/lessons/usage.ts";
import type { UsageEntry } from "../src/lessons/usage.ts";
import { openStore } from "../src/store.ts";

const NOW = Date.UTC(2026, 9, 26, 12);
const DAY = 86_400_000;
const SCOPE = "/work/acme";
const OTHER = "/work/beta";

function occurrence(
  sourceKey: string,
  mrKey: string,
  at: number,
  extra: Partial<NewOccurrence> = {},
): NewOccurrence {
  const iid = mrKey.slice(mrKey.lastIndexOf("!") + 1);
  const project = mrKey.slice(0, mrKey.lastIndexOf("!"));
  return {
    sourceKey,
    source: "review",
    mrKey,
    mrTitle: `MR ${iid}`,
    mrUrl: `https://gitlab.example/${project}/-/merge_requests/${iid}`,
    path: "src/client.go",
    line: 12,
    severity: "Major",
    title: "No timeout",
    text: "The client has no timeout.",
    outcome: "open",
    at,
    ...extra,
  };
}

function lesson(
  lessons: LessonStore,
  title: string,
  rows: readonly NewOccurrence[],
  scope = SCOPE,
  extra: { topics?: string[]; globs?: string[] } = {},
): number {
  const id = lessons.createLesson(
    {
      scope,
      title,
      rule: `${title}, because it keeps biting.`,
      topics: extra.topics ?? ["http-client", "go"],
      globs: extra.globs ?? ["**/*.go"],
    },
    1,
  );
  lessons.addOccurrences(rows);
  lessons.attach(
    rows.map((row) => lessons.occurrenceBySource(row.sourceKey)?.id ?? 0),
    id,
    1,
  );
  return id;
}

/**
 * The golden's data: two lessons of one scope, linked; one archived; one of another scope; one
 * pending; one pending from a repo under no scope, which can never be learned.
 */
function seed(lessons: LessonStore): {
  timeout: number;
  errors: number;
  archived: number;
  beta: number;
} {
  const timeout = lesson(lessons, "HTTP clients need an explicit timeout", [
    occurrence("review:1:1", "acme/api!3", NOW - 30 * DAY),
    occurrence("thread:acme/web!5:d1", "acme/web!5", NOW - 2 * DAY, {
      source: "thread",
      severity: "",
      path: "web/fetch.go",
      line: 40,
      outcome: "changed",
      text: "fetch() waits forever when the host stalls.",
    }),
    occurrence("review:2:1", "acme/api!4", NOW - 10 * DAY, { severity: "Blocker" }),
  ]);
  const errors = lesson(
    lessons,
    "Wrap errors with context",
    [occurrence("review:2:2", "acme/api!4", NOW - 10 * DAY, { severity: "Minor" })],
    SCOPE,
    { topics: ["errors"], globs: ["**/*.go"] },
  );
  const archived = lesson(lessons, "A wrong lesson", [
    occurrence("review:3:1", "acme/api!6", NOW - DAY),
  ]);
  lessons.archive(archived, 2);
  const beta = lesson(
    lessons,
    "Beta lesson",
    [occurrence("review:4:1", "beta/x!1", NOW - DAY)],
    OTHER,
  );
  lessons.link(timeout, errors);
  lessons.link(timeout, archived);
  lessons.link(timeout, beta);
  lessons.addOccurrences([
    occurrence("review:5:1", "acme/api!9", NOW),
    occurrence("review:6:1", "solo/elsewhere!2", NOW),
  ]);
  return { timeout, errors, archived, beta };
}

const SCAN = () => ({
  repos: [
    { scope: SCOPE, dir: `${SCOPE}/api`, project: "acme/api" },
    { scope: SCOPE, dir: `${SCOPE}/web`, project: "acme/web" },
    { scope: OTHER, dir: `${OTHER}/x`, project: "beta/x" },
  ],
});

let dir: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "suica-lesson-cli-"));
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

describe("the Lessons view documents", () => {
  it("lessons list and show match the golden", () => {
    const store = openStore(":memory:");
    const { timeout } = seed(store.lessons);
    const golden = JSON.parse(readFileSync("contracts/lessons.v1.json", "utf8")) as {
      list: unknown;
      show: unknown;
    };
    expect(
      buildLessonList(store.lessons, { enabled: true, scopes: [SCOPE, `${SCOPE}/`] }, SCAN, NOW),
    ).toEqual(golden.list);
    expect(buildLessonShow(store.lessons, timeout, NOW)).toEqual(golden.show);
  });

  it("lessons usage matches the golden", () => {
    const store = openStore(":memory:");
    const { timeout, errors, beta } = seed(store.lessons);
    const base = { source: "session" as const, tokens: 0 };
    const entries: UsageEntry[] = [
      {
        ...base,
        at: NOW - 3 * DAY,
        project: "acme/api",
        scope: SCOPE,
        sessionId: "s1",
        lessonIds: [timeout, errors],
        tokens: 120,
      },
      {
        ...base,
        at: NOW - 3 * DAY + 60_000,
        project: "acme/api",
        scope: SCOPE,
        source: "read",
        sessionId: "s1",
        file: "src/client.go",
        lessonIds: [timeout],
        tokens: 40,
      },
      {
        ...base,
        at: NOW - 2 * DAY,
        project: "acme/web",
        scope: SCOPE,
        source: "mcp",
        tool: "lessons_for_path",
        file: "web/fetch.go",
        lessonIds: [timeout],
        tokens: 30,
      },
      {
        ...base,
        at: NOW - DAY,
        project: null,
        scope: OTHER,
        sessionId: "s2",
        lessonIds: [beta, 999],
        tokens: 20,
      },
    ];
    const golden = JSON.parse(readFileSync("contracts/lessons.v1.json", "utf8")) as {
      usage: unknown;
    };
    expect(buildLessonUsage(entries, (id) => store.lessons.lesson(id)?.title, NOW)).toEqual(
      golden.usage,
    );
  });

  it("lists nothing, reading nothing, while lessons are off", () => {
    let scanned = false;
    expect(
      buildLessonList(
        undefined,
        { enabled: false, scopes: [SCOPE] },
        () => {
          scanned = true;
          return { repos: [] };
        },
        NOW,
      ),
    ).toEqual({ version: 1, enabled: false, scopes: [], pending: 0, unscoped: 0 });
    expect(scanned).toBe(false);
  });

  it("lists each scope with no lessons before any are stored", () => {
    expect(buildLessonList(undefined, { enabled: true, scopes: [SCOPE] }, SCAN, NOW)).toEqual({
      version: 1,
      enabled: true,
      scopes: [{ path: SCOPE, repos: 2, lessons: [] }],
      pending: 0,
      unscoped: 0,
    });
  });

  it("caps an occurrence's text at 1000 characters", () => {
    const store = openStore(":memory:");
    const id = lesson(store.lessons, "Long", [
      occurrence("review:1:1", "acme/api!1", NOW, { text: "x".repeat(1200) }),
    ]);
    const text = buildLessonShow(store.lessons, id, NOW)?.lesson.occurrences[0]?.text ?? "";
    expect(text).toHaveLength(1000);
    expect(text.endsWith("…")).toBe(true);
  });

  it("checks a merge inside the transaction that writes it", () => {
    const store = openStore(":memory:");
    const { timeout, errors } = seed(store.lessons);
    const events: string[] = [];
    let open = false;
    const wrapped = {
      transaction: (work: () => void) => {
        events.push("begin");
        open = true;
        try {
          store.lessons.transaction(work);
        } finally {
          open = false;
          events.push("end");
        }
      },
      lesson: (id: number) => {
        events.push(open ? "read-inside" : "read-outside");
        return store.lessons.lesson(id);
      },
      merge: (keep: number, gone: number, at: number) => {
        events.push(open ? "merge-inside" : "merge-outside");
        store.lessons.merge(keep, gone, at);
      },
    };
    expect(mergeLessons(wrapped, timeout, errors, NOW)).toEqual({ status: "merged" });
    expect(events).toEqual(["begin", "read-inside", "read-inside", "merge-inside", "end"]);
  });

  it("refuses a merge when either lesson is archived, and changes nothing", () => {
    const store = openStore(":memory:");
    const { timeout, archived } = seed(store.lessons);
    const before = () => [store.lessons.occurrences(timeout), store.lessons.occurrences(archived)];
    const was = before();
    expect(mergeLessons(store.lessons, timeout, archived, NOW)).toEqual({
      status: "bad-request",
      message: `lesson ${String(archived)} is archived`,
    });
    expect(mergeLessons(store.lessons, archived, timeout, NOW)).toEqual({
      status: "bad-request",
      message: `lesson ${String(archived)} is archived`,
    });
    expect(before()).toEqual(was);
    expect(store.lessons.lesson(archived)).toBeDefined();
  });

  it("shows nothing for an unknown id", () => {
    const store = openStore(":memory:");
    expect(buildLessonShow(store.lessons, 42, NOW)).toBeUndefined();
  });
});

describe("suica lessons list|show|archive|merge", () => {
  let configPath: string;
  let statePath: string;
  let vault: string;
  const run = (...args: string[]) => {
    const result = spawnSync(process.execPath, ["src/cli.ts", "lessons", ...args], {
      encoding: "utf8",
      env: { ...process.env, SUICA_CONFIG: configPath },
    });
    return {
      status: result.status,
      json: JSON.parse(result.stdout || "null") as Record<string, unknown> | null,
      stderr: result.stderr,
    };
  };
  const write = (lessons: string) => {
    writeFileSync(
      configPath,
      `gitlab:\n  hostname: gitlab.example\nstatePath: ${statePath}\nlessons:\n${lessons}`,
    );
  };
  let ids: ReturnType<typeof seed>;
  beforeEach(() => {
    configPath = join(dir, "config.yaml");
    statePath = join(dir, "state", "state.db");
    vault = join(dir, "vault");
    mkdirSync(join(dir, "state"));
    const store = openStore(statePath);
    ids = seed(store.lessons);
    store.close();
    // The scope map the daemon caches after each scan.
    writeFileSync(join(dir, "state", "lesson-scopes.json"), JSON.stringify(SCAN()));
    write(`  enabled: true\n  scopes: ["${SCOPE}", "${OTHER}"]\n`);
  });
  const titles = (json: Record<string, unknown> | null, path = SCOPE): string[] => {
    const scopes = (json?.["scopes"] ?? []) as { path: string; lessons: { title: string }[] }[];
    return scopes.find((s) => s.path === path)?.lessons.map((l) => l.title) ?? [];
  };

  it("lessons list matches the golden's shape, heaviest first, with the pending count", () => {
    const result = run("list", "--json");
    expect(result.status).toBe(0);
    expect(result.json).toMatchObject({ version: 1, enabled: true, pending: 1, unscoped: 1 });
    expect(titles(result.json)).toEqual([
      "HTTP clients need an explicit timeout",
      "Wrap errors with context",
    ]);
    expect(titles(result.json, OTHER)).toEqual(["Beta lesson"]);
    const scopes = result.json?.["scopes"] as { path: string; repos: number }[];
    expect(scopes.map((s) => [s.path, s.repos])).toEqual([
      [SCOPE, 2],
      [OTHER, 1],
    ]);
  }, 20_000);

  it("lessons usage reads the last 30 days of the log, with titles, even while lessons are off", () => {
    write(`  enabled: false\n  scopes: ["${SCOPE}"]\n`);
    const now = Date.now();
    const log = fileUsageLog(join(dir, "state", "lessons-usage"), now);
    const entry = (at: number, lessonIds: number[]): UsageEntry => ({
      at,
      project: "acme/api",
      scope: SCOPE,
      source: "session",
      lessonIds,
      tokens: 12,
    });
    log.append(entry(now - DAY, [ids.timeout, 999]));
    log.append(entry(now - 40 * DAY, [ids.errors]));
    const result = run("usage", "--json");
    expect(result.status).toBe(0);
    expect(result.json).toMatchObject({
      version: 1,
      days: 30,
      totals: { deliveries: 1, tokens: 12, lessons: 2 },
      projects: [
        {
          project: "acme/api",
          topLessons: [
            { id: ids.timeout, title: "HTTP clients need an explicit timeout", times: 1 },
            { id: 999, title: null, times: 1 },
          ],
        },
      ],
    });
  }, 20_000);

  it("lessons usage with no log is an empty document", () => {
    const result = run("usage", "--json");
    expect(result.status).toBe(0);
    expect(result.json).toMatchObject({
      version: 1,
      totals: { deliveries: 0, sessions: 0, tokens: 0, lessons: 0 },
      projects: [],
      recent: [],
    });
  }, 20_000);

  it("lessons list says off while lessons are disabled", () => {
    write(`  enabled: false\n  scopes: ["${SCOPE}"]\n`);
    const result = run("list", "--json");
    expect(result.status).toBe(0);
    expect(result.json).toEqual({
      version: 1,
      enabled: false,
      scopes: [],
      pending: 0,
      unscoped: 0,
    });
  }, 20_000);

  it("lessons show lists occurrences newest first, and not-found for an unknown id", () => {
    const result = run("show", String(ids.timeout), "--json");
    expect(result.status).toBe(0);
    const shown = result.json?.["lesson"] as { occurrences: { mrKey: string; text: string }[] };
    expect(shown.occurrences.map((o) => o.mrKey)).toEqual([
      "acme/web!5",
      "acme/api!4",
      "acme/api!3",
    ]);
    const missing = run("show", "999", "--json");
    expect(missing.status).toBe(1);
    expect(missing.json).toEqual({ version: 1, status: "not-found" });
  }, 20_000);

  it("archive hides a lesson from list and re-exports the vault", () => {
    write(`  enabled: true\n  scopes: ["${SCOPE}"]\n  vaultPath: ${vault}\n`);
    expect(run("export", "--json").status).toBe(0);
    const note = join(vault, "Lessons", `wrap-errors-with-context-${String(ids.errors)}.md`);
    expect(existsSync(note)).toBe(true);
    const result = run("archive", String(ids.errors), "--json");
    expect(result).toMatchObject({ status: 0, json: { version: 1, status: "archived" } });
    expect(titles(run("list", "--json").json)).toEqual(["HTTP clients need an explicit timeout"]);
    expect(existsSync(note)).toBe(false);
    expect(run("archive", "999", "--json")).toMatchObject({
      status: 1,
      json: { version: 1, status: "not-found" },
    });
  }, 20_000);

  it("merge moves the occurrences to the lesson kept", () => {
    const result = run("merge", String(ids.timeout), String(ids.errors), "--json");
    expect(result).toMatchObject({ status: 0, json: { version: 1, status: "merged" } });
    const reader = openLessonsReadOnly(statePath);
    expect(reader?.lesson(ids.errors)).toBeUndefined();
    expect(reader?.occurrences(ids.timeout)).toHaveLength(4);
    reader?.close();
  }, 20_000);

  it("merge of two scopes is a bad request and changes nothing", () => {
    const snapshot = () => {
      const reader = openLessonsReadOnly(statePath);
      const state = [SCOPE, OTHER].flatMap((scope) =>
        (reader?.lessons(scope) ?? []).map((l) => [
          l,
          reader?.occurrences(l.id),
          reader?.links(l.id),
        ]),
      );
      reader?.close();
      return state;
    };
    const before = snapshot();
    const result = run("merge", String(ids.timeout), String(ids.beta), "--json");
    expect(result.status).toBe(1);
    expect(result.json).toMatchObject({ version: 1, status: "bad-request" });
    expect(typeof result.json?.["message"]).toBe("string");
    expect(snapshot()).toEqual(before);
    const reader = openLessonsReadOnly(statePath);
    expect(reader?.lesson(ids.beta)?.scope).toBe(OTHER);
    expect(reader?.occurrences(ids.timeout)).toHaveLength(3);
    reader?.close();
    expect(run("merge", String(ids.timeout), String(ids.timeout), "--json")).toMatchObject({
      status: 1,
      json: { version: 1, status: "bad-request" },
    });
    expect(run("merge", String(ids.archived), String(ids.timeout), "--json")).toMatchObject({
      status: 1,
      json: {
        version: 1,
        status: "bad-request",
        message: `lesson ${String(ids.archived)} is archived`,
      },
    });
    expect(snapshot()).toEqual(before);
    expect(run("merge", String(ids.timeout), "999", "--json")).toMatchObject({
      status: 1,
      json: { version: 1, status: "not-found" },
    });
  }, 20_000);

  it("a vault that cannot be written does not fail the change", () => {
    writeFileSync(join(dir, "not-a-folder"), "");
    write(`  enabled: true\n  scopes: ["${SCOPE}"]\n  vaultPath: ${join(dir, "not-a-folder")}\n`);
    const result = run("archive", String(ids.errors), "--json");
    expect(result).toMatchObject({ status: 0, json: { version: 1, status: "archived" } });
    expect(result.stderr).toContain("vault");
  }, 20_000);
});
