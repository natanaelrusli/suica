import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import {
  AGENT_LABEL,
  buildStatus,
  parseLaunchctlPrint,
  readServiceStatus,
  restartService,
} from "../src/agent-status.ts";
import { parseConfig } from "../src/config.ts";
import type { Exec, ExecOptions } from "../src/exec.ts";

interface Call {
  readonly file: string;
  readonly args: readonly string[];
  readonly options: ExecOptions;
}

type Reply = { readonly stdout: string } | { readonly fail: true };

function fakeExec(replies: Record<string, Reply>): { exec: Exec; calls: Call[] } {
  const calls: Call[] = [];
  const exec: Exec = (file, args, options) => {
    calls.push({ file, args, options });
    const reply = replies[args[0] ?? ""] ?? { fail: true };
    if ("fail" in reply) return Promise.reject(Object.assign(new Error("exit 113"), { code: 113 }));
    return Promise.resolve({ stdout: reply.stdout, stderr: "" });
  };
  return { exec, calls };
}

const TARGET = `gui/501/${AGENT_LABEL}`;
const RUNNING = "\tstate = running\n\tpid = 4242\n";

describe("service status", () => {
  it("parses a running service", () => {
    expect(parseLaunchctlPrint(RUNNING)).toEqual({ loaded: true, running: true, pid: 4242 });
  });

  it("parses a loaded service that is not running", () => {
    expect(parseLaunchctlPrint("\tstate = not running\n")).toEqual({
      loaded: true,
      running: false,
      pid: null,
    });
  });

  it("reports not loaded when launchctl exits non-zero", async () => {
    const { exec } = fakeExec({});
    expect(await readServiceStatus(exec, 501)).toEqual({
      loaded: false,
      running: false,
      pid: null,
    });
  });

  it("calls launchctl print with the exact target and a timeout", async () => {
    const { exec, calls } = fakeExec({ print: { stdout: RUNNING } });
    expect(await readServiceStatus(exec, 501)).toEqual({ loaded: true, running: true, pid: 4242 });
    expect(calls).toEqual([
      { file: "launchctl", args: ["print", TARGET], options: { timeoutMs: 5000 } },
    ]);
  });

  it("restart refuses when the agent is not installed", async () => {
    const { exec, calls } = fakeExec({});
    expect(await restartService(exec, 501)).toBe("not-installed");
    expect(calls.map((call) => call.args[0])).toEqual(["print"]);
  });

  it("restart kickstarts with -k", async () => {
    const { exec, calls } = fakeExec({ print: { stdout: RUNNING }, kickstart: { stdout: "" } });
    expect(await restartService(exec, 501)).toBe("restarted");
    expect(calls[1]).toEqual({
      file: "launchctl",
      args: ["kickstart", "-k", TARGET],
      options: { timeoutMs: 15000 },
    });
  });

  it("restart reports failed when kickstart fails", async () => {
    const { exec } = fakeExec({ print: { stdout: RUNNING } });
    expect(await restartService(exec, 501)).toBe("failed");
  });
});

describe("buildStatus", () => {
  const service = { loaded: true, running: true, pid: 4242 };

  it("matches the golden contract file", () => {
    const config = parseConfig(
      [
        "gitlab:",
        "  hostname: h",
        "teams:",
        "  enabled: true",
        "  templatesPath: /Users/o/.config/suica/templates",
        "statePath: /Users/o/Library/Application Support/suica/state.db",
      ].join("\n"),
    );
    const golden: unknown = JSON.parse(readFileSync("contracts/status.v1.json", "utf8"));
    expect(
      buildStatus({
        service,
        configPath: "/Users/o/.config/suica/config.yaml",
        logsPath: "/Users/o/Library/Logs/suica",
        loaded: {
          config,
          paused: false,
          lastPoll: { at: 1792148400000, status: "ok", failure: null, durationMs: 1500 },
        },
      }),
    ).toEqual(golden);
  });

  it("builds a status with a config error and default paths", () => {
    const status = buildStatus({
      service: { loaded: false, running: false, pid: null },
      configPath: "/c/config.yaml",
      logsPath: "/l",
      loaded: { error: "invalid config: gitlab: Required" },
    });
    expect(status).toMatchObject({
      configError: "invalid config: gitlab: Required",
      paused: null,
      teamsEnabled: null,
      lastPoll: null,
      polling: null,
      agent: { label: AGENT_LABEL, loaded: false },
      paths: {
        config: "/c/config.yaml",
        state: join(homedir(), "Library", "Application Support", "suica", "state.db"),
        logs: "/l",
        templates: join(homedir(), ".config", "suica", "templates"),
      },
    });
  });
});
