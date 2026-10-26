import type { LessonStore, OccurrenceRow } from "../lesson-store.ts";
import { projectOfMrKey, scopeForProject } from "./scopes.ts";
import type { ScopeMap } from "./scopes.ts";

/** True when both maps hold the same repos in the same scopes. */
export function sameScopeMap(a: ScopeMap, b: ScopeMap): boolean {
  const key = (map: ScopeMap): string =>
    JSON.stringify(
      map.repos
        .map((r) => [r.scope, r.dir, r.project])
        .sort((x, y) => (x < y ? -1 : x > y ? 1 : 0)),
    );
  return key(a) === key(b);
}

/**
 * Brings every Lesson in step with `map`: a Lesson's scope follows the repos of its occurrences,
 * one spread over several scopes is split into one Lesson per scope, and one with no occurrence in
 * any scope drops to scope "". Links never cross scopes. Safe to run again.
 */
export function remapScopes(
  store: LessonStore,
  map: ScopeMap,
  at: number,
): { split: number; orphaned: number } {
  let split = 0;
  let orphaned = 0;
  store.transaction(() => {
    for (const lesson of store.allLessons()) {
      const groups = new Map<string, OccurrenceRow[]>();
      for (const row of store.occurrences(lesson.id)) {
        const repo = scopeForProject(map, projectOfMrKey(row.mrKey));
        if (repo === undefined) continue;
        if (row.repoPath !== repo.dir) store.setRepoPath(row.id, repo.dir);
        const list = groups.get(repo.scope) ?? [];
        list.push(row);
        groups.set(repo.scope, list);
      }
      const ranked = [...groups.entries()].sort(
        (a, b) => b[1].length - a[1].length || (a[0] < b[0] ? -1 : 1),
      );
      const keep = ranked[0]?.[0] ?? "";
      if (keep === "" && lesson.scope !== "") orphaned += 1;
      if (keep !== lesson.scope) store.setScope(lesson.id, keep, at);
      for (const [scope, rows] of ranked.slice(1)) {
        const copy = store.createLesson(
          {
            scope,
            title: lesson.title,
            rule: lesson.rule,
            topics: lesson.topics,
            globs: lesson.globs,
          },
          at,
        );
        if (lesson.archived) store.archive(copy, at);
        store.attach(
          rows.map((row) => row.id),
          copy,
          at,
        );
        split += 1;
      }
    }
    const scopeOf = new Map(store.allLessons().map((each) => [each.id, each.scope]));
    for (const [id, scope] of scopeOf) {
      for (const other of store.links(id)) {
        if (other > id && (scope === "" || scope !== scopeOf.get(other))) store.unlink(id, other);
      }
    }
  });
  return { split, orphaned };
}
