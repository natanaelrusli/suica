import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { clip, describeCommand, describeTool } from "../src/office/describe.ts";
import { roomFor } from "../src/office/room.ts";
import { classifyByActivity } from "../src/office/status.ts";
import { readTail } from "../src/office/tail.ts";

let dir: string;
beforeEach(() => {
  dir = realpathSync(mkdtempSync(join(tmpdir(), "suica-office-core-")));
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

describe("roomFor", () => {
  it("is the folder itself outside a repository", () => {
    mkdirSync(join(dir, "plain"));
    expect(roomFor(join(dir, "plain"), dir)).toBe(join(dir, "plain"));
  });

  it("is the repository root for a folder inside it", () => {
    mkdirSync(join(dir, "suica", ".git"), { recursive: true });
    mkdirSync(join(dir, "suica", "macos", "Suica"), { recursive: true });
    expect(roomFor(join(dir, "suica", "macos", "Suica"), dir)).toBe(join(dir, "suica"));
  });

  it("puts a git worktree in the Room of the repository it belongs to", () => {
    mkdirSync(join(dir, "suica", ".git", "worktrees", "topic"), { recursive: true });
    mkdirSync(join(dir, "suica-topic", "src"), { recursive: true });
    writeFileSync(
      join(dir, "suica-topic", ".git"),
      `gitdir: ${join(dir, "suica", ".git", "worktrees", "topic")}\n`,
    );
    expect(roomFor(join(dir, "suica-topic", "src"), dir)).toBe(join(dir, "suica"));
  });

  it("keeps a submodule as its own Room", () => {
    mkdirSync(join(dir, "app", ".git", "modules", "lib"), { recursive: true });
    mkdirSync(join(dir, "app", "lib"), { recursive: true });
    writeFileSync(
      join(dir, "app", "lib", ".git"),
      `gitdir: ${join(dir, "app", ".git", "modules", "lib")}\n`,
    );
    expect(roomFor(join(dir, "app", "lib"), dir)).toBe(join(dir, "app", "lib"));
  });

  it("recognises a removed Claude worktree folder by its path", () => {
    mkdirSync(join(dir, "repo"), { recursive: true });
    const gone = join(dir, "repo", ".claude", "worktrees", "wt-1");
    expect(roomFor(gone, dir)).toBe(join(dir, "repo"));
  });

  it("never climbs into the home folder's own repository", () => {
    mkdirSync(join(dir, ".git"));
    mkdirSync(join(dir, "scratch"));
    expect(roomFor(join(dir, "scratch"), dir)).toBe(join(dir, "scratch"));
  });
});

describe("describeTool", () => {
  it("names the action and its target, not the conversation", () => {
    expect(describeTool("Edit", { file_path: "/a/b/OfficeView.swift", new_string: "secret" })).toBe(
      "Editing OfficeView.swift",
    );
    expect(describeTool("Write", { file_path: "/a/notes.md" })).toBe("Writing notes.md");
    expect(describeTool("Read", { file_path: "/a/b/c.ts" })).toBe("Reading c.ts");
    expect(describeTool("Bash", { command: "npm test\nrm -rf x", description: "d" })).toBe(
      "Running npm test",
    );
    expect(describeTool("Grep", { pattern: "TODO" })).toBe("Searching TODO");
    expect(describeTool("Agent", { prompt: "a long private prompt" })).toBe("Running a subagent");
    expect(describeTool("WebSearch", { query: "q" })).toBe("Browsing the web");
  });

  it("covers the other agents' tool names and falls back to the tool name", () => {
    expect(describeTool("replace", { file_path: "/x/y.py" })).toBe("Editing y.py");
    expect(describeTool("run_shell_command", { command: "ls -la" })).toBe("Running ls -la");
    expect(describeTool("apply_patch", {})).toBe("Editing files");
    expect(describeTool("mcp__github__create_issue", {})).toBe("Using create_issue");
    expect(describeTool("Mystery", undefined)).toBe("Using Mystery");
  });

  it("clips long text with an ellipsis", () => {
    expect(clip("abcdef", 4)).toBe("abc…");
    expect(clip("abc", 4)).toBe("abc");
    expect(describeCommand(`echo ${"x".repeat(200)}`).length).toBeLessThanOrEqual(80);
  });
});

describe("readTail", () => {
  it("drops the partial first line when the window starts mid-file", () => {
    const path = join(dir, "t.jsonl");
    writeFileSync(path, ["first-line-long-enough", "second", "third"].join("\n") + "\n");
    expect(readTail(path, 14)).toEqual(["second", "third"]);
  });

  it("returns every line of a file smaller than the window, and none for a missing file", () => {
    const path = join(dir, "s.jsonl");
    writeFileSync(path, "a\n\nb");
    expect(readTail(path, 1024)).toEqual(["a", "b"]);
    expect(readTail(join(dir, "missing"), 1024)).toEqual([]);
  });

  it("skips lines over the line limit", () => {
    const path = join(dir, "big.jsonl");
    writeFileSync(path, `ok\n${"y".repeat(500)}\nlast\n`);
    expect(readTail(path, 4096, 100)).toEqual(["ok", "last"]);
  });
});

describe("classifyByActivity", () => {
  const now = 1_000_000;
  it("is waiting whenever the agent waits, working while fresh, idle once stale or finished", () => {
    expect(classifyByActivity({ now, lastActivityAt: now - 5_000, waiting: true })).toBe("waiting");
    expect(classifyByActivity({ now, lastActivityAt: now - 5_000 })).toBe("working");
    expect(classifyByActivity({ now, lastActivityAt: now - 61_000 })).toBe("idle");
    expect(classifyByActivity({ now, lastActivityAt: now - 1_000, finished: true })).toBe("idle");
  });
});
