import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, describe, expect, it, vi } from "vitest";
import { createLessonStore, openLessonsReadOnly } from "../src/lesson-store.ts";
import type { NewOccurrence } from "../src/lesson-store.ts";
import { openStore } from "../src/store.ts";

const folders: string[] = [];
afterEach(() => {
  for (const folder of folders.splice(0)) rmSync(folder, { recursive: true, force: true });
});

function occurrence(sourceKey: string, extra: Partial<NewOccurrence> = {}): NewOccurrence {
  return {
    sourceKey,
    source: "review",
    mrKey: "g/p!1",
    mrTitle: "Title",
    mrUrl: "https://gitlab/g/p/-/merge_requests/1",
    path: "src/a.ts",
    line: 3,
    severity: "major",
    title: "Missing check",
    text: "Missing check\nbody",
    outcome: "open",
    at: 100,
    ...extra,
  };
}

const fields = { scope: "g/p", title: "t", rule: "r", topics: [], globs: [] };

describe("lesson store", () => {
  it("addOccurrences ignores a source key it already has", () => {
    const { lessons } = openStore(":memory:");
    expect(lessons.addOccurrences([occurrence("review:1:1")])).toBe(1);
    expect(lessons.addOccurrences([occurrence("review:1:1")])).toBe(0);
    expect(lessons.occurrenceBySource("review:1:1")).toMatchObject({ repoPath: null, failures: 0 });
  });

  it("pendingOccurrences skips attached and not-yet-due rows", () => {
    const { lessons } = openStore(":memory:");
    lessons.addOccurrences([
      occurrence("a", { at: 3 }),
      occurrence("b", { at: 1 }),
      occurrence("c", { at: 2 }),
      occurrence("d", { at: 4 }),
    ]);
    const id = (key: string): number => lessons.occurrenceBySource(key)?.id ?? 0;
    lessons.attach([id("a")], lessons.createLesson(fields, 5), 5);
    lessons.failBatch([id("b")], 1000);
    expect(lessons.pendingOccurrences(500, 10).map((row) => row.sourceKey)).toEqual(["c", "d"]);
    expect(lessons.pendingOccurrences(1000, 10).map((row) => row.sourceKey)).toEqual([
      "b",
      "c",
      "d",
    ]);
    expect(lessons.pendingOccurrences(1000, 1)).toHaveLength(1);
    expect(lessons.occurrenceBySource("b")?.failures).toBe(1);
    expect(lessons.countPending()).toBe(3);
  });

  it("merge moves occurrences and links and deletes the other lesson", () => {
    const { lessons } = openStore(":memory:");
    const keep = lessons.createLesson(fields, 1);
    const gone = lessons.createLesson(fields, 1);
    const third = lessons.createLesson(fields, 1);
    lessons.addOccurrences([occurrence("a"), occurrence("b")]);
    lessons.attach([lessons.occurrenceBySource("a")?.id ?? 0], keep, 2);
    lessons.attach([lessons.occurrenceBySource("b")?.id ?? 0], gone, 2);
    lessons.link(gone, third);
    lessons.link(keep, gone);
    lessons.merge(keep, gone, 9);
    expect(lessons.lesson(gone)).toBeUndefined();
    expect(lessons.occurrences(keep).map((row) => row.sourceKey)).toEqual(["a", "b"]);
    expect(lessons.links(keep)).toEqual([third]);
    expect(lessons.links(third)).toEqual([keep]);
    expect(lessons.lesson(keep)?.updatedAt).toBe(9);
  });

  it("link is undirected", () => {
    const { lessons } = openStore(":memory:");
    for (let i = 0; i < 3; i += 1) lessons.createLesson(fields, 1);
    lessons.link(3, 1);
    lessons.link(1, 3);
    expect(lessons.links(1)).toEqual([3]);
    expect(lessons.links(3)).toEqual([1]);
  });

  it("filters lessons by scope and archive, and keeps meta in the shared table", () => {
    const store = openStore(":memory:");
    const a = store.lessons.createLesson(fields, 1);
    store.lessons.createLesson({ ...fields, scope: "" }, 1);
    store.lessons.archive(a, 2);
    expect(store.lessons.lessons("g/p")).toEqual([]);
    expect(store.lessons.lessons("g/p", true)).toHaveLength(1);
    store.lessons.setMeta("k", "v");
    expect(store.lessons.meta("k")).toBe("v");
    expect(store.lessons.meta("none")).toBeUndefined();
  });

  it("finds an occurrence by location and updates its outcome", () => {
    const { lessons } = openStore(":memory:");
    lessons.addOccurrences([occurrence("a")]);
    lessons.setOutcome("a", "fixed", 7);
    expect(lessons.findOccurrenceByLocation("g/p!1", "src/a.ts", "Missing check")).toMatchObject({
      outcome: "fixed",
    });
  });

  it("openLessonsReadOnly returns undefined for a missing file", () => {
    const folder = mkdtempSync(join(tmpdir(), "suica-lessons-"));
    folders.push(folder);
    expect(openLessonsReadOnly(join(folder, "none.db"))).toBeUndefined();
  });

  it("openLessonsReadOnly returns undefined for a database without the lesson table", () => {
    const folder = mkdtempSync(join(tmpdir(), "suica-lessons-"));
    folders.push(folder);
    const path = join(folder, "old.db");
    const db = new DatabaseSync(path);
    db.exec("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)");
    db.close();
    expect(openLessonsReadOnly(path)).toBeUndefined();
  });

  it("openLessonsReadOnly refuses writes", () => {
    const folder = mkdtempSync(join(tmpdir(), "suica-lessons-"));
    folders.push(folder);
    const path = join(folder, "state.db");
    const store = openStore(path);
    const id = store.lessons.createLesson(fields, 1);
    store.close();
    const reader = openLessonsReadOnly(path);
    expect(reader?.lesson(id)?.title).toBe("t");
    expect(reader?.lessons("g/p")).toHaveLength(1);
    expect(() => reader?.db.exec("INSERT INTO lesson_link (a, b) VALUES (1, 2)")).toThrow();
    reader?.close();
  });

  it("allLessons spans scopes, unlink drops a link and setRepoPath updates a row", () => {
    const store = openStore(":memory:");
    const { lessons } = store;
    const a = lessons.createLesson({ ...fields, scope: "" }, 1);
    const b = lessons.createLesson(fields, 1);
    lessons.archive(b, 2);
    expect(lessons.allLessons().map((l) => l.id)).toEqual([a, b]);
    lessons.link(a, b);
    lessons.unlink(b, a);
    expect(lessons.links(a)).toEqual([]);
    lessons.addOccurrences([occurrence("k")]);
    const id = lessons.occurrenceBySource("k")?.id ?? 0;
    lessons.setRepoPath(id, "/w/p");
    expect(lessons.occurrenceBySource("k")?.repoPath).toBe("/w/p");
    store.close();
  });

  describe("repeatsBySource", () => {
    /** One lesson of `scope` with the given occurrences: [sourceKey, mrKey] pairs. */
    const seed = (
      lessons: ReturnType<typeof openStore>["lessons"],
      rows: readonly (readonly [string, string])[],
      scope = "/w/acme",
    ): number => {
      const id = lessons.createLesson({ ...fields, scope, title: `L ${scope}` }, 1);
      lessons.addOccurrences(rows.map(([key, mrKey]) => occurrence(key, { mrKey })));
      lessons.attach(
        rows.map(([key]) => lessons.occurrenceBySource(key)?.id ?? 0),
        id,
        2,
      );
      return id;
    };

    it("counts the other occurrences and their distinct repos, sorted", () => {
      const { lessons } = openStore(":memory:");
      const id = seed(lessons, [
        ["review:9:1", "g/web!3"],
        ["review:2:1", "g/api!1"],
        ["thread:g/api!4:d", "g/api!4"],
        ["review:5:2", "g/cli!8"],
      ]);
      const repeats = lessons.repeatsBySource(["review:9:1", "review:404:1"]);
      expect([...repeats.entries()]).toEqual([
        ["review:9:1", { lessonId: id, title: "L /w/acme", before: 3, repos: ["g/api", "g/cli"] }],
      ]);
    });

    it("leaves out a lone occurrence, an archived lesson, a lesson with no scope and a pending one", () => {
      const { lessons } = openStore(":memory:");
      seed(lessons, [["lone", "g/a!1"]]);
      const archived = seed(lessons, [
        ["arch", "g/a!1"],
        ["arch2", "g/a!2"],
      ]);
      lessons.archive(archived, 3);
      seed(
        lessons,
        [
          ["noscope", "g/a!1"],
          ["noscope2", "g/a!2"],
        ],
        "",
      );
      lessons.addOccurrences([occurrence("pending")]);
      expect(lessons.repeatsBySource(["lone", "arch", "noscope", "pending"]).size).toBe(0);
      expect(lessons.repeatsBySource([]).size).toBe(0);
    });

    it("reads with one query however many keys it is given", () => {
      const folder = mkdtempSync(join(tmpdir(), "suica-lessons-"));
      folders.push(folder);
      const path = join(folder, "state.db");
      const store = openStore(path);
      seed(store.lessons, [
        ["a", "g/a!1"],
        ["b", "g/b!1"],
      ]);
      store.close();
      const db = new DatabaseSync(path);
      const prepare = vi.spyOn(db, "prepare");
      const keys = Array.from({ length: 200 }, (_, i) => `review:${String(i)}:1`);
      expect(createLessonStore(db).repeatsBySource(["a", "b", ...keys]).size).toBe(2);
      expect(prepare).toHaveBeenCalledTimes(1);
      db.close();
    });

    it("is offered by the read-only reader, with countPending", () => {
      const folder = mkdtempSync(join(tmpdir(), "suica-lessons-"));
      folders.push(folder);
      const path = join(folder, "state.db");
      const store = openStore(path);
      seed(store.lessons, [
        ["a", "g/a!1"],
        ["b", "g/b!1"],
      ]);
      store.lessons.addOccurrences([occurrence("pending")]);
      store.close();
      const reader = openLessonsReadOnly(path);
      expect(reader?.repeatsBySource(["a"]).get("a")?.before).toBe(1);
      expect(reader?.countPending()).toBe(1);
      reader?.close();
    });
  });
});
