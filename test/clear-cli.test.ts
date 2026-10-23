import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { AgentStateJson } from "../src/agent-state.ts";
import { openStore } from "../src/store.ts";
import { intent, teamsPlan } from "./teams-builders.ts";

let dir: string;
let configPath: string;
let statePath: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "suica-clear-cli-"));
  configPath = join(dir, "config.yaml");
  statePath = join(dir, "state", "state.db");
  writeFileSync(
    configPath,
    `gitlab:\n  hostname: h\nstatePath: ${statePath}\nteams:\n  enabled: true\n`,
  );
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

function suica(...args: string[]): { status: number | null; stdout: string } {
  const result = spawnSync("node", ["src/cli.ts", ...args], {
    encoding: "utf8",
    env: { ...process.env, SUICA_CONFIG: configPath },
  });
  return { status: result.status, stdout: result.stdout };
}

function recentIds(): number[] {
  const state = JSON.parse(suica("state").stdout) as AgentStateJson;
  return state.teams?.recent.map((item) => item.id) ?? [];
}

describe("suica clear", () => {
  it("clears one row by id, then a group's Recent rows, and says when there was nothing", () => {
    const now = Date.now();
    const store = openStore(statePath);
    store.applyTeamsPlan(
      teamsPlan({
        intents: [
          intent(1),
          intent(2),
          intent(3, { dedupeKey: "notice:3", kind: "notice", variant: "notice.approved" }),
        ],
      }),
      now,
    );
    for (const id of [1, 2, 3]) store.transitionOutbox(id, "queued", "sent", {}, now);
    store.close();
    expect(recentIds()).toEqual([3, 2, 1]);

    expect(suica("clear", "2", "--json")).toEqual({ status: 0, stdout: '{"status":"cleared"}\n' });
    expect(suica("clear", "2", "--json")).toEqual({ status: 1, stdout: '{"status":"nothing"}\n' });
    expect(recentIds()).toEqual([3, 1]);

    expect(suica("clear", "yours", "--json").stdout).toBe('{"status":"cleared"}\n');
    expect(recentIds()).toEqual([3]);
    expect(suica("clear", "yours", "--json").stdout).toBe('{"status":"nothing"}\n');
    expect(suica("clear", "all").stdout).toBe("cleared 1\n");
    expect(recentIds()).toEqual([]);
  }, 30_000);

  it("rejects a group it does not know", () => {
    expect(suica("clear", "mine", "--json").status).toBe(2);
    expect(suica("clear", "toString", "--json").status).toBe(2);
  }, 20_000);
});
