import { spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it } from "vitest";

const SCRIPT = join(import.meta.dirname, "..", "scripts", "install-cli.sh");

it("puts SUICA_NODE's directory on the PATH so npm finds node on a short PATH", () => {
  const root = mkdtempSync(join(tmpdir(), "install cli-"));
  const nodeDir = join(root, "fake node");
  mkdirSync(nodeDir);
  const stub = (name: string, body: string) => {
    writeFileSync(join(nodeDir, name), `#!/bin/sh\n${body}\n`);
    chmodSync(join(nodeDir, name), 0o755);
  };
  stub("node", "echo 24");
  stub("npm", `command -v node > "${root}/npm-saw-node"`);
  const home = join(root, "home");
  mkdirSync(home);
  const r = spawnSync("sh", [SCRIPT], {
    env: {
      PATH: "/usr/bin:/bin",
      HOME: home,
      SUICA_PREFIX: join(root, "prefix"),
      SUICA_NODE: join(nodeDir, "node"),
    },
    encoding: "utf8",
  });
  expect(r.stderr).toBe("");
  expect(r.status).toBe(0);
  expect(readFileSync(join(root, "npm-saw-node"), "utf8").trim()).toBe(join(nodeDir, "node"));
});
