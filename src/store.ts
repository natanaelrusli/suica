import { chmodSync, existsSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { DatabaseSync } from "node:sqlite";
import type { Snapshot } from "./domain.ts";
import { myReviewState, reviewerKey } from "./events.ts";
import type { PreviousState } from "./events.ts";
import { isOutboxKind, isOutboxStatus, isTemplateName } from "./teams/types.ts";
import type {
  NudgeRecord,
  OutboxRow,
  OutboxStatus,
  Round,
  TeamsPlan,
  TeamsState,
} from "./teams/types.ts";

export type HistoryKind = "review-requested" | "owner-reviewed" | "reviewer-reviewed" | "activity";

export interface HistoryEvent {
  readonly kind: HistoryKind;
  readonly mrKey: string;
  /** Empty unless `kind` is "reviewer-reviewed". */
  readonly username: string;
  readonly at: number;
}

export interface PollLogEntry {
  readonly at: number;
  readonly status: "ok" | "failed";
  readonly failure: string | null;
  readonly durationMs: number;
}

/** Both lists are ordered by `at`. */
export interface HistoryRows {
  readonly polls: readonly PollLogEntry[];
  readonly events: readonly HistoryEvent[];
}

const HISTORY_KINDS: readonly string[] = [
  "review-requested",
  "owner-reviewed",
  "reviewer-reviewed",
  "activity",
];

function isHistoryKind(value: string): value is HistoryKind {
  return HISTORY_KINDS.includes(value);
}

export interface Store {
  load(): PreviousState;
  /**
   * Replaces the stored state with `snapshot` in one transaction and marks the baseline as done.
   * The `history` rows are inserted in the same transaction.
   */
  commit(snapshot: Snapshot, history?: readonly HistoryEvent[]): void;
  /** Inserts the poll, then forgets poll-log and history rows older than 90 days before it. */
  recordPoll(entry: PollLogEntry): void;
  /** The poll log and the history events at or after `since`, oldest first. */
  loadHistory(since: number): HistoryRows;
  isPaused(): boolean;
  setPaused(paused: boolean): void;
  loadTeams(): TeamsState;
  /**
   * Forgets the review rounds and the Teams baseline. Used while Teams is switched off: the ledger
   * is not maintained then, so the next start must re-seed it instead of announcing the gap.
   */
  resetTeamsBaseline(): void;
  /** Queues the plan's intents (idempotent per `dedupeKey`) and updates the ledger in one transaction. */
  applyTeamsPlan(plan: TeamsPlan, now: number): number;
  listOutbox(statuses: readonly OutboxStatus[]): OutboxRow[];
  getOutbox(id: number): OutboxRow | undefined;
  /** Compare-and-set: true only for the one caller that found the row in `from`. */
  transitionOutbox(
    id: number,
    from: OutboxStatus,
    to: OutboxStatus,
    fields: { detail?: string; text?: string },
    now: number,
  ): boolean;
  loadIdentity(username: string): string | undefined;
  saveIdentity(username: string, email: string, now: number): void;
  close(): void;
}

const SCHEMA_VERSION = 3;
const SCHEMA_V3 = `
CREATE TABLE IF NOT EXISTS poll_log (
  at INTEGER NOT NULL, status TEXT NOT NULL, failure TEXT, duration_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS poll_log_at ON poll_log (at);
CREATE TABLE IF NOT EXISTS history_event (
  kind TEXT NOT NULL, mr_key TEXT NOT NULL, username TEXT NOT NULL, at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS history_event_at ON history_event (at);
`;
const SCHEMA_V2 = `
CREATE TABLE IF NOT EXISTS outbox (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  dedupe_key TEXT NOT NULL UNIQUE,
  kind TEXT NOT NULL,
  variant TEXT NOT NULL,
  mr_key TEXT NOT NULL,
  mr_iid INTEGER NOT NULL,
  mr_project TEXT NOT NULL,
  mr_title TEXT NOT NULL,
  mr_url TEXT NOT NULL,
  recipient TEXT NOT NULL,
  recipient_name TEXT NOT NULL,
  status TEXT NOT NULL,
  detail TEXT NOT NULL DEFAULT '',
  text TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS outbox_status ON outbox (status);
CREATE TABLE IF NOT EXISTS nudge_state (
  key TEXT PRIMARY KEY,
  sent_count INTEGER NOT NULL,
  last_sent_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS review_round (
  mr_key TEXT PRIMARY KEY,
  my_state TEXT NOT NULL,
  my_notes INTEGER NOT NULL,
  changed_at INTEGER NOT NULL,
  noticed_state TEXT NOT NULL,
  noticed_notes INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS identity (
  username TEXT PRIMARY KEY,
  email TEXT NOT NULL,
  resolved_at INTEGER NOT NULL
);
`;
const META_TEAMS_BASELINE = "teams_baseline_done";
const FINISHED_STATUSES = ["sent", "skipped", "failed", "dry-run"] as const;
const OUTBOX_RETENTION_MS = 90 * 24 * 3_600_000;
const HISTORY_RETENTION_MS = 90 * 24 * 3_600_000;
const SCHEMA = `
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS tracked_authored (mr_key TEXT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS my_review_state (mr_key TEXT PRIMARY KEY, state TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS reviewer_state (
  mr_key TEXT NOT NULL,
  username TEXT NOT NULL,
  state TEXT NOT NULL,
  PRIMARY KEY (mr_key, username)
);
CREATE TABLE IF NOT EXISTS seen_note (note_id TEXT PRIMARY KEY);
`;
const META_BASELINE = "baseline_done";
const META_PAUSED = "paused";
const DIRECTORY_MODE = 0o700;
const FILE_MODE = 0o600;
const BUSY_TIMEOUT_MS = 5000;

type Row = Record<string, unknown>;

function text(row: Row, column: string): string {
  const value = row[column];
  if (typeof value !== "string") throw new Error(`column ${column} is not text`);
  return value;
}

function integer(row: Row, column: string): number {
  const value = row[column];
  if (typeof value !== "number") throw new Error(`column ${column} is not an integer`);
  return value;
}

function toOutboxRow(row: Row): OutboxRow {
  const kind = text(row, "kind");
  const variant = text(row, "variant");
  const status = text(row, "status");
  if (!isOutboxKind(kind) || !isTemplateName(variant) || !isOutboxStatus(status)) {
    throw new Error("outbox row has an unknown kind, variant or status");
  }
  const stored = row["text"];
  return {
    id: integer(row, "id"),
    dedupeKey: text(row, "dedupe_key"),
    kind,
    variant,
    mrKey: text(row, "mr_key"),
    mrIid: integer(row, "mr_iid"),
    mrProject: text(row, "mr_project"),
    mrTitle: text(row, "mr_title"),
    mrUrl: text(row, "mr_url"),
    recipient: text(row, "recipient"),
    recipientName: text(row, "recipient_name"),
    status,
    detail: text(row, "detail"),
    text: typeof stored === "string" ? stored : null,
    createdAt: integer(row, "created_at"),
    updatedAt: integer(row, "updated_at"),
  };
}

function toHistoryEvent(row: Row): HistoryEvent {
  const kind = text(row, "kind");
  if (!isHistoryKind(kind)) throw new Error("history row has an unknown kind");
  return {
    kind,
    mrKey: text(row, "mr_key"),
    username: text(row, "username"),
    at: integer(row, "at"),
  };
}

function toPollLogEntry(row: Row): PollLogEntry {
  const status = text(row, "status");
  if (status !== "ok" && status !== "failed") throw new Error("poll log row has an unknown status");
  const failure = row["failure"];
  return {
    at: integer(row, "at"),
    status,
    failure: typeof failure === "string" ? failure : null,
    durationMs: integer(row, "duration_ms"),
  };
}

function initSchema(db: DatabaseSync): void {
  const found = db.prepare("PRAGMA user_version").get()?.["user_version"];
  const version = typeof found === "number" ? found : 0;
  if (version > SCHEMA_VERSION) {
    throw new Error(`state database schema ${version} is newer than supported ${SCHEMA_VERSION}`);
  }
  if (version === 0) db.exec(SCHEMA);
  if (version < 2) db.exec(SCHEMA_V2);
  if (version < 3) db.exec(SCHEMA_V3);
  if (version !== SCHEMA_VERSION) db.exec(`PRAGMA user_version = ${SCHEMA_VERSION}`);
}

/** The database holds employee IDs: keep the folder and every SQLite file private to the owner. */
function restrictPermissions(path: string): void {
  if (path === ":memory:") return;
  chmodSync(dirname(path), DIRECTORY_MODE);
  for (const file of [path, `${path}-wal`, `${path}-shm`]) {
    if (existsSync(file)) chmodSync(file, FILE_MODE);
  }
}

export function openStore(path: string): Store {
  if (path !== ":memory:") mkdirSync(dirname(path), { recursive: true, mode: DIRECTORY_MODE });
  const db = new DatabaseSync(path);
  try {
    db.exec(`PRAGMA journal_mode = WAL; PRAGMA busy_timeout = ${BUSY_TIMEOUT_MS};`);
    initSchema(db);
    restrictPermissions(path);
  } catch (error) {
    db.close();
    throw error;
  }

  const rows = (sql: string): Row[] => db.prepare(sql).all();
  const metaValue = (key: string): string | undefined => {
    const row = db.prepare("SELECT value FROM meta WHERE key = ?").get(key);
    return row === undefined ? undefined : text(row, "value");
  };
  const setMeta = (key: string, value: string): void => {
    db.prepare(
      "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
    ).run(key, value);
  };

  return {
    load() {
      return {
        baselineDone: metaValue(META_BASELINE) === "1",
        trackedAuthored: new Set(
          rows("SELECT mr_key FROM tracked_authored").map((row) => text(row, "mr_key")),
        ),
        myReviewStates: new Map(
          rows("SELECT mr_key, state FROM my_review_state").map(
            (row) => [text(row, "mr_key"), text(row, "state")] as const,
          ),
        ),
        reviewerStates: new Map(
          rows("SELECT mr_key, username, state FROM reviewer_state").map(
            (row) =>
              [
                reviewerKey(text(row, "mr_key"), text(row, "username")),
                text(row, "state"),
              ] as const,
          ),
        ),
        seenNotes: new Set(
          rows("SELECT note_id FROM seen_note").map((row) => text(row, "note_id")),
        ),
      };
    },

    commit(snapshot, history = []) {
      const insertTracked = db.prepare(
        "INSERT OR REPLACE INTO tracked_authored (mr_key) VALUES (?)",
      );
      const insertMine = db.prepare(
        "INSERT OR REPLACE INTO my_review_state (mr_key, state) VALUES (?, ?)",
      );
      const insertReviewer = db.prepare(
        "INSERT OR REPLACE INTO reviewer_state (mr_key, username, state) VALUES (?, ?, ?)",
      );
      const insertNote = db.prepare("INSERT OR REPLACE INTO seen_note (note_id) VALUES (?)");
      const insertEvent = db.prepare(
        "INSERT INTO history_event (kind, mr_key, username, at) VALUES (?, ?, ?, ?)",
      );
      db.exec("BEGIN IMMEDIATE");
      try {
        db.exec(
          "DELETE FROM tracked_authored; DELETE FROM my_review_state; DELETE FROM reviewer_state; DELETE FROM seen_note;",
        );
        for (const mr of snapshot.reviewRequested) {
          if (!mr.draft) insertMine.run(mr.key, myReviewState(snapshot, mr));
        }
        for (const mr of snapshot.authored) {
          if (mr.draft) continue;
          insertTracked.run(mr.key);
          for (const reviewer of mr.reviewers) {
            insertReviewer.run(mr.key, reviewer.username, reviewer.state);
          }
          for (const note of mr.notes) insertNote.run(note.id);
        }
        for (const item of history) insertEvent.run(item.kind, item.mrKey, item.username, item.at);
        setMeta(META_BASELINE, "1");
        db.exec("COMMIT");
      } catch (error) {
        db.exec("ROLLBACK");
        throw error;
      }
      // The -wal and -shm files only exist once something has been written.
      restrictPermissions(path);
    },

    recordPoll(entry) {
      const cutoff = entry.at - HISTORY_RETENTION_MS;
      db.exec("BEGIN IMMEDIATE");
      try {
        db.prepare(
          "INSERT INTO poll_log (at, status, failure, duration_ms) VALUES (?, ?, ?, ?)",
        ).run(entry.at, entry.status, entry.failure, entry.durationMs);
        db.prepare("DELETE FROM poll_log WHERE at < ?").run(cutoff);
        db.prepare("DELETE FROM history_event WHERE at < ?").run(cutoff);
        db.exec("COMMIT");
      } catch (error) {
        db.exec("ROLLBACK");
        throw error;
      }
      restrictPermissions(path);
    },

    loadHistory(since) {
      return {
        polls: db
          .prepare("SELECT * FROM poll_log WHERE at >= ? ORDER BY at, rowid")
          .all(since)
          .map(toPollLogEntry),
        events: db
          .prepare("SELECT * FROM history_event WHERE at >= ? ORDER BY at, rowid")
          .all(since)
          .map(toHistoryEvent),
      };
    },

    loadTeams() {
      const nudges = new Map<string, NudgeRecord>();
      const undelivered = new Set<string>();
      // The time of the latest message is when it was delivered, not when it was queued: a
      // reminder is due a day after the Reviewer could first have read the nudge.
      for (const row of rows(
        `SELECT n.key, n.sent_count, n.last_sent_at, o.status AS status, o.updated_at AS delivered_at
         FROM nudge_state n
         LEFT JOIN outbox o ON o.dedupe_key = 'nudge:' || n.key || ':' || n.sent_count`,
      )) {
        const key = text(row, "key");
        const status = row["status"];
        const delivered = status === "sent" || status === "dry-run";
        if (!delivered) undelivered.add(key);
        nudges.set(key, {
          sentCount: integer(row, "sent_count"),
          lastSentAt: delivered ? integer(row, "delivered_at") : integer(row, "last_sent_at"),
        });
      }
      const rounds = new Map<string, Round>();
      for (const row of rows("SELECT * FROM review_round")) {
        rounds.set(text(row, "mr_key"), {
          myState: text(row, "my_state"),
          myNotes: integer(row, "my_notes"),
          changedAt: integer(row, "changed_at"),
          noticedState: text(row, "noticed_state"),
          noticedNotes: integer(row, "noticed_notes"),
        });
      }
      return { baselineDone: metaValue(META_TEAMS_BASELINE) === "1", nudges, rounds, undelivered };
    },

    resetTeamsBaseline() {
      db.exec("BEGIN IMMEDIATE");
      try {
        db.exec("DELETE FROM review_round");
        db.prepare("DELETE FROM meta WHERE key = ?").run(META_TEAMS_BASELINE);
        db.exec("COMMIT");
      } catch (error) {
        db.exec("ROLLBACK");
        throw error;
      }
    },

    applyTeamsPlan(plan, now) {
      const insertOutbox = db.prepare(
        `INSERT OR IGNORE INTO outbox
           (dedupe_key, kind, variant, mr_key, mr_iid, mr_project, mr_title, mr_url,
            recipient, recipient_name, status, detail, text, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'queued', '', NULL, ?, ?)`,
      );
      const upsertNudge = db.prepare(
        `INSERT INTO nudge_state (key, sent_count, last_sent_at) VALUES (?, ?, ?)
         ON CONFLICT(key) DO UPDATE SET
           sent_count = excluded.sent_count, last_sent_at = excluded.last_sent_at`,
      );
      const upsertRound = db.prepare(
        `INSERT INTO review_round
           (mr_key, my_state, my_notes, changed_at, noticed_state, noticed_notes)
         VALUES (?, ?, ?, ?, ?, ?)
         ON CONFLICT(mr_key) DO UPDATE SET
           my_state = excluded.my_state, my_notes = excluded.my_notes,
           changed_at = excluded.changed_at, noticed_state = excluded.noticed_state,
           noticed_notes = excluded.noticed_notes`,
      );
      db.exec("BEGIN IMMEDIATE");
      try {
        let created = 0;
        for (const item of plan.intents) {
          const result = insertOutbox.run(
            item.dedupeKey,
            item.kind,
            item.variant,
            item.mr.key,
            item.mr.iid,
            item.mr.projectPath,
            item.mr.title,
            item.mr.url,
            item.recipient.username,
            item.recipient.name,
            now,
            now,
          );
          created += Number(result.changes);
        }
        for (const { key, record } of plan.nudgeUpdates) {
          upsertNudge.run(key, record.sentCount, record.lastSentAt);
        }
        for (const { mrKey, round } of plan.roundUpdates) {
          upsertRound.run(
            mrKey,
            round.myState,
            round.myNotes,
            round.changedAt,
            round.noticedState,
            round.noticedNotes,
          );
        }
        const keepNudges = new Set(plan.keepNudges);
        for (const row of rows("SELECT key FROM nudge_state")) {
          const key = text(row, "key");
          if (!keepNudges.has(key)) db.prepare("DELETE FROM nudge_state WHERE key = ?").run(key);
        }
        const keepRounds = new Set(plan.keepRounds);
        for (const row of rows("SELECT mr_key FROM review_round")) {
          const key = text(row, "mr_key");
          if (!keepRounds.has(key)) {
            db.prepare("DELETE FROM review_round WHERE mr_key = ?").run(key);
          }
        }
        db.prepare(
          `DELETE FROM outbox WHERE updated_at < ? AND status IN (${FINISHED_STATUSES.map(() => "?").join(", ")})`,
        ).run(now - OUTBOX_RETENTION_MS, ...FINISHED_STATUSES);
        if (plan.baselineDone) setMeta(META_TEAMS_BASELINE, "1");
        db.exec("COMMIT");
        return created;
      } catch (error) {
        db.exec("ROLLBACK");
        throw error;
      }
    },

    listOutbox(statuses) {
      if (statuses.length === 0) return [];
      const marks = statuses.map(() => "?").join(", ");
      return db
        .prepare(`SELECT * FROM outbox WHERE status IN (${marks}) ORDER BY id`)
        .all(...statuses)
        .map(toOutboxRow);
    },

    getOutbox(id) {
      const row = db.prepare("SELECT * FROM outbox WHERE id = ?").get(id);
      return row === undefined ? undefined : toOutboxRow(row);
    },

    transitionOutbox(id, from, to, fields, now) {
      const result = db
        .prepare(
          `UPDATE outbox SET status = ?, detail = COALESCE(?, detail), text = COALESCE(?, text),
             updated_at = ? WHERE id = ? AND status = ?`,
        )
        .run(to, fields.detail ?? null, fields.text ?? null, now, id, from);
      return Number(result.changes) === 1;
    },

    loadIdentity(username) {
      const row = db.prepare("SELECT email FROM identity WHERE username = ?").get(username);
      return row === undefined ? undefined : text(row, "email");
    },

    saveIdentity(username, email, now) {
      db.prepare(
        `INSERT INTO identity (username, email, resolved_at) VALUES (?, ?, ?)
         ON CONFLICT(username) DO UPDATE SET email = excluded.email, resolved_at = excluded.resolved_at`,
      ).run(username, email, now);
    },

    isPaused: () => metaValue(META_PAUSED) === "1",
    setPaused: (paused) => {
      setMeta(META_PAUSED, paused ? "1" : "0");
    },
    close: () => {
      db.close();
    },
  };
}
