import { readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { describeCommand, describeTool } from "./describe.ts";
import { processesRunning } from "./proc.ts";
import { activityFor, classifyByActivity } from "./status.ts";
import { readHead, readTail } from "./tail.ts";
import { asRecord, codexTitle, parseLine as parse } from "./transcript.ts";
import {
  LIVE_WINDOW_MS,
  type Adapter,
  type ProcInfo,
  type RawSession,
  type RecentAction,
} from "./types.ts";

const MAX_ACTIONS = 5;
const TAIL_BYTES = 512 * 1024;
const APPROVALS = new Set([
  "exec_approval_request",
  "apply_patch_approval_request",
  "request_user_input",
  "elicitation_request",
]);
const ENDS_TURN = new Set(["task_complete", "turn_aborted", "shutdown_complete"]);
const STARTS_TURN = new Set([
  "task_started",
  "user_message",
  "agent_message",
  "exec_command_begin",
  "exec_command_end",
  "patch_apply_begin",
  "patch_apply_end",
  "mcp_tool_call_begin",
  "mcp_tool_call_end",
]);

/** `["bash", "-lc", "npm test"]` is the command `npm test`. */
function commandText(command: unknown): string | undefined {
  if (typeof command === "string") return command;
  if (!Array.isArray(command)) return undefined;
  const parts = command.filter((part): part is string => typeof part === "string");
  const shell = parts[0]?.split("/").at(-1);
  if (parts.length === 3 && (shell === "bash" || shell === "sh" || shell === "zsh")) {
    return parts[2];
  }
  return parts.join(" ");
}

function actionOf(payload: Record<string, unknown>): string | undefined {
  switch (payload["type"]) {
    case "function_call": {
      const name = typeof payload["name"] === "string" ? payload["name"] : "tool";
      let input: unknown;
      try {
        input = JSON.parse(typeof payload["arguments"] === "string" ? payload["arguments"] : "");
      } catch {
        input = undefined;
      }
      const command = commandText(asRecord(input)?.["command"] ?? asRecord(input)?.["cmd"]);
      return command === undefined ? describeTool(name, input) : describeCommand(command);
    }
    case "local_shell_call":
    case "exec_command_begin": {
      const command = commandText(asRecord(payload["action"])?.["command"] ?? payload["command"]);
      return command === undefined ? "Running a command" : describeCommand(command);
    }
    case "custom_tool_call":
      return describeTool(
        typeof payload["name"] === "string" ? payload["name"] : "tool",
        undefined,
      );
    case "patch_apply_begin":
      return "Editing files";
    case "mcp_tool_call_begin": {
      const tool = asRecord(payload["invocation"])?.["tool"];
      return `Using ${typeof tool === "string" ? tool : "a tool"}`;
    }
    default:
      return undefined;
  }
}

interface Reading {
  readonly actions: RecentAction[];
  readonly waiting: boolean;
  readonly finished: boolean;
}

function read(path: string): Reading {
  const actions: RecentAction[] = [];
  let waiting = false;
  let finished = false;
  for (const line of readTail(path, TAIL_BYTES)) {
    const entry = parse(line);
    const payload = asRecord(entry?.["payload"]);
    if (entry === undefined || payload === undefined) continue;
    const type = payload["type"];
    const at = Date.parse(typeof entry["timestamp"] === "string" ? entry["timestamp"] : "") || 0;
    if (entry["type"] === "event_msg" && typeof type === "string") {
      if (APPROVALS.has(type)) {
        waiting = true;
        finished = false;
        continue;
      }
      if (ENDS_TURN.has(type)) {
        waiting = false;
        finished = true;
        continue;
      }
      if (STARTS_TURN.has(type)) {
        waiting = false;
        finished = false;
      }
    }
    const text = actionOf(payload);
    if (text === undefined) continue;
    waiting = false;
    finished = false;
    const previous = actions.at(-1);
    // A call is logged twice, as a response item and as an event.
    if (previous?.text === text && at - previous.at < 2_000) continue;
    actions.push({ at, text });
  }
  return { actions: actions.slice(-MAX_ACTIONS), waiting, finished };
}

interface Rollout {
  readonly path: string;
  readonly mtime: number;
}

/** Rollouts of today and yesterday (the folders are YYYY/MM/DD), newest first. */
function recentRollouts(home: string, now: number): Rollout[] {
  const found: Rollout[] = [];
  for (const back of [0, 1]) {
    const date = new Date(now - back * 86_400_000);
    const dir = join(
      home,
      ".codex",
      "sessions",
      String(date.getFullYear()),
      String(date.getMonth() + 1).padStart(2, "0"),
      String(date.getDate()).padStart(2, "0"),
    );
    let names: string[];
    try {
      names = readdirSync(dir);
    } catch {
      continue;
    }
    for (const name of names) {
      if (!name.startsWith("rollout-") || !name.endsWith(".jsonl")) continue;
      try {
        found.push({ path: join(dir, name), mtime: statSync(join(dir, name)).mtimeMs });
      } catch {
        // Removed between the listing and the stat.
      }
    }
  }
  return found.sort((a, b) => b.mtime - a.mtime);
}

interface Meta {
  readonly id: string;
  readonly cwd: string;
  readonly startedAt: number | null;
}

function metaOf(path: string): Meta | undefined {
  const head = readHead(path, 64 * 1024);
  const entry = head === undefined ? undefined : parse(head);
  const payload = asRecord(entry?.["payload"]);
  if (entry?.["type"] !== "session_meta" || payload === undefined) return undefined;
  const { id, cwd } = payload;
  if (typeof id !== "string" || typeof cwd !== "string") return undefined;
  const started = Date.parse(typeof payload["timestamp"] === "string" ? payload["timestamp"] : "");
  return { id, cwd, startedAt: Number.isNaN(started) ? null : started };
}

const ROLLOUT = /\/rollout-[^/]*\.jsonl$/;

/**
 * Codex: rollout files under `~/.codex/sessions`. A rollout is a live Session when a `codex`
 * process (not the `app-server` daemon) has it open or runs in its folder, or it was written in
 * the last few minutes.
 */
export const codexAdapter: Adapter = (probe) => {
  const rollouts = recentRollouts(probe.home, probe.now);
  const found = processesRunning(probe.processes(), "codex").filter(
    (proc) => !/\sapp-server(\s|$)/.test(proc.command),
  );
  // A wrapper and the program it starts are both `codex`: they are one Session, the child's.
  const processes = found.filter((proc) => !found.some((other) => other.ppid === proc.pid));

  const claimed = new Map<string, number>();
  const metas = new Map<string, Meta | undefined>();
  const metaFor = (path: string): Meta | undefined => {
    if (!metas.has(path)) metas.set(path, metaOf(path));
    return metas.get(path);
  };
  const fallback: ProcInfo[] = [];
  for (const proc of processes) {
    // The rollout the process is writing, wherever its folder: it may be days old.
    const open = probe.openFiles(proc.pid).find((file) => ROLLOUT.test(file));
    if (open === undefined) {
      fallback.push(proc);
      continue;
    }
    claimed.set(open, proc.pid);
    if (!rollouts.some((r) => r.path === open)) {
      try {
        rollouts.push({ path: open, mtime: statSync(open).mtimeMs });
      } catch {
        claimed.delete(open);
      }
    }
  }
  for (const proc of fallback) {
    const cwd = probe.cwdOf(proc.pid);
    if (cwd === null) continue;
    const match = rollouts.find((r) => !claimed.has(r.path) && metaFor(r.path)?.cwd === cwd);
    if (match !== undefined) claimed.set(match.path, proc.pid);
  }

  const sessions: RawSession[] = [];
  for (const rollout of rollouts) {
    const pid = claimed.get(rollout.path) ?? null;
    if (pid === null && probe.now - rollout.mtime > LIVE_WINDOW_MS) continue;
    const meta = metaFor(rollout.path);
    if (meta === undefined) continue;
    const reading = read(rollout.path);
    const status = classifyByActivity({
      now: probe.now,
      lastActivityAt: rollout.mtime,
      waiting: reading.waiting,
      finished: reading.finished,
    });
    sessions.push({
      agent: "codex",
      sessionId: meta.id,
      title: codexTitle(rollout.path),
      cwd: meta.cwd,
      status,
      activity: activityFor(status, reading.actions, probe.now),
      recentActions: reading.actions,
      startedAt: meta.startedAt,
      updatedAt: rollout.mtime,
      pid,
    });
  }
  return sessions;
};
