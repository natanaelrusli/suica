import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { describeTool } from "./describe.ts";
import { processesRunning } from "./proc.ts";
import { activityFor, classifyByActivity } from "./status.ts";
import { readTail } from "./tail.ts";
import {
  EXITED_STAY_MS,
  type Adapter,
  type OfficeStatus,
  type ProcInfo,
  type Probe,
  type RawSession,
  type RecentAction,
} from "./types.ts";

const MAX_ACTIONS = 5;
const WINDOWS = [256 * 1024, 1024 * 1024, 4 * 1024 * 1024];

const asRecord = (value: unknown): Record<string, unknown> | undefined =>
  typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;

/** Claude Code's folder for a working folder: every character that is not a letter or digit is `-`. */
export const projectSlug = (cwd: string): string => cwd.replace(/[^a-zA-Z0-9]/g, "-");

function toolActions(lines: readonly string[]): RecentAction[] {
  const actions: RecentAction[] = [];
  for (const line of lines) {
    if (!line.includes('"tool_use"')) continue;
    let entry: Record<string, unknown> | undefined;
    try {
      entry = asRecord(JSON.parse(line));
    } catch {
      continue;
    }
    const content = asRecord(entry?.["message"])?.["content"];
    if (entry?.["type"] !== "assistant" || !Array.isArray(content)) continue;
    const at = Date.parse(typeof entry["timestamp"] === "string" ? entry["timestamp"] : "");
    for (const item of content) {
      const block = asRecord(item);
      if (block?.["type"] !== "tool_use" || typeof block["name"] !== "string") continue;
      actions.push({
        at: Number.isNaN(at) ? 0 : at,
        text: describeTool(block["name"], block["input"]),
      });
    }
  }
  return actions.slice(-MAX_ACTIONS);
}

/** The newest tool calls of a transcript, reading further back while a window holds none. */
function recentActions(path: string, size: number): RecentAction[] {
  for (const bytes of WINDOWS) {
    const actions = toolActions(readTail(path, bytes));
    if (actions.length > 0 || bytes >= size) return actions;
  }
  return [];
}

function transcriptOf(home: string, cwd: string, sessionId: string): string | undefined {
  const path = join(home, ".claude", "projects", projectSlug(cwd), `${sessionId}.jsonl`);
  try {
    statSync(path);
    return path;
  } catch {
    return undefined;
  }
}

function newestTranscript(home: string, cwd: string): { path: string; mtime: number } | undefined {
  const dir = join(home, ".claude", "projects", projectSlug(cwd));
  let best: { path: string; mtime: number } | undefined;
  try {
    for (const name of readdirSync(dir)) {
      if (!name.endsWith(".jsonl")) continue;
      const mtime = statSync(join(dir, name)).mtimeMs;
      if (best === undefined || mtime > best.mtime) best = { path: join(dir, name), mtime };
    }
  } catch {
    return undefined;
  }
  return best;
}

function mapStatus(raw: unknown): OfficeStatus {
  if (raw === "busy") return "working";
  if (typeof raw === "string" && /wait|input|permission|approv/i.test(raw)) return "waiting";
  return "idle";
}

function build(args: {
  readonly sessionId: string;
  readonly cwd: string;
  readonly status: OfficeStatus;
  readonly startedAt: number | null;
  readonly updatedAt: number;
  readonly pid: number | null;
  readonly transcript: string | undefined;
  readonly now: number;
}): RawSession {
  const actions =
    args.transcript === undefined ? [] : recentActions(args.transcript, sizeOf(args.transcript));
  return {
    agent: "claude",
    sessionId: args.sessionId,
    cwd: args.cwd,
    status: args.status,
    activity: activityFor(args.status, actions, args.now),
    recentActions: actions,
    startedAt: args.startedAt,
    updatedAt: args.updatedAt,
    pid: args.pid,
  };
}

function sizeOf(path: string): number {
  try {
    return statSync(path).size;
  } catch {
    return 0;
  }
}

function mtimeOf(path: string | undefined): number {
  if (path === undefined) return 0;
  try {
    return statSync(path).mtimeMs;
  } catch {
    return 0;
  }
}

function readSessionFiles(home: string): Map<number, Record<string, unknown>> {
  const found = new Map<number, Record<string, unknown>>();
  const dir = join(home, ".claude", "sessions");
  let names: string[];
  try {
    names = readdirSync(dir);
  } catch {
    return found;
  }
  for (const name of names) {
    const pid = /^(\d+)\.json$/.exec(name)?.[1];
    if (pid === undefined) continue;
    try {
      const parsed = asRecord(JSON.parse(readFileSync(join(dir, name), "utf8")));
      if (parsed !== undefined) found.set(Number(pid), parsed);
    } catch {
      // A half-written file is read again two seconds later.
    }
  }
  return found;
}

function fromProcess(probe: Probe, proc: ProcInfo): RawSession | undefined {
  const cwd = probe.cwdOf(proc.pid);
  if (cwd === null) return undefined;
  const newest = newestTranscript(probe.home, cwd);
  if (newest === undefined) return undefined;
  const sessionId = newest.path.slice(newest.path.lastIndexOf("/") + 1, -".jsonl".length);
  return build({
    sessionId,
    cwd,
    status: classifyByActivity({ now: probe.now, lastActivityAt: newest.mtime }),
    startedAt: null,
    updatedAt: newest.mtime,
    pid: proc.pid,
    transcript: newest.path,
    now: probe.now,
  });
}

/**
 * Claude Code: `~/.claude/sessions/<pid>.json` lists each running process; the transcript under
 * `~/.claude/projects` has its tool calls. The format is undocumented, so a file without the
 * fields falls back to the process list and the newest transcript of the process's folder.
 */
export const claudeAdapter: Adapter = (probe) => {
  const procs = new Map(probe.processes().map((proc) => [proc.pid, proc]));
  const sessions: RawSession[] = [];
  const handled = new Set<number>();

  for (const [pid, file] of readSessionFiles(probe.home)) {
    const { sessionId, cwd } = file;
    if (typeof sessionId !== "string" || typeof cwd !== "string") continue;
    handled.add(pid);
    const proc = procs.get(pid);
    const alive = probe.pidAlive(pid) && (proc === undefined || /claude/i.test(proc.command));
    const transcript = transcriptOf(probe.home, cwd, sessionId);
    const updatedAt = Math.max(Number(file["updatedAt"]) || 0, mtimeOf(transcript));
    if (!alive && probe.now - updatedAt > EXITED_STAY_MS) continue;
    sessions.push(
      build({
        sessionId,
        cwd,
        status: alive ? mapStatus(file["status"]) : "exited",
        startedAt: typeof file["startedAt"] === "number" ? file["startedAt"] : null,
        updatedAt,
        pid,
        transcript,
        now: probe.now,
      }),
    );
  }

  for (const proc of processesRunning(probe.processes(), "claude")) {
    if (handled.has(proc.pid)) continue;
    const session = fromProcess(probe, proc);
    if (session !== undefined) sessions.push(session);
  }
  return sessions;
};
