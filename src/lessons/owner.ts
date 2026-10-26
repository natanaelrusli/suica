import { resolve } from "node:path";
import type { LessonReader, LessonStore, OccurrenceRow, Outcome } from "../lesson-store.ts";
import { rankLessons, weight } from "./match.ts";
import { projectOfMrKey } from "./scopes.ts";
import type { ScopeMap } from "./scopes.ts";

/**
 * The Owner's view of the Lessons (`suica lessons list|show|archive|merge`), for the app's Lessons
 * view. See contracts/lessons.v1.json. Unlike the vault, it names MR titles: it stays on the Mac.
 */

const TEXT_MAX = 1000;

export interface LessonSummaryJson {
  readonly id: number;
  readonly title: string;
  readonly rule: string;
  readonly topics: readonly string[];
  /** Ranking weight now, rounded to two decimals. */
  readonly weight: number;
  readonly count: number;
  /** Distinct projects (`group/project`) it was flagged in, sorted. */
  readonly repos: readonly string[];
  /** ISO 8601, its newest occurrence. */
  readonly lastSeen: string;
}

export interface LessonScopeJson {
  /** The configured folder, resolved. */
  readonly path: string;
  /** Git repos found under it. */
  readonly repos: number;
  /** Its unarchived Lessons, heaviest first. */
  readonly lessons: readonly LessonSummaryJson[];
}

/** `suica lessons list --json`. */
export interface LessonListJson {
  readonly version: 1;
  readonly enabled: boolean;
  /** Empty while lessons are off. */
  readonly scopes: readonly LessonScopeJson[];
  /** Occurrences not learned into a Lesson yet. */
  readonly pending: number;
}

export interface OccurrenceJson {
  readonly mrKey: string;
  readonly mrTitle: string;
  readonly mrUrl: string;
  readonly path: string | null;
  readonly line: number | null;
  readonly severity: string;
  readonly outcome: Outcome;
  /** The finding's text, at most 1000 characters. */
  readonly text: string;
  /** ISO 8601. */
  readonly at: string;
}

/** `suica lessons show <id> --json`. */
export interface LessonShowJson {
  readonly version: 1;
  readonly lesson: {
    readonly id: number;
    readonly title: string;
    readonly rule: string;
    readonly topics: readonly string[];
    readonly globs: readonly string[];
    /** The Lesson Scope's path; "" when its occurrences fall in no scope. */
    readonly scope: string;
    readonly archived: boolean;
    readonly weight: number;
    readonly count: number;
    readonly repos: readonly string[];
    /** ISO 8601; null when it has no occurrence. */
    readonly lastSeen: string | null;
    /** Linked Lessons of the same scope, not archived, by id. */
    readonly related: readonly { readonly id: number; readonly title: string }[];
    /** Newest first. */
    readonly occurrences: readonly OccurrenceJson[];
  };
}

type ListReader = Pick<LessonReader, "lessons" | "occurrences" | "countPending">;
type ShowReader = Pick<LessonReader, "lesson" | "occurrences" | "links">;

function rounded(value: number): number {
  return Math.round(value * 100) / 100;
}

function iso(at: number): string {
  return new Date(at).toISOString();
}

/** Every configured scope with its Lessons; reads nothing at all while lessons are off. */
export function buildLessonList(
  reader: ListReader | undefined,
  config: { readonly enabled: boolean; readonly scopes: readonly string[] },
  scan: () => ScopeMap,
  now: number,
): LessonListJson {
  if (!config.enabled) return { version: 1, enabled: false, scopes: [], pending: 0 };
  const map = scan();
  const paths = [...new Set(config.scopes.filter((raw) => raw !== "").map((raw) => resolve(raw)))];
  return {
    version: 1,
    enabled: true,
    scopes: paths.map((path) => ({
      path,
      repos: map.repos.filter((repo) => repo.scope === path).length,
      lessons:
        reader === undefined
          ? []
          : rankLessons(reader, path, now).map((ranked) => ({
              id: ranked.lesson.id,
              title: ranked.lesson.title,
              rule: ranked.lesson.rule,
              topics: ranked.lesson.topics,
              weight: rounded(ranked.weight),
              count: ranked.count,
              repos: ranked.repos,
              lastSeen: iso(ranked.last.at),
            })),
    })),
    pending: reader?.countPending() ?? 0,
  };
}

function newestFirst(a: OccurrenceRow, b: OccurrenceRow): number {
  return b.at - a.at || b.id - a.id;
}

/** One Lesson, archived or not, with every occurrence; undefined for an unknown id. */
export function buildLessonShow(
  reader: ShowReader,
  id: number,
  now: number,
): LessonShowJson | undefined {
  const lesson = reader.lesson(id);
  if (lesson === undefined) return undefined;
  const occurrences = reader.occurrences(id).sort(newestFirst);
  const related = reader.links(id).flatMap((other) => {
    const row = reader.lesson(other);
    // A link never leads to another scope's Lesson, or to one the Owner archived.
    return row === undefined || row.archived || row.scope !== lesson.scope
      ? []
      : [{ id: row.id, title: row.title }];
  });
  const newest = occurrences[0];
  return {
    version: 1,
    lesson: {
      id: lesson.id,
      title: lesson.title,
      rule: lesson.rule,
      topics: lesson.topics,
      globs: lesson.globs,
      scope: lesson.scope,
      archived: lesson.archived,
      weight: rounded(weight(occurrences, now)),
      count: occurrences.length,
      repos: [...new Set(occurrences.map((o) => projectOfMrKey(o.mrKey)))].sort(),
      lastSeen: newest === undefined ? null : iso(newest.at),
      related,
      occurrences: occurrences.map((o) => ({
        mrKey: o.mrKey,
        mrTitle: o.mrTitle,
        mrUrl: o.mrUrl,
        path: o.path,
        line: o.line,
        severity: o.severity,
        outcome: o.outcome,
        text: o.text.length <= TEXT_MAX ? o.text : `${o.text.slice(0, TEXT_MAX - 1)}…`,
        at: iso(o.at),
      })),
    },
  };
}

export type ChangeResult =
  | { readonly status: "archived" | "merged" | "not-found" }
  | { readonly status: "bad-request"; readonly message: string };

/** Archives a Lesson: it is no longer handed to agents or exported. */
export function archiveLesson(
  store: Pick<LessonStore, "lesson" | "archive">,
  id: number,
  now: number,
): ChangeResult {
  if (store.lesson(id) === undefined) return { status: "not-found" };
  store.archive(id, now);
  return { status: "archived" };
}

/**
 * Merges `goneId` into `keepId`. Refuses Lessons of two scopes (no Lesson crosses a scope) and an
 * archived Lesson on either side. The checks run in the transaction that writes, so a scope remap
 * by the daemon cannot slip in between.
 */
export function mergeLessons(
  store: Pick<LessonStore, "lesson" | "merge" | "transaction">,
  keepId: number,
  goneId: number,
  now: number,
): ChangeResult {
  if (keepId === goneId) {
    return { status: "bad-request", message: "a lesson cannot be merged into itself" };
  }
  let result: ChangeResult = { status: "not-found" };
  store.transaction(() => {
    const keep = store.lesson(keepId);
    const gone = store.lesson(goneId);
    if (keep === undefined || gone === undefined) return;
    const archived = [keep, gone].find((each) => each.archived);
    if (archived !== undefined) {
      result = { status: "bad-request", message: `lesson ${String(archived.id)} is archived` };
      return;
    }
    if (keep.scope !== gone.scope) {
      result = { status: "bad-request", message: "lessons of two scopes cannot be merged" };
      return;
    }
    store.merge(keepId, goneId, now);
    result = { status: "merged" };
  });
  return result;
}
