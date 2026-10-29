import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { buildLessonUsage, estimateTokens, fileUsageLog, readUsage } from "../src/lessons/usage.ts";
import type { UsageEntry } from "../src/lessons/usage.ts";

const DAY = 86_400_000;
const NOW = Date.UTC(2026, 9, 29, 9);

let tmp: string;
let dir: string;

beforeEach(() => {
  tmp = mkdtempSync(join(tmpdir(), "suica-usage-"));
  dir = join(tmp, "lessons-usage");
});
afterEach(() => {
  rmSync(tmp, { recursive: true, force: true });
});

function entry(at: number, extra: Partial<UsageEntry> = {}): UsageEntry {
  return {
    at,
    project: "g/app",
    scope: "/s",
    source: "session",
    lessonIds: [1, 2],
    tokens: 10,
    ...extra,
  };
}

describe("estimateTokens", () => {
  it("is the characters over four, rounded up", () => {
    expect(estimateTokens("")).toBe(0);
    expect(estimateTokens("abcd")).toBe(1);
    expect(estimateTokens("abcde")).toBe(2);
  });
});

describe("the usage log", () => {
  it("appends one line per entry to the UTC day file", () => {
    const first = entry(Date.UTC(2026, 9, 29, 23, 30));
    const second = entry(Date.UTC(2026, 9, 30, 0, 30), { source: "read", file: "src/a.go" });
    const log = fileUsageLog(dir, NOW);
    log.append(first);
    log.append(second);
    expect(readdirSync(dir).sort()).toEqual(["2026-10-29.jsonl", "2026-10-30.jsonl"]);
    for (const name of readdirSync(dir)) {
      expect(readFileSync(join(dir, name), "utf8").trimEnd().split("\n")).toHaveLength(1);
      expect(statSync(join(dir, name)).mode & 0o777).toBe(0o600);
    }
    expect(statSync(dir).mode & 0o777).toBe(0o700);
    expect(readUsage(dir, 0)).toEqual([first, second]);
  });

  it("skips malformed lines", () => {
    mkdirSync(dir);
    const good = entry(NOW);
    writeFileSync(
      join(dir, "2026-10-29.jsonl"),
      [
        JSON.stringify(good),
        '{"at":1,',
        "null",
        JSON.stringify({ ...good, lessonIds: undefined }),
        JSON.stringify({ ...good, source: "other" }),
        JSON.stringify({ ...good, lessonIds: [1.5] }),
      ].join("\n") + "\n",
    );
    expect(readUsage(dir, 0)).toEqual([good]);
  });

  it("drops entries before since", () => {
    mkdirSync(dir);
    const old = entry(NOW - 31 * DAY);
    const recent = entry(NOW - DAY);
    writeFileSync(
      join(dir, "2026-10-29.jsonl"),
      `${JSON.stringify(old)}\n${JSON.stringify(recent)}\n`,
    );
    expect(readUsage(dir, NOW - 30 * DAY)).toEqual([recent]);
  });

  it("prunes day files older than USAGE_DAYS on open", () => {
    mkdirSync(dir);
    for (const name of ["2026-09-01.jsonl", "2026-10-28.jsonl", "notes.txt"]) {
      writeFileSync(join(dir, name), "");
    }
    fileUsageLog(dir, Date.UTC(2026, 9, 29));
    expect(readdirSync(dir).sort()).toEqual(["2026-10-28.jsonl", "notes.txt"]);
  });

  it("never throws", () => {
    writeFileSync(dir, "");
    expect(() => fileUsageLog(dir, NOW).append(entry(NOW))).not.toThrow();
    expect(readUsage(dir, 0)).toEqual([]);
    expect(readUsage(join(tmp, "missing"), 0)).toEqual([]);
    expect(existsSync(join(tmp, "missing"))).toBe(false);
  });
});

describe("buildLessonUsage", () => {
  const titles = new Map([
    [1, "Close rows"],
    [2, "Await promises"],
  ]);
  const titleOf = (id: number): string | undefined => titles.get(id);
  const list: UsageEntry[] = [
    entry(NOW - 4 * DAY, { sessionId: "s1", lessonIds: [1, 2], tokens: 40 }),
    entry(NOW - 3 * DAY, {
      sessionId: "s1",
      source: "read",
      file: "a.go",
      lessonIds: [1],
      tokens: 10,
    }),
    entry(NOW - 2 * DAY, { source: "mcp", tool: "get_lesson", lessonIds: [1], tokens: 5 }),
    entry(NOW - DAY, { project: null, scope: "/s", lessonIds: [3], tokens: 20 }),
  ];

  it("totals, groups per project, and keeps a null-project scope as its own row", () => {
    const usage = buildLessonUsage(list, titleOf, NOW);
    expect(usage.version).toBe(1);
    expect(usage.generatedAt).toBe(NOW);
    expect(usage.days).toBe(30);
    expect(usage.totals).toEqual({ deliveries: 4, sessions: 1, tokens: 75, lessons: 3 });
    expect(usage.projects).toHaveLength(2);
    expect(usage.projects[0]).toEqual({
      project: "g/app",
      scope: "/s",
      deliveries: 3,
      sessions: 1,
      tokens: 55,
      lessons: 2,
      bySource: { session: 1, read: 1, edit: 0, mcp: 1 },
      lastAt: NOW - 2 * DAY,
      topLessons: [
        { id: 1, title: "Close rows", times: 3 },
        { id: 2, title: "Await promises", times: 1 },
      ],
    });
    expect(usage.projects[1]).toEqual({
      project: null,
      scope: "/s",
      deliveries: 1,
      sessions: 0,
      tokens: 20,
      lessons: 1,
      bySource: { session: 1, read: 0, edit: 0, mcp: 0 },
      lastAt: NOW - DAY,
      topLessons: [{ id: 3, title: null, times: 1 }],
    });
  });

  it("lists the newest 100 entries first", () => {
    expect(buildLessonUsage(list, titleOf, NOW).recent.map((e) => e.at)).toEqual(
      [...list].reverse().map((e) => e.at),
    );
    const many = Array.from({ length: 101 }, (_, i) => entry(NOW - i * 1000));
    const recent = buildLessonUsage(many, titleOf, NOW).recent;
    expect(recent).toHaveLength(100);
    expect(recent[0]?.at).toBe(NOW);
  });

  it("orders projects by tokens then name, and the top Lessons by times then id", () => {
    const usage = buildLessonUsage(
      [
        entry(NOW, { project: "b/x", lessonIds: [5, 4], tokens: 7 }),
        entry(NOW, { project: "a/x", lessonIds: [9], tokens: 7 }),
        entry(NOW, { project: "c/x", lessonIds: [1], tokens: 8 }),
      ],
      titleOf,
      NOW,
    );
    expect(usage.projects.map((p) => p.project)).toEqual(["c/x", "a/x", "b/x"]);
    expect(usage.projects[2]?.topLessons.map((l) => l.id)).toEqual([4, 5]);
  });

  it("keeps at most 20 top Lessons", () => {
    const ids = Array.from({ length: 25 }, (_, i) => i + 1);
    const usage = buildLessonUsage([entry(NOW, { lessonIds: ids })], titleOf, NOW);
    expect(usage.projects[0]?.lessons).toBe(25);
    expect(usage.projects[0]?.topLessons).toHaveLength(20);
  });

  it("is empty for no entries", () => {
    expect(buildLessonUsage([], titleOf, NOW)).toEqual({
      version: 1,
      generatedAt: NOW,
      days: 30,
      totals: { deliveries: 0, sessions: 0, tokens: 0, lessons: 0 },
      projects: [],
      recent: [],
    });
  });
});
