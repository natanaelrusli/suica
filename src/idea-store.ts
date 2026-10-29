import type { DatabaseSync } from "node:sqlite";
import { integer, nullableInteger, nullableText, text } from "./sql-row.ts";

export const MAX_IDEA_TEXT_LENGTH = 100_000;
export const MAX_IDEA_NOTE_LENGTH = 100_000;
export const MAX_IDEA_PROJECT_PATH_LENGTH = 4_096;

export interface IdeaNote {
  readonly id: number;
  readonly text: string;
  readonly createdAt: number;
}

export interface IdeaSessionLink {
  readonly agent: string;
  readonly sessionId: string;
  readonly linkedAt: number;
}

export interface Idea {
  readonly id: number;
  readonly text: string;
  readonly projectPath: string | null;
  readonly createdAt: number;
  readonly updatedAt: number;
  readonly archivedAt: number | null;
  readonly revision: number;
  readonly notes: readonly IdeaNote[];
  readonly planPaths: readonly string[];
  readonly sessions: readonly IdeaSessionLink[];
}

export class IdeaStoreError extends Error {
  readonly code: "bad-request" | "not-found" | "conflict";

  constructor(code: "bad-request" | "not-found" | "conflict", message: string) {
    super(message);
    this.code = code;
    this.name = "IdeaStoreError";
  }
}

export interface IdeaStore {
  list(options?: { archived?: boolean; search?: string }): Idea[];
  show(id: number): Idea | undefined;
  create(input: { text: string; projectPath?: string | null }, now?: number): Idea;
  update(
    id: number,
    input: { revision: number; text: string; projectPath?: string | null },
    now?: number,
  ): { status: "ok"; idea: Idea } | { status: "conflict"; idea: Idea };
  archive(id: number, now?: number): Idea | undefined;
  restore(id: number, now?: number): Idea | undefined;
  addNote(id: number, noteText: string, now?: number): Idea | undefined;
  linkPlan(id: number, path: string, now?: number): Idea | undefined;
  linkSession(id: number, agent: string, sessionId: string, now?: number): Idea | undefined;
}

function validateText(value: unknown, max: number, label: string): asserts value is string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new IdeaStoreError("bad-request", `${label} must not be empty`);
  }
  if (value.length > max) {
    throw new IdeaStoreError("bad-request", `${label} exceeds ${max} characters`);
  }
}

function validateProjectPath(value: unknown): string | null {
  if (value === undefined || value === null || value === "") return null;
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new IdeaStoreError("bad-request", "projectPath must be a path or null");
  }
  if (value.length > MAX_IDEA_PROJECT_PATH_LENGTH) {
    throw new IdeaStoreError("bad-request", "projectPath exceeds 4096 characters");
  }
  return value;
}

export function createIdeaStore(db: DatabaseSync): IdeaStore {
  const show = (id: number): Idea | undefined => {
    const row = db.prepare("SELECT * FROM idea WHERE id = ?").get(id);
    if (row === undefined) return undefined;
    const notes = db
      .prepare(
        "SELECT id, text, created_at FROM idea_note WHERE idea_id = ? ORDER BY created_at, id",
      )
      .all(id)
      .map((note) => ({
        id: integer(note, "id"),
        text: text(note, "text"),
        createdAt: integer(note, "created_at"),
      }));
    const planPaths = db
      .prepare("SELECT path FROM idea_plan WHERE idea_id = ? ORDER BY path COLLATE NOCASE, path")
      .all(id)
      .map((link) => text(link, "path"));
    const sessions = db
      .prepare(
        "SELECT agent, session_id, linked_at FROM idea_session WHERE idea_id = ? ORDER BY linked_at, agent, session_id",
      )
      .all(id)
      .map((link) => ({
        agent: text(link, "agent"),
        sessionId: text(link, "session_id"),
        linkedAt: integer(link, "linked_at"),
      }));
    return {
      id: integer(row, "id"),
      text: text(row, "text"),
      projectPath: nullableText(row, "project_path"),
      createdAt: integer(row, "created_at"),
      updatedAt: integer(row, "updated_at"),
      archivedAt: nullableInteger(row, "archived_at"),
      revision: integer(row, "revision"),
      notes,
      planPaths,
      sessions,
    };
  };

  return {
    list(options = {}) {
      const conditions = ["archived_at IS " + (options.archived ? "NOT NULL" : "NULL")];
      const args: (string | number)[] = [];
      if (options.search !== undefined && options.search.length > 0) {
        const like = `%${options.search.replace(/[\\%_]/g, "\\$&")}%`;
        conditions.push(
          "(idea.text LIKE ? ESCAPE '\\' COLLATE NOCASE OR EXISTS (SELECT 1 FROM idea_note n WHERE n.idea_id = idea.id AND n.text LIKE ? ESCAPE '\\' COLLATE NOCASE))",
        );
        args.push(like, like);
      }
      const ids = db
        .prepare(
          `SELECT idea.id FROM idea WHERE ${conditions.join(" AND ")} ORDER BY idea.updated_at DESC, idea.id DESC`,
        )
        .all(...args)
        .map((row) => integer(row, "id"));
      const ideas: Idea[] = [];
      for (const id of ids) {
        const idea = show(id);
        if (idea !== undefined) ideas.push(idea);
      }
      return ideas;
    },
    show,
    create(input, now = Date.now()) {
      validateText(input.text, MAX_IDEA_TEXT_LENGTH, "text");
      const projectPath = validateProjectPath(input.projectPath);
      const result = db
        .prepare(
          "INSERT INTO idea (text, project_path, created_at, updated_at, revision) VALUES (?, ?, ?, ?, 1)",
        )
        .run(input.text, projectPath, now, now);
      const idea = show(Number(result.lastInsertRowid));
      if (idea === undefined) throw new Error("created idea could not be read");
      return idea;
    },
    update(id, input, now = Date.now()) {
      validateText(input.text, MAX_IDEA_TEXT_LENGTH, "text");
      const projectPath = validateProjectPath(input.projectPath);
      const current = show(id);
      if (current === undefined) throw new IdeaStoreError("not-found", "idea not found");
      if (!Number.isSafeInteger(input.revision) || input.revision < 1) {
        throw new IdeaStoreError("bad-request", "revision must be a positive integer");
      }
      if (current.revision !== input.revision) return { status: "conflict", idea: current };
      const result = db
        .prepare(
          "UPDATE idea SET text = ?, project_path = ?, updated_at = ?, revision = revision + 1 WHERE id = ? AND revision = ?",
        )
        .run(input.text, projectPath, now, id, input.revision);
      if (Number(result.changes) !== 1) {
        const latest = show(id);
        if (latest === undefined) throw new IdeaStoreError("not-found", "idea not found");
        return { status: "conflict", idea: latest };
      }
      const idea = show(id);
      if (idea === undefined) throw new IdeaStoreError("not-found", "idea not found");
      return { status: "ok", idea };
    },
    archive(id, now = Date.now()) {
      db.prepare(
        "UPDATE idea SET archived_at = ?, updated_at = ? WHERE id = ? AND archived_at IS NULL",
      ).run(now, now, id);
      return show(id);
    },
    restore(id, now = Date.now()) {
      db.prepare(
        "UPDATE idea SET archived_at = NULL, updated_at = ? WHERE id = ? AND archived_at IS NOT NULL",
      ).run(now, id);
      return show(id);
    },
    addNote(id, noteText, now = Date.now()) {
      validateText(noteText, MAX_IDEA_NOTE_LENGTH, "note text");
      if (show(id) === undefined) return undefined;
      db.prepare("INSERT INTO idea_note (idea_id, text, created_at) VALUES (?, ?, ?)").run(
        id,
        noteText,
        now,
      );
      db.prepare("UPDATE idea SET updated_at = ? WHERE id = ?").run(now, id);
      return show(id);
    },
    linkPlan(id, path, now = Date.now()) {
      validateText(path, MAX_IDEA_PROJECT_PATH_LENGTH, "plan path");
      if (show(id) === undefined) return undefined;
      const result = db
        .prepare("INSERT OR IGNORE INTO idea_plan (idea_id, path) VALUES (?, ?)")
        .run(id, path);
      if (Number(result.changes))
        db.prepare("UPDATE idea SET updated_at = ? WHERE id = ?").run(now, id);
      return show(id);
    },
    linkSession(id, agent, sessionId, now = Date.now()) {
      validateText(agent, 100, "agent");
      validateText(sessionId, 4_096, "sessionId");
      if (show(id) === undefined) return undefined;
      const result = db
        .prepare(
          "INSERT OR IGNORE INTO idea_session (idea_id, agent, session_id, linked_at) VALUES (?, ?, ?, ?)",
        )
        .run(id, agent, sessionId, now);
      if (Number(result.changes))
        db.prepare("UPDATE idea SET updated_at = ? WHERE id = ?").run(now, id);
      return show(id);
    },
  };
}

export function parseIdeaId(value: string | undefined): number | undefined {
  if (value === undefined || !/^\d+$/.test(value)) return undefined;
  const id = Number(value);
  return Number.isSafeInteger(id) && id > 0 ? id : undefined;
}

export function validIdeaIdList(ids: unknown): number[] | undefined {
  if (!Array.isArray(ids) || ids.length === 0 || ids.length > 100) return undefined;
  if (ids.some((id) => typeof id !== "number" || !Number.isSafeInteger(id) || id < 1))
    return undefined;
  return [...new Set(ids as number[])];
}
