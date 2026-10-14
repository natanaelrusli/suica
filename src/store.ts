import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { DatabaseSync } from "node:sqlite";
import type { Snapshot } from "./domain.ts";
import { myReviewState, reviewerKey } from "./events.ts";
import type { PreviousState } from "./events.ts";

export interface Store {
  load(): PreviousState;
  /** Replaces the stored state with `snapshot` in one transaction and marks the baseline as done. */
  commit(snapshot: Snapshot): void;
  isPaused(): boolean;
  setPaused(paused: boolean): void;
  close(): void;
}

const SCHEMA_VERSION = 1;
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
const BUSY_TIMEOUT_MS = 5000;

type Row = Record<string, unknown>;

function text(row: Row, column: string): string {
  const value = row[column];
  if (typeof value !== "string") throw new Error(`column ${column} is not text`);
  return value;
}

function initSchema(db: DatabaseSync): void {
  const found = db.prepare("PRAGMA user_version").get()?.["user_version"];
  const version = typeof found === "number" ? found : 0;
  if (version > SCHEMA_VERSION) {
    throw new Error(`state database schema ${version} is newer than supported ${SCHEMA_VERSION}`);
  }
  if (version === 0) {
    db.exec(SCHEMA);
    db.exec(`PRAGMA user_version = ${SCHEMA_VERSION}`);
  }
}

export function openStore(path: string): Store {
  if (path !== ":memory:") mkdirSync(dirname(path), { recursive: true, mode: DIRECTORY_MODE });
  const db = new DatabaseSync(path);
  try {
    db.exec(`PRAGMA journal_mode = WAL; PRAGMA busy_timeout = ${BUSY_TIMEOUT_MS};`);
    initSchema(db);
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

    commit(snapshot) {
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
        setMeta(META_BASELINE, "1");
        db.exec("COMMIT");
      } catch (error) {
        db.exec("ROLLBACK");
        throw error;
      }
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
