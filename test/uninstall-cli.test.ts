import { spawnSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

const SCRIPT = "scripts/uninstall-cli.sh";

const folders: string[] = [];
afterEach(() => {
  for (const folder of folders.splice(0)) rmSync(folder, { recursive: true, force: true });
});

/** A prefix with a stub `suica` that logs each call and whether the lib folder still exists. */
function prefix(body = ""): { root: string; run: () => { status: number | null; output: string } } {
  const root = mkdtempSync(join(tmpdir(), "suica-uninstall-"));
  folders.push(root);
  mkdirSync(join(root, "bin"));
  mkdirSync(join(root, "lib", "suica", "src"), { recursive: true });
  const bin = join(root, "bin", "suica");
  writeFileSync(
    bin,
    `#!/bin/sh\nif [ -d "${join(root, "lib", "suica")}" ]; then lib=present; else lib=gone; fi\necho "$* lib=$lib" >> "${join(root, "calls.log")}"\n${body}\n`,
  );
  chmodSync(bin, 0o755);
  return {
    root,
    run: () => {
      const result = spawnSync("sh", [SCRIPT], {
        env: { HOME: root, PATH: "/usr/bin:/bin", SUICA_PREFIX: root },
        encoding: "utf8",
      });
      return { status: result.status, output: `${result.stdout}${result.stderr}` };
    },
  };
}

describe("uninstall-cli.sh", () => {
  it("removes the lessons hook and MCP registrations before removing the code", () => {
    const box = prefix();
    const { status } = box.run();
    expect(status).toBe(0);
    const calls = readFileSync(join(box.root, "calls.log"), "utf8").trim().split("\n");
    expect(calls).toEqual(["agent uninstall lib=present", "lessons uninstall lib=present"]);
    expect(existsSync(join(box.root, "lib", "suica"))).toBe(false);
    expect(existsSync(join(box.root, "bin", "suica"))).toBe(false);
  }, 20_000);

  it("still removes the code when lessons uninstall fails", () => {
    const box = prefix(`if [ "$1" = lessons ]; then exit 1; fi`);
    const { status } = box.run();
    expect(status).toBe(0);
    expect(existsSync(join(box.root, "lib", "suica"))).toBe(false);
  }, 20_000);
});
