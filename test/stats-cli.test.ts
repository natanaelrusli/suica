import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { StatsJson } from "../src/stats.ts";
import { openStore } from "../src/store.ts";
import { snapshot } from "./builders.ts";
import { intent, teamsPlan } from "./teams-builders.ts";

const DAY = 24 * 3_600_000;

let dir: string;
let configPath: string;
let statePath: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "suica-stats-cli-"));
  configPath = join(dir, "config.yaml");
  statePath = join(dir, "state", "state.db");
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

function writeConfig(extra = ""): void {
  writeFileSync(configPath, `gitlab:\n  hostname: h\nstatePath: ${statePath}\n${extra}`);
}

function stats(): { status: number | null; stdout: string; stderr: string } {
  const result = spawnSync("node", ["src/cli.ts", "stats"], {
    encoding: "utf8",
    env: { ...process.env, SUICA_CONFIG: configPath },
  });
  return { status: result.status, stdout: result.stdout, stderr: result.stderr };
}

const metaRows = (): unknown[] => {
  const db = new DatabaseSync(statePath);
  try {
    return db.prepare("SELECT key FROM meta WHERE key = 'teams_baseline_done'").all();
  } finally {
    db.close();
  }
};

describe("suica stats", () => {
  it("exits 1 with a short message and no output when the config is broken, and creates no state", () => {
    writeConfig("polling:\n  activeSeconds: 0\n");
    const result = stats();
    expect(result.status).toBe(1);
    expect(result.stdout).toBe("");
    expect(result.stderr).toMatch(/^suica: invalid config: /);
    expect(existsSync(join(dir, "state"))).toBe(false);
  });

  it("does not forget the Teams baseline while Teams is off", () => {
    writeConfig();
    const store = openStore(statePath);
    store.applyTeamsPlan(teamsPlan(), Date.now());
    store.close();
    expect(metaRows()).toHaveLength(1);
    const result = stats();
    expect(result.status).toBe(0);
    expect(metaRows()).toHaveLength(1);
  });

  it("counts the outbox only while Teams is on", () => {
    const now = Date.now();
    const store = openStore(statePath);
    store.applyTeamsPlan(teamsPlan({ intents: [intent(1)] }), now - 1000);
    expect(store.transitionOutbox(1, "queued", "sent", {}, now - 500)).toBe(true);
    store.close();

    writeConfig();
    const off = JSON.parse(stats().stdout) as StatsJson;
    expect(off.days.reduce((sum, day) => sum + day.nudgesSent, 0)).toBe(0);

    // A templates folder that does not load must not matter to the statistics.
    writeConfig(`teams:\n  enabled: true\n  templatesPath: ${join(dir, "missing")}\n`);
    const result = stats();
    expect(result.status).toBe(0);
    const on = JSON.parse(result.stdout) as StatsJson;
    expect(on.days.reduce((sum, day) => sum + day.nudgesSent, 0)).toBe(1);
  });

  it("pairs a request older than 30 days with a review inside the window", () => {
    writeConfig();
    const now = Date.now();
    const store = openStore(statePath);
    store.commit(snapshot(), [
      { kind: "review-requested", mrKey: "g/p!1", username: "", at: now - 40 * DAY },
      { kind: "owner-reviewed", mrKey: "g/p!1", username: "", at: now - 10 * DAY },
    ]);
    store.close();
    const document = JSON.parse(stats().stdout) as StatsJson;
    expect(document.ownerAfterRequest).toEqual({
      count: 1,
      medianMinutes: 30 * 24 * 60,
      p90Minutes: 30 * 24 * 60,
    });
  });
});
