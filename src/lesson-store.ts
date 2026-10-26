import { existsSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { projectOfMrKey } from "./lessons/scopes.ts";
import { integer, nullableInteger, nullableText, text } from "./sql-row.ts";
import type { Row } from "./sql-row.ts";

export type OccurrenceSource = "review" | "thread";
export type Outcome =
  "open" | "fixed" | "not-fixed" | "partly-fixed" | "changed" | "replied" | "resolved";

export interface NewOccurrence {
  /** "review:<id>:<findingNumber>" or "thread:<mrKey>:<discussionId>". */
  readonly sourceKey: string;
  readonly source: OccurrenceSource;
  readonly mrKey: string;
  readonly mrTitle: string;
  readonly mrUrl: string;
  /** The repository checkout the finding was made in, when known. */
  readonly repoPath?: string | null;
  readonly path: string | null;
  readonly line: number | null;
  readonly severity: string;
  /** The first line of the text, at most 120 characters. */
  readonly title: string;
  readonly text: string;
  readonly outcome: Outcome;
  readonly at: number;
}

export interface OccurrenceRow extends NewOccurrence {
  readonly repoPath: string | null;
  readonly id: number;
  readonly lessonId: number | null;
  readonly failures: number;
  readonly retryAt: number | null;
}

export interface LessonRow {
  readonly id: number;
  readonly scope: string;
  readonly title: string;
  readonly rule: string;
  readonly topics: readonly string[];
  readonly globs: readonly string[];
  readonly archived: boolean;
  readonly createdAt: number;
  readonly updatedAt: number;
}

/** A finding that repeats a Lesson: the Lesson and its other occurrences. */
export interface LessonRepeat {
  readonly lessonId: number;
  readonly title: string;
  /** The Lesson's occurrences from other MRs that came before this one (time, then id). */
  readonly before: number;
  /** The distinct projects (`group/project`) of those earlier occurrences, sorted. */
  readonly repos: readonly string[];
}

/** The occurrence key of an Agent Review finding; `finding` as `uniqueFindingNumbers` gives it. */
export function reviewSourceKey(reviewId: number, finding: string): string {
  return `review:${String(reviewId)}:${finding}`;
}

/** The occurrence key of a Finding Thread. */
export function threadSourceKey(mrKey: string, discussionId: string): string {
  return `thread:${mrKey}:${discussionId}`;
}

export interface LessonStore {
  /** Returns how many rows were inserted; a source key already stored is ignored. */
  addOccurrences(rows: readonly NewOccurrence[]): number;
  setOutcome(sourceKey: string, outcome: Outcome, at: number): void;
  /** The newest occurrence at `path` of the MR whose title matches, ignoring case and outer spaces. */
  findOccurrenceByLocation(mrKey: string, path: string, title: string): OccurrenceRow | undefined;
  /** Occurrences with no lesson that are due, oldest first; only `mrKey`'s when given. */
  pendingOccurrences(now: number, limit: number, mrKey?: string): OccurrenceRow[];
  /** The MRs with due occurrences that have no lesson, the one with the oldest first. */
  pendingMrKeys(now: number): string[];
  countPending(): number;
  /**
   * For each key whose occurrence belongs to an unarchived Lesson of a scope that has an earlier
   * occurrence from another MR, that Lesson; keys without one are left out. Siblings of the same
   * MR and later findings never count. One query, whatever the key count.
   */
  repeatsBySource(sourceKeys: readonly string[]): Map<string, LessonRepeat>;
  /** Counts a failed distilling attempt and holds the rows back until `retryAt`. */
  failBatch(ids: readonly number[], retryAt: number): void;
  createLesson(
    fields: Omit<LessonRow, "id" | "archived" | "createdAt" | "updatedAt">,
    at: number,
  ): number;
  attach(occurrenceIds: readonly number[], lessonId: number, at: number): void;
  lessons(scope: string, includeArchived?: boolean): LessonRow[];
  lesson(id: number): LessonRow | undefined;
  occurrences(lessonId: number): OccurrenceRow[];
  occurrenceBySource(sourceKey: string): OccurrenceRow | undefined;
  setScope(lessonId: number, scope: string, at: number): void;
  /** Every lesson of every scope, scope "" and archived ones included. */
  allLessons(): LessonRow[];
  setRepoPath(occurrenceId: number, repoPath: string | null): void;
  /** Removes the link between `a` and `b`, if any. */
  unlink(a: number, b: number): void;
  /** Undirected and idempotent. */
  link(a: number, b: number): void;
  links(lessonId: number): number[];
  archive(id: number, at: number): void;
  /** Moves the occurrences and links of `goneId` to `keepId` and deletes `goneId`. */
  merge(keepId: number, goneId: number, at: number): void;
  /** Runs `work` in one transaction: a throw leaves none of its writes. */
  transaction(work: () => void): void;
  /** Shares the store's meta table. */
  meta(key: string): string | undefined;
  setMeta(key: string, value: string): void;
}

/** What a reader of the lessons file may do; `db` is its read-only handle. */
export type LessonReader = Pick<
  LessonStore,
  "lessons" | "lesson" | "occurrences" | "links" | "countPending" | "repeatsBySource"
> & {
  readonly db: DatabaseSync;
  close(): void;
};

const OCCURRENCE_COLUMNS = `id, source_key, source, mr_key, mr_title, mr_url, repo_path, path, line,
  severity, title, text, outcome, lesson_id, failures, retry_at, at`;

function toOutcome(value: string): Outcome {
  switch (value) {
    case "fixed":
    case "not-fixed":
    case "partly-fixed":
    case "changed":
    case "replied":
    case "resolved":
      return value;
    default:
      return "open";
  }
}

function toOccurrence(row: Row): OccurrenceRow {
  return {
    id: integer(row, "id"),
    sourceKey: text(row, "source_key"),
    source: text(row, "source") === "thread" ? "thread" : "review",
    mrKey: text(row, "mr_key"),
    mrTitle: text(row, "mr_title"),
    mrUrl: text(row, "mr_url"),
    repoPath: nullableText(row, "repo_path"),
    path: nullableText(row, "path"),
    line: nullableInteger(row, "line"),
    severity: text(row, "severity"),
    title: text(row, "title"),
    text: text(row, "text"),
    outcome: toOutcome(text(row, "outcome")),
    lessonId: nullableInteger(row, "lesson_id"),
    failures: integer(row, "failures"),
    retryAt: nullableInteger(row, "retry_at"),
    at: integer(row, "at"),
  };
}

function stringList(value: unknown): string[] {
  if (typeof value !== "string") return [];
  try {
    const parsed: unknown = JSON.parse(value);
    return Array.isArray(parsed)
      ? parsed.filter((item): item is string => typeof item === "string")
      : [];
  } catch {
    return [];
  }
}

function toLesson(row: Row): LessonRow {
  return {
    id: integer(row, "id"),
    scope: text(row, "scope"),
    title: text(row, "title"),
    rule: text(row, "rule"),
    topics: stringList(row["topics"]),
    globs: stringList(row["globs"]),
    archived: row["archived"] === 1,
    createdAt: integer(row, "created_at"),
    updatedAt: integer(row, "updated_at"),
  };
}

function placeholders(count: number): string {
  return Array.from({ length: count }, () => "?").join(", ");
}

type Reads = Pick<
  LessonStore,
  "lessons" | "lesson" | "occurrences" | "links" | "countPending" | "repeatsBySource"
>;

function createReads(db: DatabaseSync): Reads {
  return {
    lessons(scope, includeArchived = false) {
      const archived = includeArchived ? "" : " AND archived = 0";
      return db
        .prepare(`SELECT * FROM lesson WHERE scope = ?${archived} ORDER BY id`)
        .all(scope)
        .map(toLesson);
    },
    lesson(id) {
      const row = db.prepare("SELECT * FROM lesson WHERE id = ?").get(id);
      return row === undefined ? undefined : toLesson(row);
    },
    occurrences(lessonId) {
      return db
        .prepare(
          `SELECT ${OCCURRENCE_COLUMNS} FROM lesson_occurrence WHERE lesson_id = ? ORDER BY id`,
        )
        .all(lessonId)
        .map(toOccurrence);
    },
    links(lessonId) {
      return db
        .prepare(
          "SELECT CASE WHEN a = ? THEN b ELSE a END AS other FROM lesson_link WHERE a = ? OR b = ? ORDER BY other",
        )
        .all(lessonId, lessonId, lessonId)
        .map((row) => integer(row, "other"));
    },
    countPending() {
      const row = db
        .prepare("SELECT COUNT(*) AS n FROM lesson_occurrence WHERE lesson_id IS NULL")
        .get();
      return row === undefined ? 0 : integer(row, "n");
    },
    repeatsBySource(sourceKeys) {
      const out = new Map<string, LessonRepeat>();
      const keys = [...new Set(sourceKeys)];
      if (keys.length === 0) return out;
      // json_each takes the keys as one parameter, so no key count reaches SQLite's variable limit.
      const rows = db
        .prepare(
          `SELECT o.source_key, l.id, l.title, other.mr_key
           FROM json_each(?) AS k
           JOIN lesson_occurrence o ON o.source_key = k.value
           JOIN lesson l ON l.id = o.lesson_id AND l.archived = 0 AND l.scope <> ''
           JOIN lesson_occurrence other ON other.lesson_id = l.id AND other.mr_key <> o.mr_key
             AND (other.at < o.at OR (other.at = o.at AND other.id < o.id))
           ORDER BY o.source_key`,
        )
        .all(JSON.stringify(keys));
      const found = new Map<string, { lessonId: number; title: string; mrKeys: string[] }>();
      for (const row of rows) {
        const key = text(row, "source_key");
        const entry = found.get(key) ?? {
          lessonId: integer(row, "id"),
          title: text(row, "title"),
          mrKeys: [],
        };
        entry.mrKeys.push(text(row, "mr_key"));
        found.set(key, entry);
      }
      for (const [key, { lessonId, title, mrKeys }] of found) {
        out.set(key, {
          lessonId,
          title,
          before: mrKeys.length,
          repos: [...new Set(mrKeys.map(projectOfMrKey))].sort(),
        });
      }
      return out;
    },
  };
}

export function createLessonStore(db: DatabaseSync): LessonStore {
  const occurrenceBy = (where: string, ...args: (string | number)[]): OccurrenceRow | undefined => {
    const row = db
      .prepare(`SELECT ${OCCURRENCE_COLUMNS} FROM lesson_occurrence WHERE ${where} LIMIT 1`)
      .get(...args);
    return row === undefined ? undefined : toOccurrence(row);
  };
  let depth = 0;
  /** One transaction; a call inside another joins it. */
  const inTransaction = (work: () => void): void => {
    if (depth > 0) {
      work();
      return;
    }
    db.exec("BEGIN IMMEDIATE");
    depth += 1;
    try {
      work();
      db.exec("COMMIT");
    } catch (error) {
      db.exec("ROLLBACK");
      throw error;
    } finally {
      depth -= 1;
    }
  };

  return {
    ...createReads(db),
    transaction: inTransaction,
    addOccurrences(rows) {
      const insert = db.prepare(
        `INSERT OR IGNORE INTO lesson_occurrence
           (source_key, source, mr_key, mr_title, mr_url, repo_path, path, line, severity, title,
            text, outcome, failures, at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)`,
      );
      let inserted = 0;
      inTransaction(() => {
        for (const row of rows) {
          const result = insert.run(
            row.sourceKey,
            row.source,
            row.mrKey,
            row.mrTitle,
            row.mrUrl,
            row.repoPath ?? null,
            row.path,
            row.line,
            row.severity,
            row.title,
            row.text,
            row.outcome,
            row.at,
            row.at,
          );
          inserted += Number(result.changes);
        }
      });
      return inserted;
    },
    setOutcome(sourceKey, outcome, at) {
      db.prepare(
        "UPDATE lesson_occurrence SET outcome = ?, updated_at = ? WHERE source_key = ?",
      ).run(outcome, at, sourceKey);
    },
    findOccurrenceByLocation(mrKey, path, title) {
      return occurrenceBy(
        "mr_key = ? AND path = ? AND lower(trim(title)) = lower(trim(?)) ORDER BY id DESC",
        mrKey,
        path,
        title,
      );
    },
    pendingOccurrences(now, limit, mrKey) {
      const ofMr = mrKey === undefined ? "" : " AND mr_key = ?";
      return db
        .prepare(
          `SELECT ${OCCURRENCE_COLUMNS} FROM lesson_occurrence
           WHERE lesson_id IS NULL AND (retry_at IS NULL OR retry_at <= ?)${ofMr}
           ORDER BY at, id LIMIT ?`,
        )
        .all(now, ...(mrKey === undefined ? [] : [mrKey]), limit)
        .map(toOccurrence);
    },
    pendingMrKeys(now) {
      return db
        .prepare(
          `SELECT mr_key FROM lesson_occurrence
           WHERE lesson_id IS NULL AND (retry_at IS NULL OR retry_at <= ?)
           GROUP BY mr_key ORDER BY MIN(at), MIN(id)`,
        )
        .all(now)
        .map((row) => text(row, "mr_key"));
    },
    failBatch(ids, retryAt) {
      if (ids.length === 0) return;
      db.prepare(
        `UPDATE lesson_occurrence SET failures = failures + 1, retry_at = ?
         WHERE id IN (${placeholders(ids.length)})`,
      ).run(retryAt, ...ids);
    },
    createLesson(fields, at) {
      const result = db
        .prepare(
          `INSERT INTO lesson (scope, title, rule, topics, globs, archived, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, 0, ?, ?)`,
        )
        .run(
          fields.scope,
          fields.title,
          fields.rule,
          JSON.stringify(fields.topics),
          JSON.stringify(fields.globs),
          at,
          at,
        );
      return Number(result.lastInsertRowid);
    },
    attach(occurrenceIds, lessonId, at) {
      if (occurrenceIds.length === 0) return;
      inTransaction(() => {
        db.prepare(
          `UPDATE lesson_occurrence SET lesson_id = ?, retry_at = NULL, updated_at = ?
           WHERE id IN (${placeholders(occurrenceIds.length)})`,
        ).run(lessonId, at, ...occurrenceIds);
        db.prepare("UPDATE lesson SET updated_at = ? WHERE id = ?").run(at, lessonId);
      });
    },
    occurrenceBySource(sourceKey) {
      return occurrenceBy("source_key = ?", sourceKey);
    },
    setScope(lessonId, scope, at) {
      db.prepare("UPDATE lesson SET scope = ?, updated_at = ? WHERE id = ?").run(
        scope,
        at,
        lessonId,
      );
    },
    allLessons() {
      return db.prepare("SELECT * FROM lesson ORDER BY id").all().map(toLesson);
    },
    setRepoPath(occurrenceId, repoPath) {
      db.prepare("UPDATE lesson_occurrence SET repo_path = ? WHERE id = ?").run(
        repoPath,
        occurrenceId,
      );
    },
    unlink(a, b) {
      db.prepare("DELETE FROM lesson_link WHERE a = ? AND b = ?").run(
        Math.min(a, b),
        Math.max(a, b),
      );
    },
    link(a, b) {
      if (a === b) return;
      db.prepare("INSERT OR IGNORE INTO lesson_link (a, b) VALUES (?, ?)").run(
        Math.min(a, b),
        Math.max(a, b),
      );
    },
    archive(id, at) {
      db.prepare("UPDATE lesson SET archived = 1, updated_at = ? WHERE id = ?").run(at, id);
    },
    merge(keepId, goneId, at) {
      if (keepId === goneId) return;
      inTransaction(() => {
        db.prepare(
          "UPDATE lesson_occurrence SET lesson_id = ?, updated_at = ? WHERE lesson_id = ?",
        ).run(keepId, at, goneId);
        const others = db
          .prepare(
            "SELECT CASE WHEN a = ? THEN b ELSE a END AS other FROM lesson_link WHERE a = ? OR b = ?",
          )
          .all(goneId, goneId, goneId)
          .map((row) => integer(row, "other"));
        db.prepare("DELETE FROM lesson_link WHERE a = ? OR b = ?").run(goneId, goneId);
        const insert = db.prepare("INSERT OR IGNORE INTO lesson_link (a, b) VALUES (?, ?)");
        for (const other of others) {
          if (other !== keepId) insert.run(Math.min(keepId, other), Math.max(keepId, other));
        }
        db.prepare("DELETE FROM lesson WHERE id = ?").run(goneId);
        db.prepare("UPDATE lesson SET updated_at = ? WHERE id = ?").run(at, keepId);
      });
    },
    meta(key) {
      const row = db.prepare("SELECT value FROM meta WHERE key = ?").get(key);
      return row === undefined ? undefined : text(row, "value");
    },
    setMeta(key, value) {
      db.prepare(
        "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
      ).run(key, value);
    },
  };
}

/** Opens the lessons for reading only, without touching the schema; undefined if it cannot. */
export function openLessonsReadOnly(statePath: string): LessonReader | undefined {
  if (!existsSync(statePath)) return undefined;
  let db: DatabaseSync;
  try {
    db = new DatabaseSync(statePath, { readOnly: true, timeout: 200 });
  } catch {
    return undefined;
  }
  // A database from before the lessons tables (or not Suica's at all) has nothing to read.
  try {
    const table = db
      .prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'lesson'")
      .get();
    if (table === undefined) {
      db.close();
      return undefined;
    }
  } catch {
    db.close();
    return undefined;
  }
  return { ...createReads(db), db, close: () => db.close() };
}
