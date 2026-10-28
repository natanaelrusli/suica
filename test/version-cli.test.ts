import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

describe("suica --version", () => {
  it("prints the package.json version", () => {
    const pkg = JSON.parse(readFileSync("package.json", "utf8")) as { version: string };
    for (const flag of ["--version", "version"]) {
      const result = spawnSync("node", ["src/cli.ts", flag], { encoding: "utf8" });
      expect(result.status).toBe(0);
      expect(result.stdout.trim()).toBe(pkg.version);
    }
  }, 20_000);
});
