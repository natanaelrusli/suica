import type { DatabaseSync } from "node:sqlite";
import { z } from "zod";
import type { Person } from "./domain.ts";
import { integer, nullableInteger, nullableText, parseActivity, text } from "./sql-row.ts";
import type { ActivityLine, Row } from "./sql-row.ts";

export const FIX_STATUSES = [
  "queued",
  "running",
  "ready",
  "confirming",
  "pushed",
  "push-failed",
  "discarded",
  "failed",
  "skipped",
  "cancelled",
] as const;
export type FixStatus = (typeof FIX_STATUSES)[number];
export type FixTrigger = "auto" | "manual";

/** A Finding Thread as a fix sees it, with the model's answer once it ran. */
export interface FixThread {
  /** The GitLab discussion id (gid://gitlab/Discussion/…). */
  readonly id: string;
  /** The thread's newest note when the fix took it; the thread is handled at this note. */
  readonly noteId: string;
  /** Who started the thread. */
  readonly author: Person;
  readonly filePath: string | null;
  readonly line: number | null;
  readonly notes: readonly { author: Person; body: string; createdAt: string }[];
  /** changed: the code changed for it; reply: only a reply; null until the model answered. */
  readonly action: "changed" | "reply" | null;
  /** The reply to post; `{{sha}}` becomes the short pushed commit. */
  readonly reply: string;
  /** Whether Confirm posts the reply. */
  readonly post: boolean;
  /** True once the reply is on GitLab. */
  readonly posted: boolean;
}

/** One failed job of a Pipeline Fix's pipeline; its log is never kept. */
export interface FixJob {
  readonly name: string;
  readonly stage: string;
  readonly url: string;
}

/** The failed pipeline a Pipeline Fix works on. */
export interface FixPipeline {
  /** GitLab's per-project pipeline number, as text. */
  readonly iid: string;
  readonly url: string;
  /** The commit it ran on; null until the run read the pipeline. */
  readonly sha: string | null;
  /** The failed jobs the run read; empty until then. */
  readonly jobs: readonly FixJob[];
  /** The model's sentence: why the jobs failed and what it changed. Empty until it answered. */
  readonly summary: string;
}

/** The head pipeline an MR had at the last poll. */
export interface PipelineMark {
  readonly iid: string;
  readonly status: string;
}

/** One Agent Fix of one MR, from queued to pushed or dropped. */
export interface FixRow {
  readonly id: number;
  readonly mrKey: string;
  readonly mrTitle: string | null;
  readonly trigger: FixTrigger;
  readonly status: FixStatus;
  readonly threads: readonly FixThread[];
  /** The failed pipeline it fixes; null for a fix of threads only. */
  readonly pipeline: FixPipeline | null;
  /** The Owner's note for a retry; empty otherwise. */
  readonly note: string;
  /** The commit the fix was made on; null until the checkout. */
  readonly baseSha: string | null;
  readonly commitMessage: string;
  /** `git diff --cached --binary` of the change; null until ready, and empty for a reply-only fix. */
  readonly diff: string | null;
  readonly pushedSha: string | null;
  readonly cli: string | null;
  readonly model: string | null;
  /** Why it failed, was skipped or cancelled, or a note about the push. */
  readonly detail: string;
  readonly activity: readonly ActivityLine[];
  readonly createdAt: number;
  readonly updatedAt: number;
  readonly startedAt: number | null;
}

export type FixFields = Partial<
  Pick<
    FixRow,
    | "mrTitle"
    | "threads"
    | "pipeline"
    | "baseSha"
    | "commitMessage"
    | "diff"
    | "pushedSha"
    | "cli"
    | "model"
    | "detail"
    | "startedAt"
  >
>;

export interface FixStore {
  /**
   * Adds the threads (and the pipeline, which replaces one already there) to the MR's queued fix
   * (a thread already there takes the newer note), or queues a new fix; undefined while the MR
   * has a fix that is running, ready or confirming.
   */
  queue(
    mrKey: string,
    trigger: FixTrigger,
    threads: readonly FixThread[],
    now: number,
    mrTitle?: string,
    note?: string,
    pipeline?: FixPipeline,
  ): number | undefined;
  get(id: number): FixRow | undefined;
  nextQueued(): FixRow | undefined;
  /** The MR's fix that is queued, running, ready or confirming. */
  open(mrKey: string): FixRow | undefined;
  /** Every open fix and every fix updated since `since`, newest first. */
  list(since: number): FixRow[];
  latestByMr(): Map<string, FixRow>;
  /** Only from one of `from`; false when the row was elsewhere, so two callers never both win. */
  transition(
    id: number,
    from: readonly FixStatus[],
    to: FixStatus,
    fields: FixFields,
    now: number,
  ): boolean;
  /** Adds a line to a running fix's activity; does nothing once it stopped running. */
  appendActivity(id: number, at: number, text: string): void;
  countAuto(since: number): number;
  /** Puts a running fix back in the queue, as if it never started. */
  requeue(id: number, now: number): boolean;
  /** The newest note id each thread of the MR was handled at. */
  handledNotes(mrKey: string): Map<string, string>;
  markHandled(mrKey: string, threads: readonly { id: string; noteId: string }[]): void;
  interruptedRunning(): FixRow[];
  /** When the watcher last read the threads of each of the Owner's MRs. */
  watchMarks(): Map<string, number>;
  markWatched(mrKey: string, at: number): void;
  /** Forgets that the MR was read, so the watcher reads it again. */
  unwatch(mrKey: string): void;
  /** The head pipeline each of the Owner's MRs had at the last poll. */
  pipelineMarks(): Map<string, PipelineMark>;
  /** Records each MR's head pipeline and forgets the MRs left out. */
  savePipelineMarks(marks: ReadonlyMap<string, PipelineMark>): void;
}

const OPEN: readonly FixStatus[] = ["queued", "running", "ready", "confirming"];
const DONE: readonly FixStatus[] = [
  "pushed",
  "push-failed",
  "discarded",
  "failed",
  "skipped",
  "cancelled",
];
const RETENTION_MS = 90 * 24 * 3_600_000;
const ACTIVITY_LINES = 50;

const personSchema = z.object({ username: z.string(), name: z.string() });
const threadsSchema = z.array(
  z.object({
    id: z.string(),
    noteId: z.string(),
    author: personSchema,
    filePath: z.string().nullable(),
    line: z.number().nullable(),
    notes: z.array(z.object({ author: personSchema, body: z.string(), createdAt: z.string() })),
    action: z.enum(["changed", "reply"]).nullable(),
    reply: z.string(),
    post: z.boolean(),
    posted: z.boolean(),
  }),
);

const pipelineSchema = z.object({
  iid: z.string(),
  url: z.string(),
  sha: z.string().nullable(),
  jobs: z.array(z.object({ name: z.string(), stage: z.string(), url: z.string() })),
  summary: z.string(),
});

function parsePipeline(value: unknown): FixPipeline | null {
  if (typeof value !== "string") return null;
  try {
    const parsed = pipelineSchema.safeParse(JSON.parse(value));
    return parsed.success ? parsed.data : null;
  } catch {
    return null;
  }
}

function isFixStatus(value: string): value is FixStatus {
  return (FIX_STATUSES as readonly string[]).includes(value);
}

function parseThreads(value: unknown): FixThread[] {
  if (typeof value !== "string") return [];
  try {
    const parsed = threadsSchema.safeParse(JSON.parse(value));
    return parsed.success ? parsed.data : [];
  } catch {
    return [];
  }
}

function toFixRow(row: Row): FixRow {
  const status = text(row, "status");
  const trigger = text(row, "trigger");
  if (!isFixStatus(status) || (trigger !== "auto" && trigger !== "manual")) {
    throw new Error("fix row has an unknown status or trigger");
  }
  return {
    id: integer(row, "id"),
    mrKey: text(row, "mr_key"),
    mrTitle: nullableText(row, "mr_title"),
    trigger,
    status,
    threads: parseThreads(row["threads"]),
    pipeline: parsePipeline(row["pipeline"]),
    note: text(row, "note"),
    baseSha: nullableText(row, "base_sha"),
    commitMessage: text(row, "commit_message"),
    diff: nullableText(row, "diff"),
    pushedSha: nullableText(row, "pushed_sha"),
    cli: nullableText(row, "cli"),
    model: nullableText(row, "model"),
    detail: text(row, "detail"),
    activity: parseActivity(row["activity"]),
    createdAt: integer(row, "created_at"),
    updatedAt: integer(row, "updated_at"),
    startedAt: nullableInteger(row, "started_at"),
  };
}

const marks = (values: readonly unknown[]): string => values.map(() => "?").join(", ");
const toJson = (value: FixPipeline | null): string | null =>
  value === null ? null : JSON.stringify(value);

/** Merges `added` into `threads` by id; an added thread replaces one with the same id. */
function mergeThreads(threads: readonly FixThread[], added: readonly FixThread[]): FixThread[] {
  const byId = new Map(threads.map((each) => [each.id, each]));
  for (const each of added) byId.set(each.id, each);
  return [...byId.values()];
}

export function createFixStore(db: DatabaseSync): FixStore {
  const one = (sql: string, ...params: (string | number)[]): FixRow | undefined => {
    const row = db.prepare(sql).get(...params);
    return row === undefined ? undefined : toFixRow(row);
  };
  const many = (sql: string, ...params: (string | number)[]): FixRow[] =>
    db
      .prepare(sql)
      .all(...params)
      .map(toFixRow);
  const openFix = (mrKey: string): FixRow | undefined =>
    one(
      `SELECT * FROM fix_run WHERE mr_key = ? AND status IN (${marks(OPEN)}) ORDER BY id DESC LIMIT 1`,
      mrKey,
      ...OPEN,
    );

  return {
    queue(mrKey, trigger, threads, now, mrTitle, note = "", pipeline) {
      db.exec("BEGIN IMMEDIATE");
      try {
        const open = openFix(mrKey);
        let id: number | undefined;
        if (open?.status === "queued") {
          // Your request joining an automatic fix makes it yours, with your note.
          db.prepare(
            "UPDATE fix_run SET threads = ?, pipeline = ?, trigger = ?, note = ?, updated_at = ? WHERE id = ?",
          ).run(
            JSON.stringify(mergeThreads(open.threads, threads)),
            toJson(pipeline ?? open.pipeline),
            trigger === "manual" ? "manual" : open.trigger,
            note === "" ? open.note : note,
            now,
            open.id,
          );
          id = open.id;
        } else if (open === undefined) {
          const result = db
            .prepare(
              `INSERT INTO fix_run (mr_key, trigger, status, mr_title, threads, pipeline, note, created_at, updated_at)
               VALUES (?, ?, 'queued', ?, ?, ?, ?, ?, ?)`,
            )
            .run(
              mrKey,
              trigger,
              mrTitle ?? null,
              JSON.stringify(threads),
              toJson(pipeline ?? null),
              note,
              now,
              now,
            );
          id = Number(result.lastInsertRowid);
        }
        db.prepare(`DELETE FROM fix_run WHERE updated_at < ? AND status IN (${marks(DONE)})`).run(
          now - RETENTION_MS,
          ...DONE,
        );
        db.exec("COMMIT");
        return id;
      } catch (error) {
        db.exec("ROLLBACK");
        throw error;
      }
    },

    get(id) {
      return one("SELECT * FROM fix_run WHERE id = ?", id);
    },

    nextQueued() {
      return one("SELECT * FROM fix_run WHERE status = 'queued' ORDER BY id LIMIT 1");
    },

    open: openFix,

    list(since) {
      return many(
        `SELECT * FROM fix_run WHERE status IN (${marks(OPEN)}) OR updated_at >= ? ORDER BY id DESC`,
        ...OPEN,
        since,
      );
    },

    latestByMr() {
      const latest = new Map<string, FixRow>();
      for (const row of many(
        "SELECT * FROM fix_run WHERE id IN (SELECT MAX(id) FROM fix_run GROUP BY mr_key)",
      )) {
        latest.set(row.mrKey, row);
      }
      return latest;
    },

    transition(id, from, to, fields, now) {
      const json = fields.threads === undefined ? null : JSON.stringify(fields.threads);
      const result = db
        .prepare(
          `UPDATE fix_run SET status = ?, mr_title = COALESCE(?, mr_title), threads = COALESCE(?, threads),
             pipeline = COALESCE(?, pipeline), base_sha = COALESCE(?, base_sha), commit_message = COALESCE(?, commit_message),
             diff = COALESCE(?, diff), pushed_sha = COALESCE(?, pushed_sha), cli = COALESCE(?, cli),
             model = COALESCE(?, model), detail = COALESCE(?, detail),
             started_at = COALESCE(?, started_at), updated_at = ?
           WHERE id = ? AND status IN (${marks(from)})`,
        )
        .run(
          to,
          fields.mrTitle ?? null,
          json,
          toJson(fields.pipeline ?? null),
          fields.baseSha ?? null,
          fields.commitMessage ?? null,
          fields.diff ?? null,
          fields.pushedSha ?? null,
          fields.cli ?? null,
          fields.model ?? null,
          fields.detail ?? null,
          fields.startedAt ?? null,
          now,
          id,
          ...from,
        );
      return result.changes > 0;
    },

    appendActivity(id, at, line) {
      const row = db
        .prepare("SELECT activity FROM fix_run WHERE id = ? AND status = 'running'")
        .get(id);
      if (row === undefined) return;
      const activity = [...parseActivity(row["activity"]), { at, text: line }].slice(
        -ACTIVITY_LINES,
      );
      db.prepare("UPDATE fix_run SET activity = ? WHERE id = ? AND status = 'running'").run(
        JSON.stringify(activity),
        id,
      );
    },

    countAuto(since) {
      const row = db
        .prepare("SELECT COUNT(*) AS n FROM fix_run WHERE trigger = 'auto' AND created_at >= ?")
        .get(since);
      return row === undefined ? 0 : integer(row, "n");
    },

    requeue(id, now) {
      return (
        db
          .prepare(
            "UPDATE fix_run SET status = 'queued', started_at = NULL, activity = '[]', updated_at = ? WHERE id = ? AND status = 'running'",
          )
          .run(now, id).changes > 0
      );
    },

    handledNotes(mrKey) {
      return new Map(
        db
          .prepare("SELECT discussion_id, note_id FROM fix_thread WHERE mr_key = ?")
          .all(mrKey)
          .map((row) => [text(row, "discussion_id"), text(row, "note_id")] as const),
      );
    },

    markHandled(mrKey, threads) {
      const upsert = db.prepare(
        "INSERT OR REPLACE INTO fix_thread (mr_key, discussion_id, note_id) VALUES (?, ?, ?)",
      );
      for (const each of threads) upsert.run(mrKey, each.id, each.noteId);
    },

    interruptedRunning() {
      return many("SELECT * FROM fix_run WHERE status = 'running' ORDER BY id");
    },

    watchMarks() {
      return new Map(
        db
          .prepare("SELECT mr_key, checked_at FROM fix_watch")
          .all()
          .map((row) => [text(row, "mr_key"), integer(row, "checked_at")] as const),
      );
    },

    markWatched(mrKey, at) {
      db.prepare("INSERT OR REPLACE INTO fix_watch (mr_key, checked_at) VALUES (?, ?)").run(
        mrKey,
        at,
      );
    },

    unwatch(mrKey) {
      db.prepare("DELETE FROM fix_watch WHERE mr_key = ?").run(mrKey);
    },

    pipelineMarks() {
      return new Map(
        db
          .prepare("SELECT mr_key, pipeline_iid, status FROM pipeline_watch")
          .all()
          .map(
            (row) =>
              [
                text(row, "mr_key"),
                { iid: text(row, "pipeline_iid"), status: text(row, "status") },
              ] as const,
          ),
      );
    },

    savePipelineMarks(marks) {
      db.exec("BEGIN IMMEDIATE");
      try {
        db.exec("DELETE FROM pipeline_watch");
        const insert = db.prepare(
          "INSERT INTO pipeline_watch (mr_key, pipeline_iid, status) VALUES (?, ?, ?)",
        );
        for (const [key, mark] of marks) insert.run(key, mark.iid, mark.status);
        db.exec("COMMIT");
      } catch (error) {
        db.exec("ROLLBACK");
        throw error;
      }
    },
  };
}
