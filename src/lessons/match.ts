import { matchesGlob } from "node:path";
import type { LessonRow, LessonStore, OccurrenceRow } from "../lesson-store.ts";
import { projectOfMrKey } from "./scopes.ts";

const DAY = 86_400_000;
const HALF_LIFE_DAYS = 90;
const MAX_TITLE = 80;
const MAX_RULE = 600;

const SEVERITY_FACTOR: Readonly<Record<string, number>> = {
  Blocker: 4,
  Major: 3,
  Minor: 1.5,
  Nit: 1,
};

export interface RankedLesson {
  readonly lesson: LessonRow;
  readonly weight: number;
  readonly count: number;
  readonly repos: readonly string[];
  readonly last: { readonly mrKey: string; readonly at: number };
}

/** Sum of severity factor x 0.5^(ageDays/90); an occurrence in the future counts as age 0. */
export function weight(
  occurrences: readonly Pick<OccurrenceRow, "severity" | "at">[],
  now: number,
): number {
  let total = 0;
  for (const o of occurrences) {
    const ageDays = Math.max(0, now - o.at) / DAY;
    total += (SEVERITY_FACTOR[o.severity] ?? 1) * 0.5 ** (ageDays / HALF_LIFE_DAYS);
  }
  return total;
}

/** The scope's unarchived lessons, heaviest first, ties by id. */
export function rankLessons(
  reader: Pick<LessonStore, "lessons" | "occurrences">,
  scope: string,
  now: number,
): RankedLesson[] {
  const out: RankedLesson[] = [];
  for (const lesson of reader.lessons(scope)) {
    if (lesson.archived) continue;
    const occurrences = reader.occurrences(lesson.id);
    let newest: OccurrenceRow | undefined;
    for (const o of occurrences) {
      if (!newest || o.at > newest.at || (o.at === newest.at && o.id > newest.id)) newest = o;
    }
    if (!newest) continue;
    out.push({
      lesson,
      weight: weight(occurrences, now),
      count: occurrences.length,
      repos: [...new Set(occurrences.map((o) => projectOfMrKey(o.mrKey)))].sort(),
      last: { mrKey: newest.mrKey, at: newest.at },
    });
  }
  return out.sort((a, b) => b.weight - a.weight || a.lesson.id - b.lesson.id);
}

/**
 * `matchesGlob` never lets `*` or `**` match a segment starting with a dot. Lessons' globs are
 * about file types and folders, so a `*.yml` glob under `**` should cover `.gitlab-ci.yml` and
 * `.github/workflows/ci.yml`. The leading dot of every segment, in path and glob alike, becomes
 * this character, which no wildcard rule singles out; a glob segment naming `.github` still only
 * matches `.github`. The plain match is tried as well, for globs such as `{.a,.b}`.
 */
const DOT = "\u0001";

function undotted(text: string): string {
  return text
    .split("/")
    .map((segment) => (segment.startsWith(".") ? DOT + segment.slice(1) : segment))
    .join("/");
}

function globMatches(path: string, glob: string): boolean {
  try {
    if (matchesGlob(path, glob) || matchesGlob(undotted(path), undotted(glob))) return true;
    // A glob without a slash, such as `*.ts` or `Dockerfile`, names a file anywhere in the repo.
    if (glob.includes("/")) return false;
    const name = path.slice(path.lastIndexOf("/") + 1);
    return (
      name !== path && (matchesGlob(name, glob) || matchesGlob(undotted(name), undotted(glob)))
    );
  } catch {
    return false;
  }
}

/** The heaviest `limit` lessons with a glob matching the path (relative to the repository). */
export function lessonsForFile(
  ranked: readonly RankedLesson[],
  relativePath: string,
  limit: number,
): RankedLesson[] {
  const path = relativePath.replaceAll("\\", "/").replace(/^(?:\.?\/)+/, "");
  return ranked.filter((r) => r.lesson.globs.some((g) => globMatches(path, g))).slice(0, limit);
}

function plain(text: string, max: number): string {
  const flat = text.replace(/\s*[\r\n]+\s*/g, " ").trim();
  return flat.length <= max ? flat : `${flat.slice(0, max - 1)}…`;
}

export function renderLessons(lessons: readonly RankedLesson[]): string {
  return lessons
    .map((r) => {
      const bang = r.last.mrKey.lastIndexOf("!");
      const repo = projectOfMrKey(r.last.mrKey);
      const iid = bang < 0 ? "" : r.last.mrKey.slice(bang + 1);
      const times = r.count === 1 ? "1 time" : `${r.count} times`;
      return `- ${plain(r.lesson.title, MAX_TITLE)}: ${plain(r.lesson.rule, MAX_RULE)} (flagged ${times}, last in ${repo} !${iid})`;
    })
    .join("\n");
}
