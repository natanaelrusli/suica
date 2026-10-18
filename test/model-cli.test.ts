import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  detectModelClis,
  isExecutableFile,
  resolveModelCli,
  searchDirs,
} from "../src/model-cli.ts";
import type { DetectedCli } from "../src/model-cli.ts";

const folders: string[] = [];
afterEach(() => {
  for (const folder of folders.splice(0)) rmSync(folder, { recursive: true, force: true });
});

const cli = (id: DetectedCli["id"], path: string | null): DetectedCli => ({
  id,
  name: { claude: "Claude Code", codex: "Codex", gemini: "Gemini CLI" }[id],
  path,
});

describe("detectModelClis", () => {
  it("finds each CLI in the first folder that has it and reports the rest as missing", () => {
    const present = new Set(["/a/codex", "/b/claude", "/b/codex"]);
    expect(detectModelClis(["/a", "/b"], (path) => present.has(path))).toEqual([
      cli("claude", "/b/claude"),
      cli("codex", "/a/codex"),
      cli("gemini", null),
    ]);
  });

  it("counts only executable files", () => {
    const dir = mkdtempSync(join(tmpdir(), "suica-cli-"));
    folders.push(dir);
    writeFileSync(join(dir, "plain"), "");
    writeFileSync(join(dir, "tool"), "#!/bin/sh\n");
    chmodSync(join(dir, "tool"), 0o755);
    mkdirSync(join(dir, "folder"));
    expect(isExecutableFile(join(dir, "tool"))).toBe(true);
    expect(isExecutableFile(join(dir, "plain"))).toBe(false);
    expect(isExecutableFile(join(dir, "folder"))).toBe(false);
    expect(isExecutableFile(join(dir, "absent"))).toBe(false);
  });
});

describe("searchDirs", () => {
  it("looks in PATH first, then the installers' folders and the folder of node, without repeats", () => {
    const dirs = searchDirs({ PATH: "/usr/bin::/opt/homebrew/bin" }, "/h", "/h/.nvm/v22/bin/node");
    expect(dirs.slice(0, 2)).toEqual(["/usr/bin", "/opt/homebrew/bin"]);
    expect(dirs).toContain("/h/.local/bin");
    expect(dirs).toContain("/h/.claude/local");
    expect(dirs).toContain("/h/.nvm/v22/bin");
    expect(new Set(dirs).size).toBe(dirs.length);
    expect(dirs).not.toContain("");
  });
});

describe("resolveModelCli", () => {
  const onlyCodex = [cli("claude", null), cli("codex", "/c/codex"), cli("gemini", null)];
  const all = [cli("claude", "/c/claude"), cli("codex", "/c/codex"), cli("gemini", "/c/gemini")];

  it("picks the first installed CLI for auto", () => {
    expect(resolveModelCli("auto", all)).toBe("claude");
    expect(resolveModelCli("auto", onlyCodex)).toBe("codex");
  });

  it("uses a named CLI only when it is installed", () => {
    expect(resolveModelCli("gemini", all)).toBe("gemini");
    expect(resolveModelCli("claude", onlyCodex)).toBeNull();
  });

  it("returns null when nothing is installed", () => {
    expect(resolveModelCli("auto", [cli("claude", null)])).toBeNull();
  });
});
