// A log of the Lessons handed to Coding Agents, one JSON line per delivery in
// `<dir>/YYYY-MM-DD.jsonl` (UTC day of `at`). Files, not the state database: the hook and the MCP
// server open that read-only, and the hook must never stall a Read or an Edit. Every failure is
// swallowed: a missing entry never costs the agent its Lessons.
import { appendFileSync, mkdirSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { join } from "node:path";

export type UsageSource = "session" | "read" | "edit" | "mcp";

const SOURCES: readonly string[] = ["session", "read", "edit", "mcp"];

export interface UsageEntry {
  readonly at: number;
  /** The repo's `group/sub/project`; null for a session started outside any repo. */
  readonly project: string | null;
  readonly scope: string;
  readonly source: UsageSource;
  /** The MCP tool, mcp only. */
  readonly tool?: string;
  /** Hook only, and only when it is safe as a file name. */
  readonly sessionId?: string;
  /** Repo-relative. */
  readonly file?: string;
  readonly lessonIds: readonly number[];
  readonly tokens: number;
}

export interface UsageLog {
  append(entry: UsageEntry): void;
}

export const USAGE_DAYS = 30;
const DAY_MS = 86_400_000;
const DAY_FILE = /^(\d{4}-\d{2}-\d{2})\.jsonl$/;

/** Four characters a token, like the learner's token cap; an estimate, not a tokenizer count. */
export function estimateTokens(text: string): number {
  return Math.ceil(text.length / 4);
}

function dayOf(at: number): string {
  return new Date(at).toISOString().slice(0, 10);
}

/** Appends entries; day files older than USAGE_DAYS are removed when the log is opened. */
export function fileUsageLog(dir: string, now: number): UsageLog {
  try {
    const oldest = dayOf(now - USAGE_DAYS * DAY_MS);
    for (const name of readdirSync(dir)) {
      const day = DAY_FILE.exec(name)?.[1];
      if (day === undefined || day >= oldest) continue;
      try {
        rmSync(join(dir, name), { force: true });
      } catch {
        // Gone already, or not ours to remove.
      }
    }
  } catch {
    // No folder yet.
  }
  return {
    append(entry) {
      try {
        mkdirSync(dir, { recursive: true, mode: 0o700 });
        appendFileSync(join(dir, `${dayOf(entry.at)}.jsonl`), `${JSON.stringify(entry)}\n`, {
          mode: 0o600,
        });
      } catch {
        // See above.
      }
    },
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseEntry(line: string): UsageEntry | undefined {
  let raw: unknown;
  try {
    raw = JSON.parse(line);
  } catch {
    return undefined;
  }
  if (!isRecord(raw)) return undefined;
  const { at, project, scope, source, tool, sessionId, file, lessonIds, tokens } = raw;
  if (typeof at !== "number" || !Number.isFinite(at)) return undefined;
  if (project !== null && typeof project !== "string") return undefined;
  if (typeof scope !== "string") return undefined;
  if (typeof source !== "string" || !SOURCES.includes(source)) return undefined;
  if (typeof tokens !== "number" || !Number.isFinite(tokens)) return undefined;
  if (!Array.isArray(lessonIds) || !lessonIds.every((n) => Number.isInteger(n))) return undefined;
  for (const optional of [tool, sessionId, file]) {
    if (optional !== undefined && typeof optional !== "string") return undefined;
  }
  return {
    at,
    project,
    scope,
    source: source as UsageSource,
    ...(typeof tool === "string" ? { tool } : {}),
    ...(typeof sessionId === "string" ? { sessionId } : {}),
    ...(typeof file === "string" ? { file } : {}),
    lessonIds: lessonIds as number[],
    tokens,
  };
}

/** The entries at or after `since`, oldest first; a malformed line or an unreadable file is skipped. */
export function readUsage(dir: string, since: number): UsageEntry[] {
  let names: string[];
  try {
    names = readdirSync(dir);
  } catch {
    return [];
  }
  const first = dayOf(since);
  const entries: UsageEntry[] = [];
  for (const name of names) {
    const day = DAY_FILE.exec(name)?.[1];
    if (day === undefined || day < first) continue;
    try {
      for (const line of readFileSync(join(dir, name), "utf8").split("\n")) {
        const entry = line === "" ? undefined : parseEntry(line);
        if (entry !== undefined && entry.at >= since) entries.push(entry);
      }
    } catch {
      // Unreadable: skip the file.
    }
  }
  return entries.sort((a, b) => a.at - b.at);
}

export interface UsageTotalsJson {
  readonly deliveries: number;
  readonly sessions: number;
  readonly tokens: number;
  readonly lessons: number;
}

export interface UsageLessonJson {
  readonly id: number;
  readonly title: string | null;
  readonly times: number;
}

export interface UsageProjectJson extends UsageTotalsJson {
  readonly project: string | null;
  readonly scope: string;
  readonly bySource: Readonly<Record<UsageSource, number>>;
  readonly lastAt: number;
  readonly topLessons: readonly UsageLessonJson[];
}

/** The document `suica lessons usage --json` prints (`usage` in contracts/lessons.v1.json). */
export interface LessonUsageJson {
  readonly version: 1;
  readonly generatedAt: number;
  readonly days: number;
  readonly totals: UsageTotalsJson;
  readonly projects: readonly UsageProjectJson[];
  readonly recent: readonly UsageEntry[];
}

const TOP_LESSONS = 20;
const RECENT = 100;

function totalsOf(entries: readonly UsageEntry[]): UsageTotalsJson {
  return {
    deliveries: entries.length,
    sessions: new Set(entries.flatMap((e) => (e.sessionId === undefined ? [] : [e.sessionId])))
      .size,
    tokens: entries.reduce((sum, e) => sum + e.tokens, 0),
    lessons: new Set(entries.flatMap((e) => e.lessonIds)).size,
  };
}

function projectRow(
  entries: readonly UsageEntry[],
  titleOf: (id: number) => string | undefined,
): UsageProjectJson {
  const latest = entries.reduce((a, b) => (b.at >= a.at ? b : a));
  const bySource: Record<UsageSource, number> = { session: 0, read: 0, edit: 0, mcp: 0 };
  const times = new Map<number, number>();
  for (const entry of entries) {
    bySource[entry.source] += 1;
    for (const id of entry.lessonIds) times.set(id, (times.get(id) ?? 0) + 1);
  }
  return {
    project: latest.project,
    scope: latest.scope,
    ...totalsOf(entries),
    bySource,
    lastAt: latest.at,
    topLessons: [...times]
      .sort((a, b) => b[1] - a[1] || a[0] - b[0])
      .slice(0, TOP_LESSONS)
      .map(([id, count]) => ({ id, title: titleOf(id) ?? null, times: count })),
  };
}

/** One row per project, or per scope folder for a session outside any repo, heaviest first. */
export function buildLessonUsage(
  entries: readonly UsageEntry[],
  titleOf: (id: number) => string | undefined,
  now: number,
): LessonUsageJson {
  const rows = new Map<string, UsageEntry[]>();
  for (const entry of entries) {
    const key = entry.project ?? entry.scope;
    rows.set(key, [...(rows.get(key) ?? []), entry]);
  }
  const projects = [...rows]
    .map(([key, group]) => ({ key, row: projectRow(group, titleOf) }))
    .sort((a, b) => b.row.tokens - a.row.tokens || (a.key < b.key ? -1 : a.key > b.key ? 1 : 0))
    .map(({ row }) => row);
  return {
    version: 1,
    generatedAt: now,
    days: USAGE_DAYS,
    totals: totalsOf(entries),
    projects,
    recent: [...entries].sort((a, b) => b.at - a.at).slice(0, RECENT),
  };
}
