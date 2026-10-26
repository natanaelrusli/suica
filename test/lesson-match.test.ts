import { describe, expect, it } from "vitest";
import type { LessonRow, OccurrenceRow } from "../src/lesson-store.ts";
import { lessonsForFile, rankLessons, renderLessons, weight } from "../src/lessons/match.ts";
import type { RankedLesson } from "../src/lessons/match.ts";

const NOW = Date.UTC(2026, 9, 26, 9);
const DAY = 86_400_000;

function lesson(id: number, extra: Partial<LessonRow> = {}): LessonRow {
  return {
    id,
    scope: "/work",
    title: `Lesson ${id}`,
    rule: `Rule ${id}`,
    topics: [],
    globs: ["**/*.go"],
    archived: false,
    createdAt: NOW,
    updatedAt: NOW,
    ...extra,
  };
}

function occ(id: number, lessonId: number, extra: Partial<OccurrenceRow> = {}): OccurrenceRow {
  return {
    sourceKey: `review:${id}:1`,
    source: "review",
    mrKey: "g/p!1",
    mrTitle: "T",
    mrUrl: "u",
    repoPath: null,
    path: null,
    line: null,
    severity: "Major",
    title: "t",
    text: "t",
    outcome: "open",
    at: NOW,
    id,
    lessonId,
    failures: 0,
    retryAt: null,
    ...extra,
  };
}

function reader(lessons: LessonRow[], occurrences: OccurrenceRow[]) {
  return {
    lessons: (scope: string) => lessons.filter((l) => l.scope === scope),
    occurrences: (id: number) => occurrences.filter((o) => o.lessonId === id),
  };
}

function ranked(l: LessonRow, extra: Partial<RankedLesson> = {}): RankedLesson {
  return {
    lesson: l,
    weight: 1,
    count: 1,
    repos: ["g/p"],
    last: { mrKey: "g/p!7", at: NOW },
    ...extra,
  };
}

describe("weight", () => {
  it("a Blocker weighs more than a Nit of the same age", () => {
    expect(weight([{ severity: "Blocker", at: NOW }], NOW)).toBeGreaterThan(
      weight([{ severity: "Nit", at: NOW }], NOW),
    );
  });
  it("uses the pinned factors", () => {
    const w = (severity: string) => weight([{ severity, at: NOW }], NOW);
    expect([w("Blocker"), w("Major"), w("Minor"), w("Nit"), w("Whatever")]).toEqual([
      4, 3, 1.5, 1, 1,
    ]);
  });
  it("a recent occurrence weighs more than an old one", () => {
    expect(weight([{ severity: "Major", at: NOW }], NOW)).toBeGreaterThan(
      weight([{ severity: "Major", at: NOW - 200 * DAY }], NOW),
    );
  });
  it("halves every 90 days and sums occurrences", () => {
    expect(weight([{ severity: "Major", at: NOW - 90 * DAY }], NOW)).toBeCloseTo(1.5);
    expect(
      weight(
        [
          { severity: "Major", at: NOW },
          { severity: "Nit", at: NOW },
        ],
        NOW,
      ),
    ).toBe(4);
  });
  it("counts an occurrence in the future as age 0", () => {
    expect(weight([{ severity: "Blocker", at: NOW + 30 * DAY }], NOW)).toBe(4);
  });
});

describe("rankLessons", () => {
  it("does not rank archived lessons", () => {
    const r = rankLessons(
      reader([lesson(1), lesson(2, { archived: true })], [occ(1, 1), occ(2, 2)]),
      "/work",
      NOW,
    );
    expect(r.map((x) => x.lesson.id)).toEqual([1]);
  });
  it("sorts heaviest first and breaks ties by id", () => {
    const r = rankLessons(
      reader(
        [lesson(3), lesson(1), lesson(2)],
        [occ(1, 1, { severity: "Nit" }), occ(2, 2), occ(3, 3)],
      ),
      "/work",
      NOW,
    );
    expect(r.map((x) => x.lesson.id)).toEqual([2, 3, 1]);
  });
  it("derives count, repos and the newest occurrence", () => {
    const [r] = rankLessons(
      reader(
        [lesson(1)],
        [
          occ(1, 1, { mrKey: "z/b!2", at: NOW - 5 }),
          occ(2, 1, { mrKey: "a/x!9", at: NOW - 1 }),
          occ(3, 1, { mrKey: "a/x!4", at: NOW - 1 }),
        ],
      ),
      "/work",
      NOW,
    );
    expect(r?.count).toBe(3);
    expect(r?.repos).toEqual(["a/x", "z/b"]);
    expect(r?.last).toEqual({ mrKey: "a/x!4", at: NOW - 1 });
  });
  it("never ranks a scope-less lesson for a real scope", () => {
    const r = rankLessons(reader([lesson(1, { scope: "" })], [occ(1, 1)]), "/work", NOW);
    expect(r).toEqual([]);
  });
});

describe("lessonsForFile", () => {
  const go = ranked(lesson(1, { globs: ["**/*.go"] }), { weight: 5 });
  const handlers = ranked(lesson(2, { globs: ["**/handlers/**"] }), { weight: 3 });
  const both = [go, handlers];
  it("matches language and folder globs", () => {
    expect(lessonsForFile(both, "cmd/api/main.go", 5)).toEqual([go]);
    expect(lessonsForFile(both, "internal/handlers/user.go", 5)).toEqual([go, handlers]);
    expect(lessonsForFile(both, "README.md", 5)).toEqual([]);
  });
  it("keeps the heaviest up to the limit", () => {
    expect(lessonsForFile(both, "internal/handlers/user.go", 1)).toEqual([go]);
  });
  it("normalises separators and leading ./ or /", () => {
    expect(lessonsForFile(both, "internal\\handlers\\user.go", 5)).toEqual([go, handlers]);
    expect(lessonsForFile(both, "./cmd/main.go", 5)).toEqual([go]);
    expect(lessonsForFile(both, "/cmd/main.go", 5)).toEqual([go]);
  });
  it("matches dotfiles and files in dot-folders", () => {
    const yml = ranked(lesson(5, { globs: ["**/*.yml"] }));
    expect(lessonsForFile([yml], ".gitlab-ci.yml", 5)).toEqual([yml]);
    expect(lessonsForFile([yml], ".github/workflows/ci.yml", 5)).toEqual([yml]);
    expect(lessonsForFile([yml], "deploy/.hidden/x.yml", 5)).toEqual([yml]);
    const github = ranked(lesson(6, { globs: [".github/**/*.yml"] }));
    expect(lessonsForFile([github], ".github/workflows/.x/ci.yml", 5)).toEqual([github]);
    expect(lessonsForFile([github], "github/workflows/ci.yml", 5)).toEqual([]);
    const env = ranked(lesson(7, { globs: ["*.env", ".env"] }));
    expect(lessonsForFile([env], "config/.env", 5)).toEqual([env]);
    expect(lessonsForFile([env], "config/env", 5)).toEqual([]);
  });
  it("matches a glob without a slash against the file name anywhere", () => {
    const ts = ranked(lesson(8, { globs: ["*.ts"] }));
    expect(lessonsForFile([ts], "src/a.ts", 5)).toEqual([ts]);
    expect(lessonsForFile([ts], "a.ts", 5)).toEqual([ts]);
    expect(lessonsForFile([ts], "src/a.tsx", 5)).toEqual([]);
    const docker = ranked(lesson(9, { globs: ["Dockerfile"] }));
    expect(lessonsForFile([docker], "build/api/Dockerfile", 5)).toEqual([docker]);
    const rooted = ranked(lesson(10, { globs: ["src/*.ts"] }));
    expect(lessonsForFile([rooted], "lib/src/a.ts", 5)).toEqual([]);
  });
  it("still does not match a file of another type", () => {
    expect(lessonsForFile([go], "a.txt", 5)).toEqual([]);
    expect(lessonsForFile([go], ".a.txt", 5)).toEqual([]);
    expect(lessonsForFile([go], ".config/a.txt", 5)).toEqual([]);
  });
  it("treats an invalid glob as no match", () => {
    const bad = ranked(lesson(3, { globs: ["\0bad", "**/*.go"] }));
    expect(() => lessonsForFile([bad], "a.go", 5)).not.toThrow();
    expect(lessonsForFile([bad], "a.go", 5)).toEqual([bad]);
    expect(lessonsForFile([ranked(lesson(4, { globs: ["\0bad"] }))], "a.go", 5)).toEqual([]);
  });
});

describe("renderLessons", () => {
  it("names the count and the last MR", () => {
    const text = renderLessons([ranked(lesson(1, { title: "T", rule: "R" }), { count: 3 })]);
    expect(text).toBe("- T: R (flagged 3 times, last in g/p !7)");
  });
  it("uses the singular for one occurrence", () => {
    expect(renderLessons([ranked(lesson(1), { count: 1 })])).toContain("flagged 1 time,");
  });
  it("renders an empty list as an empty string", () => {
    expect(renderLessons([])).toBe("");
  });
  it("collapses newlines and caps title and rule", () => {
    const text = renderLessons([
      ranked(lesson(1, { title: "a\nb" + "x".repeat(100), rule: "r\r\ns" + "y".repeat(700) })),
    ]);
    expect(text).not.toMatch(/[\r\n]/);
    const m = /^- (.*?): (.*) \(flagged/.exec(text);
    expect(m?.[1]).toHaveLength(80);
    expect(m?.[1]?.startsWith("a b")).toBe(true);
    expect(m?.[1]?.endsWith("…")).toBe(true);
    expect(m?.[2]).toHaveLength(600);
  });
  it("joins lessons with newlines", () => {
    const text = renderLessons([ranked(lesson(1)), ranked(lesson(2))]);
    expect(text.split("\n")).toHaveLength(2);
  });
});
