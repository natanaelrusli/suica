import { globSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { clip } from "./describe.ts";
import { processesRunning } from "./proc.ts";
import { activityFor, classifyByActivity } from "./status.ts";
import { readTail } from "./tail.ts";
import { LIVE_WINDOW_MS, type Adapter, type RawSession, type RecentAction } from "./types.ts";

export const BUILT_IN_AGENTS = ["claude", "codex", "gemini"] as const;

/** One `office.custom` entry: where another Coding Agent's JSONL logs are and which keys to read. */
export interface CustomAgent {
  readonly name: string;
  /** The program's name, to find it in the process list. */
  readonly process: string;
  readonly glob: string;
  /** Dotted path of the working folder in a log line, e.g. `meta.cwd`. */
  readonly cwdKey: string;
  /** Dotted path of the current activity in a log line. */
  readonly activityKey: string;
}

/** `name|process|log glob|cwd key|activity key`, or the reason it is not one. */
export function parseCustomAgent(text: string): CustomAgent | string {
  const parts = text.split("|").map((part) => part.trim());
  const [name, process, glob, cwdKey, activityKey] = parts;
  if (
    parts.length !== 5 ||
    name === undefined ||
    process === undefined ||
    glob === undefined ||
    cwdKey === undefined ||
    activityKey === undefined
  ) {
    return "must be name|process|log glob|cwd key|activity key";
  }
  if (!/^[a-z][a-z0-9-]*$/.test(name)) return "name must be lower case letters, digits and dashes";
  if ((BUILT_IN_AGENTS as readonly string[]).includes(name)) {
    return `name ${name} is a built-in agent`;
  }
  if ([process, glob, cwdKey, activityKey].includes("")) return "no part may be empty";
  return { name, process, glob, cwdKey, activityKey };
}

const MAX_ACTIONS = 5;
const SCAN_LINES = 400;
/** Quiet logs read per poll while a process runs, to find the one it writes. */
const MAX_STALE_READS = 20;

function lookup(value: unknown, key: string): string | undefined {
  let current: unknown = value;
  for (const part of key.split(".")) {
    if (typeof current !== "object" || current === null) return undefined;
    current = (current as Record<string, unknown>)[part];
  }
  return typeof current === "string" && current !== "" ? current : undefined;
}

/** A log of one more Coding Agent, read by the keys the Owner named. */
export function genericAdapter(agent: CustomAgent): Adapter {
  return (probe) => {
    const pattern = agent.glob.startsWith("~/")
      ? `${probe.home || homedir()}${agent.glob.slice(1)}`
      : agent.glob;
    let files: string[];
    try {
      files = globSync(pattern);
    } catch {
      return [];
    }
    const running = new Set<string>();
    for (const proc of processesRunning(probe.processes(), agent.process)) {
      const cwd = probe.cwdOf(proc.pid);
      if (cwd !== null) running.add(cwd);
    }

    const dated: { file: string; mtime: number }[] = [];
    for (const file of files) {
      try {
        dated.push({ file, mtime: statSync(file).mtimeMs });
      } catch {
        // Removed since the listing.
      }
    }
    dated.sort((a, b) => b.mtime - a.mtime);

    const sessions: RawSession[] = [];
    // A running process keeps one Desk: its folder's newest log, not every old log of the folder.
    const claimed = new Set<string>();
    let staleRead = 0;
    for (const { file, mtime } of dated) {
      const recent = probe.now - mtime <= LIVE_WINDOW_MS;
      if (!recent && (running.size === 0 || staleRead >= MAX_STALE_READS)) continue;
      if (!recent) staleRead += 1;
      let cwd: string | undefined;
      const actions: RecentAction[] = [];
      for (const line of readTail(file, 256 * 1024).slice(-SCAN_LINES)) {
        let entry: unknown;
        try {
          entry = JSON.parse(line);
        } catch {
          continue;
        }
        cwd = lookup(entry, agent.cwdKey) ?? cwd;
        const text = lookup(entry, agent.activityKey);
        if (text !== undefined) actions.push({ at: mtime, text: clip(text, 80) });
      }
      if (cwd === undefined) continue;
      if (!recent && (!running.has(cwd) || claimed.has(cwd))) continue;
      claimed.add(cwd);
      const status = classifyByActivity({ now: probe.now, lastActivityAt: mtime });
      const recentActions = actions.slice(-MAX_ACTIONS);
      sessions.push({
        agent: agent.name,
        sessionId: file,
        title: null,
        cwd,
        status,
        activity: activityFor(status, recentActions, probe.now),
        recentActions,
        startedAt: null,
        updatedAt: mtime,
        pid: null,
      });
    }
    return sessions;
  };
}
