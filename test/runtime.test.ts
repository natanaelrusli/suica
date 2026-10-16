import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { createRuntime } from "../src/runtime.ts";
import { openStore } from "../src/store.ts";
import { NOW, teamsPlan } from "./teams-builders.ts";

const folders: string[] = [];
afterEach(() => {
  for (const folder of folders.splice(0)) rmSync(folder, { recursive: true, force: true });
});

describe("createRuntime with Teams switched off", () => {
  it("resets the Teams baseline so that switching it on later never announces what happened meanwhile", () => {
    const folder = mkdtempSync(join(tmpdir(), "mra-runtime-"));
    folders.push(folder);
    const statePath = join(folder, "state.db");
    const seeded = openStore(statePath);
    seeded.applyTeamsPlan(teamsPlan({ baselineDone: true }), NOW);
    expect(seeded.loadTeams().baselineDone).toBe(true);
    seeded.close();

    const configPath = join(folder, "config.yaml");
    writeFileSync(
      configPath,
      `gitlab:\n  hostname: gitlab.example\nstatePath: ${statePath}\nteams:\n  enabled: false\n`,
    );
    const runtime = createRuntime(configPath);
    expect(runtime.store.loadTeams().baselineDone).toBe(false);
    runtime.store.close();
  });
});
