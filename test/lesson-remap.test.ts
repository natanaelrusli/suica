import { afterEach, describe, expect, it } from "vitest";
import { parseConfig } from "../src/config.ts";
import type { NewOccurrence } from "../src/lesson-store.ts";
import { createLessonLearner } from "../src/lessons/learn.ts";
import { createLogger } from "../src/log.ts";
import { remapScopes, sameScopeMap } from "../src/lessons/remap.ts";
import type { ScopeMap } from "../src/lessons/scopes.ts";
import { openStore } from "../src/store.ts";
import type { Store } from "../src/store.ts";

const stores: Store[] = [];
afterEach(() => {
  for (const s of stores.splice(0)) s.close();
});
const db = (): Store => {
  const s = openStore(":memory:");
  stores.push(s);
  return s;
};

const occ = (sourceKey: string, project: string): NewOccurrence => ({
  sourceKey,
  source: "review",
  mrKey: `${project}!1`,
  mrTitle: "T",
  mrUrl: "u",
  path: "a.ts",
  line: 1,
  severity: "major",
  title: "t",
  text: "t",
  outcome: "open",
  at: 1,
});

const repo = (scope: string, project: string): ScopeMap["repos"][number] => ({
  scope,
  dir: `${scope}/${project.split("/").pop() ?? ""}`,
  project,
});

/** A lesson in `scope` holding one occurrence per project. */
function lessonOf(s: Store, scope: string, projects: string[], tag = "x"): number {
  const id = s.lessons.createLesson(
    { scope, title: "Title", rule: "Rule", topics: ["a"], globs: ["*.ts"] },
    1,
  );
  const keys = projects.map((p, i) => `${tag}:${p}:${String(i)}`);
  s.lessons.addOccurrences(projects.map((p, i) => occ(keys[i] ?? "", p)));
  const ids = keys.map((k) => s.lessons.occurrenceBySource(k)?.id ?? 0);
  s.lessons.attach(ids, id, 1);
  return id;
}

describe("remapping scopes", () => {
  it("a lesson whose repos move to a deeper scope moves with them", () => {
    const s = db();
    const id = lessonOf(s, "/w", ["g/a", "g/b"]);
    const out = remapScopes(
      s.lessons,
      { repos: [repo("/w/deep", "g/a"), repo("/w/deep", "g/b")] },
      5,
    );
    expect(out).toEqual({ split: 0, orphaned: 0 });
    expect(s.lessons.lesson(id)?.scope).toBe("/w/deep");
    expect(s.lessons.lessons("/w")).toEqual([]);
    expect(s.lessons.occurrences(id).map((o) => o.repoPath)).toEqual(["/w/deep/a", "/w/deep/b"]);
  });

  it("a lesson spread over two scopes splits into one per scope", () => {
    const s = db();
    const id = lessonOf(s, "/w", ["g/a", "g/b", "g/c"]);
    const map = { repos: [repo("/w/x", "g/a"), repo("/w/y", "g/b"), repo("/w/y", "g/c")] };
    expect(remapScopes(s.lessons, map, 5)).toEqual({ split: 1, orphaned: 0 });
    expect(s.lessons.lesson(id)?.scope).toBe("/w/y");
    expect(s.lessons.occurrences(id)).toHaveLength(2);
    const [copy] = s.lessons.lessons("/w/x");
    expect(copy).toMatchObject({ title: "Title", rule: "Rule", topics: ["a"], globs: ["*.ts"] });
    expect(s.lessons.occurrences(copy?.id ?? 0).map((o) => o.mrKey)).toEqual(["g/a!1"]);
  });

  it("a lesson whose scope was removed reaches no scope", () => {
    const s = db();
    const id = lessonOf(s, "/w", ["g/a"]);
    expect(remapScopes(s.lessons, { repos: [] }, 5)).toEqual({ split: 0, orphaned: 1 });
    expect(s.lessons.lesson(id)?.scope).toBe("");
    expect(s.lessons.lessons("/w")).toEqual([]);
    expect(s.lessons.occurrences(id)).toHaveLength(1);
    // Back in a scope, it returns.
    remapScopes(s.lessons, { repos: [repo("/w", "g/a")] }, 6);
    expect(s.lessons.lesson(id)?.scope).toBe("/w");
  });

  it("links do not cross scopes after a split", () => {
    const s = db();
    const a = lessonOf(s, "/w", ["g/a", "g/b", "g/b"], "a");
    const b = lessonOf(s, "/w", ["g/a"], "b");
    s.lessons.link(a, b);
    const map = { repos: [repo("/w/x", "g/a"), repo("/w/y", "g/b")] };
    remapScopes(s.lessons, map, 5);
    expect(s.lessons.lesson(a)?.scope).toBe("/w/y");
    expect(s.lessons.lesson(b)?.scope).toBe("/w/x");
    expect(s.lessons.links(a)).toEqual([]);
    expect(s.lessons.links(b)).toEqual([]);
    for (const each of s.lessons.allLessons()) expect(s.lessons.links(each.id)).toEqual([]);
  });

  it("keeps links between lessons that end in the same scope", () => {
    const s = db();
    const a = lessonOf(s, "/w", ["g/a"], "a");
    const b = lessonOf(s, "/w", ["g/b"], "b");
    s.lessons.link(a, b);
    remapScopes(s.lessons, { repos: [repo("/w", "g/a"), repo("/w", "g/b")] }, 5);
    expect(s.lessons.links(a)).toEqual([b]);
  });

  it("breaks a tie by the first scope and keeps archived copies archived", () => {
    const s = db();
    const id = lessonOf(s, "/w", ["g/a", "g/b"]);
    s.lessons.archive(id, 2);
    remapScopes(s.lessons, { repos: [repo("/w/z", "g/a"), repo("/w/m", "g/b")] }, 5);
    expect(s.lessons.lesson(id)).toMatchObject({ scope: "/w/m", archived: true });
    expect(s.lessons.lessons("/w/z")).toEqual([]);
    expect(s.lessons.lessons("/w/z", true)).toMatchObject([{ archived: true }]);
  });

  it("running twice changes nothing the second time", () => {
    const s = db();
    lessonOf(s, "/w", ["g/a", "g/b", "g/c"]);
    lessonOf(s, "/w", ["g/q"], "q");
    const map = { repos: [repo("/w/x", "g/a"), repo("/w/y", "g/b"), repo("/w/y", "g/c")] };
    remapScopes(s.lessons, map, 5);
    const before = JSON.stringify(s.lessons.allLessons());
    expect(remapScopes(s.lessons, map, 99)).toEqual({ split: 0, orphaned: 0 });
    expect(JSON.stringify(s.lessons.allLessons())).toBe(before);
  });

  it("sameScopeMap ignores order", () => {
    const a = { repos: [repo("/w", "g/a"), repo("/w", "g/b")] };
    expect(sameScopeMap(a, { repos: [...a.repos].reverse() })).toBe(true);
    expect(sameScopeMap(a, { repos: [repo("/w", "g/a")] })).toBe(false);
  });

  it("an identical rescan does not remap", async () => {
    const s = db();
    const id = lessonOf(s, "/w", ["g/a"]);
    let map: ScopeMap = { repos: [repo("/w", "g/a")] };
    let now = 1_000_000_000_000;
    const learner = createLessonLearner({
      store: s,
      config: parseConfig(
        'gitlab:\n  hostname: gitlab.example\nmodel:\n  cli: claude\nlessons:\n  enabled: true\n  scopes: ["/w"]\n',
      ),
      log: createLogger({ write: () => undefined }),
      now: () => now,
      exec: () => Promise.reject(new Error("no")),
      detectClis: () => [],
      busy: () => true,
      detail: () => Promise.reject(new Error("no")),
      scan: () => map,
    });
    await learner.tick();
    expect(s.lessons.lesson(id)?.scope).toBe("/w");
    s.lessons.setScope(id, "/marker", 2);
    now += 3_700_000;
    await learner.tick();
    expect(s.lessons.lesson(id)?.scope).toBe("/marker"); // same map: untouched
    map = { repos: [repo("/w/d", "g/a")] };
    now += 3_700_000;
    await learner.tick();
    expect(s.lessons.lesson(id)?.scope).toBe("/w/d");
  });
});
