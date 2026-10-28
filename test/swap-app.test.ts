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

const SCRIPT = join(import.meta.dirname, "..", "scripts", "swap-app.sh");

function setup() {
  const dir = mkdtempSync(join(tmpdir(), "swap test-"));
  const bin = join(dir, "bin");
  mkdirSync(bin);
  writeFileSync(join(bin, "open"), `#!/bin/sh\necho "$1" > "${dir}/opened"\n`);
  chmodSync(join(bin, "open"), 0o755);
  const staged = join(dir, "staged", "Suica.app");
  const target = join(dir, "Applications", "Suica.app");
  mkdirSync(staged, { recursive: true });
  mkdirSync(target, { recursive: true });
  writeFileSync(join(staged, "new"), "new");
  writeFileSync(join(target, "old"), "old");
  return { dir, bin, staged, target };
}

function run(bin: string, pid: string, staged: string, target: string) {
  return spawnSync("sh", [SCRIPT, pid, staged, target], {
    env: { ...process.env, PATH: `${bin}:${process.env.PATH}` },
  });
}

it("swaps the staged app into place once the pid is gone and opens it", () => {
  const { dir, bin, staged, target } = setup();
  const dead = spawnSync("true").pid.toString();
  const r = run(bin, dead, staged, target);
  expect(r.status).toBe(0);
  expect(existsSync(join(target, "new"))).toBe(true);
  expect(existsSync(join(target, "old"))).toBe(false);
  expect(existsSync(staged)).toBe(false);
  expect(readFileSync(join(dir, "opened"), "utf8").trim()).toBe(target);
});

it("only opens the target when nothing is staged", () => {
  const { dir, bin, staged, target } = setup();
  const missing = join(dir, "nope");
  const r = run(bin, spawnSync("true").pid.toString(), missing, target);
  expect(r.status).toBe(0);
  expect(existsSync(join(target, "old"))).toBe(true);
  expect(existsSync(staged)).toBe(true);
  expect(readFileSync(join(dir, "opened"), "utf8").trim()).toBe(target);
});
