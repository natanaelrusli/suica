import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { describeTool } from "./describe.ts";
import { processesRunning } from "./proc.ts";
import { activityFor, classifyByActivity } from "./status.ts";
import { readTail } from "./tail.ts";
import { asRecord, geminiTitle } from "./transcript.ts";
import { LIVE_WINDOW_MS, type Adapter, type RawSession, type RecentAction } from "./types.ts";

const MAX_ACTIONS = 5;
const TAIL_BYTES = 512 * 1024;

/** `~/.gemini/projects.json` maps a folder to its project name; the chats live under that name. */
function projectFolders(home: string): Map<string, string> {
  const folders = new Map<string, string>();
  try {
    const raw = asRecord(JSON.parse(readFileSync(join(home, ".gemini", "projects.json"), "utf8")));
    const map = asRecord(raw?.["projects"]) ?? raw ?? {};
    for (const [folder, name] of Object.entries(map)) {
      if (typeof name === "string") folders.set(name, folder);
    }
  } catch {
    // No Gemini CLI, or a file being written.
  }
  return folders;
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
    let entry: Record<string, unknown> | undefined;
    try {
      entry = asRecord(JSON.parse(line));
    } catch {
      continue;
    }
    if (entry === undefined) continue;
    const at = Date.parse(typeof entry["timestamp"] === "string" ? entry["timestamp"] : "") || 0;
    const calls = Array.isArray(entry["toolCalls"]) ? entry["toolCalls"] : [];
    waiting = false;
    // A model turn with no tool call ends the agent's turn; a user turn or a tool call starts one.
    finished = entry["type"] === "gemini" && calls.length === 0;
    for (const item of calls) {
      const call = asRecord(item);
      if (typeof call?.["name"] !== "string") continue;
      actions.push({ at, text: describeTool(call["name"], call["args"]) });
      waiting = typeof call["status"] === "string" && /await|confirm|approv/i.test(call["status"]);
    }
  }
  return { actions: actions.slice(-MAX_ACTIONS), waiting, finished };
}

/**
 * Gemini CLI: chats under `~/.gemini/tmp/<project>/chats`. A chat is a live Session when it was
 * written in the last few minutes or a `gemini` process runs in the project's folder.
 */
export const geminiAdapter: Adapter = (probe) => {
  const folders = projectFolders(probe.home);
  const processes = processesRunning(probe.processes(), "gemini");
  const running = new Map<string, number>();
  for (const proc of processes) {
    const cwd = probe.cwdOf(proc.pid);
    if (cwd !== null && !running.has(cwd)) running.set(cwd, proc.pid);
  }

  const sessions: RawSession[] = [];
  for (const [project, folder] of folders) {
    const dir = join(probe.home, ".gemini", "tmp", project, "chats");
    let names: string[];
    try {
      names = readdirSync(dir);
    } catch {
      continue;
    }
    const chats = names
      .filter((name) => name.startsWith("session-") && name.endsWith(".jsonl"))
      .map((name) => ({ name, mtime: statSync(join(dir, name)).mtimeMs }))
      .sort((a, b) => b.mtime - a.mtime);
    // A process keeps one Session: its folder's newest chat.
    const pid = running.get(folder) ?? null;
    for (const [index, chat] of chats.entries()) {
      const claimed = pid !== null && index === 0;
      if (!claimed && probe.now - chat.mtime > LIVE_WINDOW_MS) continue;
      const reading = read(join(dir, chat.name));
      const status = classifyByActivity({
        now: probe.now,
        lastActivityAt: chat.mtime,
        waiting: reading.waiting,
        finished: reading.finished,
      });
      sessions.push({
        agent: "gemini",
        sessionId: chat.name.slice("session-".length, -".jsonl".length),
        title: geminiTitle(join(dir, chat.name)),
        cwd: folder,
        status,
        activity: activityFor(status, reading.actions, probe.now),
        recentActions: reading.actions,
        startedAt: null,
        updatedAt: chat.mtime,
        pid: claimed ? pid : null,
      });
    }
  }
  return sessions;
};
