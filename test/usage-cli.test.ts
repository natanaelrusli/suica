import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { openStore } from "../src/store.ts";
import type { UsageJson } from "../src/usage.ts";

let dir: string;
let configPath: string;
let statePath: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "suica-usage-cli-"));
  configPath = join(dir, "config.yaml");
  statePath = join(dir, "state", "state.db");
  writeFileSync(configPath, `gitlab:\n  hostname: h\nstatePath: ${statePath}\n`);
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

function usage(): { status: number | null; stdout: string } {
  const result = spawnSync("node", ["src/cli.ts", "usage"], {
    encoding: "utf8",
    env: { ...process.env, SUICA_CONFIG: configPath },
  });
  return { status: result.status, stdout: result.stdout };
}

describe("suica usage", () => {
  it("prints the recorded runs as one usage document", () => {
    const store = openStore(statePath);
    store.recordTokenUsage({
      at: Date.now() - 60_000,
      purpose: "review",
      inputTokens: 1200,
      outputTokens: 300,
      cacheReadTokens: 0,
      cacheCreationTokens: 0,
    });
    store.close();
    const result = usage();
    expect(result.status).toBe(0);
    const document = JSON.parse(result.stdout) as UsageJson;
    expect(document.version).toBe(1);
    expect(document.days).toHaveLength(14);
    expect(document.last24h.inputTokens).toBe(1200);
    expect(document.byPurpose.map((p) => [p.purpose, p.outputTokens])).toEqual([["review", 300]]);
  });
});
