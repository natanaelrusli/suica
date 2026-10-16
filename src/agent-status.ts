import type { Exec } from "./exec.ts";
import { defaultStatePath } from "./config.ts";
import type { Config } from "./config.ts";
import type { PollLogEntry } from "./store.ts";
import { defaultTemplatesPath } from "./teams/templates.ts";

export const AGENT_LABEL = "com.madhani.suica.agent";

const PRINT_TIMEOUT_MS = 5_000;
const KICKSTART_TIMEOUT_MS = 15_000;

export interface ServiceStatus {
  readonly loaded: boolean;
  readonly running: boolean;
  readonly pid: number | null;
}

const NOT_LOADED: ServiceStatus = { loaded: false, running: false, pid: null };

/** Reads the output of `launchctl print`; a successful print means the service is loaded. */
export function parseLaunchctlPrint(stdout: string): ServiceStatus {
  const lines = stdout.split("\n").map((line) => line.trim());
  const pidLine = lines.find((line) => /^pid = \d+$/.test(line));
  return {
    loaded: true,
    running: lines.includes("state = running"),
    pid: pidLine === undefined ? null : Number(pidLine.slice("pid = ".length)),
  };
}

function target(uid: number): string {
  return `gui/${uid}/${AGENT_LABEL}`;
}

export async function readServiceStatus(exec: Exec, uid: number): Promise<ServiceStatus> {
  try {
    const { stdout } = await exec("launchctl", ["print", target(uid)], {
      timeoutMs: PRINT_TIMEOUT_MS,
    });
    return parseLaunchctlPrint(stdout);
  } catch {
    return NOT_LOADED;
  }
}

export async function restartService(
  exec: Exec,
  uid: number,
): Promise<"restarted" | "not-installed" | "failed"> {
  if (!(await readServiceStatus(exec, uid)).loaded) return "not-installed";
  try {
    await exec("launchctl", ["kickstart", "-k", target(uid)], { timeoutMs: KICKSTART_TIMEOUT_MS });
    return "restarted";
  } catch {
    return "failed";
  }
}

/** The document `suica status --json` prints; see contracts/status.v1.json. */
export interface StatusJson {
  readonly version: 1;
  readonly agent: ServiceStatus & { readonly label: string };
  readonly configError: string | null;
  /** Null when the config could not be loaded. */
  readonly paused: boolean | null;
  readonly teamsEnabled: boolean | null;
  readonly lastPoll: PollLogEntry | null;
  readonly polling: { readonly activeSeconds: number; readonly idleSeconds: number } | null;
  readonly paths: {
    readonly config: string;
    readonly state: string;
    readonly logs: string;
    readonly templates: string;
  };
}

export interface StatusInput {
  readonly service: ServiceStatus;
  readonly configPath: string;
  readonly logsPath: string;
  readonly loaded:
    | { readonly config: Config; readonly paused: boolean; readonly lastPoll: PollLogEntry | null }
    | { readonly error: string };
}

export function buildStatus(input: StatusInput): StatusJson {
  const { loaded } = input;
  const agent = { label: AGENT_LABEL, ...input.service };
  if ("error" in loaded) {
    return {
      version: 1,
      agent,
      configError: loaded.error,
      paused: null,
      teamsEnabled: null,
      lastPoll: null,
      polling: null,
      paths: {
        config: input.configPath,
        state: defaultStatePath(),
        logs: input.logsPath,
        templates: defaultTemplatesPath(),
      },
    };
  }
  const { config } = loaded;
  return {
    version: 1,
    agent,
    configError: null,
    paused: loaded.paused,
    teamsEnabled: config.teams.enabled,
    lastPoll: loaded.lastPoll,
    polling: {
      activeSeconds: config.polling.activeSeconds,
      idleSeconds: config.polling.idleSeconds,
    },
    paths: {
      config: input.configPath,
      state: config.statePath ?? defaultStatePath(),
      logs: input.logsPath,
      templates: config.teams.templatesPath ?? defaultTemplatesPath(),
    },
  };
}
