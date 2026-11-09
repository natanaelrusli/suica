import { describe, expect, it } from "vitest";
import { buildLessonGraph } from "../src/lessons/owner.ts";
import type { LessonRow } from "../src/lesson-store.ts";

const lesson = (id: number, archived = false): LessonRow => ({
  id,
  scope: "/s",
  title: `L${String(id)}`,
  rule: "r",
  topics: ["db"],
  globs: ["**/*"],
  archived,
  createdAt: 0,
  updatedAt: 0,
});

describe("buildLessonGraph", () => {
  it("emits live lessons, topic nodes, topic edges and each link once", () => {
    const reader = {
      allLessons: () => [lesson(1), lesson(2), lesson(3, true)],
      occurrences: () => [],
      links: (id: number) => ({ 1: [2, 3], 2: [1], 3: [1] })[id] ?? [],
    };
    const g = buildLessonGraph(reader, 0);
    expect(g.nodes.map((n) => n["id"])).toEqual(["lesson:1", "lesson:2", "topic:db"]);
    expect(g.edges.filter((e) => e.type === "related")).toEqual([
      { source: "lesson:1", target: "lesson:2", type: "related" },
    ]);
    expect(g.edges.filter((e) => e.type === "topic")).toHaveLength(2);
  });
});
