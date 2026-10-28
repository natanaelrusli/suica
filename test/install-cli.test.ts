import { spawnSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
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

it("still succeeds when the agent cannot be reloaded", { timeout: 20_000 }, () => {
  const root = mkdtempSync(join(tmpdir(), "install cli-"));
  const nodeDir = join(root, "node");
  mkdirSync(nodeDir);
  for (const [name, body] of [
    ["node", "echo 24"],
    ["npm", "true"],
  ]) {
    writeFileSync(join(nodeDir, name), `#!/bin/sh\n${body}\n`);
    chmodSync(join(nodeDir, name), 0o755);
  }
  const home = join(root, "home");
  mkdirSync(join(home, "Library", "LaunchAgents"), { recursive: true });
  writeFileSync(join(home, "Library", "LaunchAgents", "com.madhani.suica.agent.plist"), "");
  const prefix = join(root, "prefix");
  // The installed wrapper execs `node .../cli.ts agent install`; the stub node fails for that.
  writeFileSync(join(nodeDir, "node"), '#!/bin/sh\n[ "$1" = -p ] && echo 24 && exit 0\nexit 1\n');
  const r = spawnSync("sh", [SCRIPT], {
    env: {
      PATH: "/usr/bin:/bin",
      HOME: home,
      SUICA_PREFIX: prefix,
      SUICA_NODE: join(nodeDir, "node"),
    },
    encoding: "utf8",
  });
  expect(r.status).toBe(0);
  expect(r.stderr).toContain("warning: agent not reloaded");
  expect(existsSync(join(prefix, "lib", "suica", "package.json"))).toBe(true);
});
