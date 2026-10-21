import { basename } from "node:path";
import type { Config } from "../config.ts";
import { claudeAdapter } from "./claude.ts";
import { codexAdapter } from "./codex.ts";
import { geminiAdapter } from "./gemini.ts";
import { genericAdapter, parseCustomAgent } from "./generic.ts";
import { roomFor } from "./room.ts";
import type { Adapter, OfficeJson, OfficeSession, ProcInfo, Probe, RawSession } from "./types.ts";

export interface NamedAdapter {
  readonly name: string;
  readonly run: Adapter;
}

const BUILT_IN: Readonly<Record<string, Adapter>> = {
  claude: claudeAdapter,
  codex: codexAdapter,
  gemini: geminiAdapter,
};

/** The adapters `office.agents` and `office.custom` switch on, built-ins first. */
export function adaptersFor(config: Config["office"]): NamedAdapter[] {
  const adapters: NamedAdapter[] = [];
  for (const name of config.agents) {
    const run = BUILT_IN[name];
    if (run !== undefined) adapters.push({ name, run });
  }
  for (const entry of config.custom) {
    const agent = parseCustomAgent(entry);
    if (typeof agent !== "string") adapters.push({ name: agent.name, run: genericAdapter(agent) });
  }
  return adapters;
}

/** The `.app` that hosts a process: the first application bundle among its ancestors. */
export function hostAppOf(pid: number | null, procs: readonly ProcInfo[]): string | null {
  if (pid === null) return null;
  const byPid = new Map(procs.map((proc) => [proc.pid, proc]));
  let current = byPid.get(pid);
  for (let hops = 0; hops < 24 && current !== undefined; hops++) {
    current = byPid.get(current.ppid);
    const app = current === undefined ? undefined : /^(.*?\.app)\/Contents\//.exec(current.command);
    if (app?.[1] !== undefined) return app[1];
  }
  return null;
}

export interface CollectOptions {
  readonly roomOf?: (cwd: string) => string;
  readonly hostApp?: (pid: number | null) => string | null;
}

/**
 * Every live Session of the enabled Coding Agents, each in its Room. An adapter that fails (a log
 * format it does not know) shows nothing; the other agents still show.
 */
export function collectOffice(
  adapters: readonly NamedAdapter[],
  probe: Probe,
  options: CollectOptions = {},
): OfficeJson {
  const roomOf = options.roomOf ?? ((cwd: string) => roomFor(cwd, probe.home));
  const procs = probe.processes();
  const hostApp = options.hostApp ?? ((pid: number | null) => hostAppOf(pid, procs));

  const newest = new Map<string, RawSession>();
  for (const adapter of adapters) {
    let found: readonly RawSession[];
    try {
      found = adapter.run(probe);
    } catch {
      continue;
    }
    for (const session of found) {
      const key = `${session.agent}\n${session.sessionId}`;
      const known = newest.get(key);
      if (known === undefined || session.updatedAt > known.updatedAt) newest.set(key, session);
    }
  }

  const sessions: OfficeSession[] = [...newest.values()].map((session) => {
    const room = roomOf(session.cwd);
    return {
      ...session,
      // File times have fractions on APFS; the app decodes whole milliseconds.
      startedAt: session.startedAt === null ? null : Math.floor(session.startedAt),
      updatedAt: Math.floor(session.updatedAt),
      recentActions: session.recentActions.map((a) => ({ at: Math.floor(a.at), text: a.text })),
      room,
      roomName: basename(room),
      hostApp: hostApp(session.pid),
    };
  });
  sessions.sort(
    (a, b) =>
      a.roomName.localeCompare(b.roomName) ||
      a.room.localeCompare(b.room) ||
      (a.startedAt ?? a.updatedAt) - (b.startedAt ?? b.updatedAt) ||
      a.sessionId.localeCompare(b.sessionId),
  );
  return { version: 1, generatedAt: probe.now, sessions };
}
