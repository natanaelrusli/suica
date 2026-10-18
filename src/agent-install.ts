import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { dirname, join } from "node:path";
import { AGENT_LABEL } from "./agent-status.ts";
import type { Exec } from "./exec.ts";

/** `suica agent install|uninstall`: the LaunchAgent that runs this installation's `main.ts`. */

const LAUNCHCTL_TIMEOUT_MS = 15_000;
const GONE_CHECK_MS = 200;
const GONE_CHECKS = 25;
const SEARCH_PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";

export interface AgentPaths {
  /** Absolute path of the `node` that runs the agent (the one running this CLI). */
  readonly node: string;
  /** Absolute path of `src/main.ts` in this installation. */
  readonly main: string;
  readonly home: string;
}

function xml(text: string): string {
  return text
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

export function plistPath(home: string): string {
  return join(home, "Library", "LaunchAgents", `${AGENT_LABEL}.plist`);
}

export function logsPath(home: string): string {
  return join(home, "Library", "Logs", "suica");
}

/** launchd restarts the agent only after a failed exit, at most once a minute. */
export function renderPlist(paths: AgentPaths): string {
  const logs = logsPath(paths.home);
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${AGENT_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${xml(paths.node)}</string>
    <string>${xml(paths.main)}</string>
  </array>
  <key>WorkingDirectory</key><string>${xml(dirname(dirname(paths.main)))}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${xml(paths.home)}</string>
    <key>PATH</key><string>${SEARCH_PATH}</string>
    <key>SUICA_ENV</key><string>production</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key><false/>
  </dict>
  <key>ThrottleInterval</key><integer>60</integer>
  <key>StandardOutPath</key><string>${xml(join(logs, "stdout.log"))}</string>
  <key>StandardErrorPath</key><string>${xml(join(logs, "stderr.log"))}</string>
</dict>
</plist>
`;
}

export type InstallOutcome = "installed" | "no-config" | "failed";

export type Nap = (ms: number) => Promise<unknown>;

/**
 * Writes the plist and (re)loads it. A daemon that cannot read its config exits on every start,
 * so it refuses to install without one.
 */
export async function installAgent(
  exec: Exec,
  uid: number,
  paths: AgentPaths,
  configPath: string,
  nap: Nap = sleep,
): Promise<InstallOutcome> {
  if (!existsSync(configPath)) return "no-config";
  const plist = plistPath(paths.home);
  mkdirSync(dirname(plist), { recursive: true });
  mkdirSync(logsPath(paths.home), { recursive: true });
  writeFileSync(plist, renderPlist(paths));
  const domain = `gui/${uid}`;
  const options = { timeoutMs: LAUNCHCTL_TIMEOUT_MS };
  const service = `${domain}/${AGENT_LABEL}`;
  let wasLoaded = true;
  try {
    await exec("launchctl", ["bootout", service], options);
  } catch {
    // Not loaded yet is the normal case for a first install.
    wasLoaded = false;
  }
  // bootout returns before the old agent is gone, and bootstrap fails while launchd still lists it.
  for (let check = 0; wasLoaded && check < GONE_CHECKS; check += 1) {
    try {
      await exec("launchctl", ["print", service], options);
    } catch {
      break;
    }
    await nap(GONE_CHECK_MS);
  }
  try {
    // RunAtLoad starts it. A kickstart -k right after would kill that first run and then block
    // for the plist's 60 s ThrottleInterval before launchd starts it again.
    await exec("launchctl", ["bootstrap", domain, plist], options);
    return "installed";
  } catch {
    return "failed";
  }
}

/** Unloads the agent and removes its plist; true when there was a plist to remove. */
export async function uninstallAgent(exec: Exec, uid: number, home: string): Promise<boolean> {
  try {
    await exec("launchctl", ["bootout", `gui/${uid}/${AGENT_LABEL}`], {
      timeoutMs: LAUNCHCTL_TIMEOUT_MS,
    });
  } catch {
    // Not loaded.
  }
  const plist = plistPath(home);
  const existed = existsSync(plist);
  rmSync(plist, { force: true });
  return existed;
}
