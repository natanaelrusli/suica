import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { genericAdapter, parseCustomAgent } from "../src/office/generic.ts";
import { NOW, fakeProbe, lines, put } from "./office-builders.ts";

let home: string;
beforeEach(() => {
  home = realpathSync(mkdtempSync(join(tmpdir(), "suica-office-generic-")));
});
afterEach(() => {
  rmSync(home, { recursive: true, force: true });
});

describe("parseCustomAgent", () => {
  it("reads name|process|glob|cwdKey|activityKey", () => {
    expect(parseCustomAgent("aider|aider|~/.aider/*.jsonl|meta.cwd|tool.name")).toEqual({
      name: "aider",
      process: "aider",
      glob: "~/.aider/*.jsonl",
      cwdKey: "meta.cwd",
      activityKey: "tool.name",
    });
  });

  it("rejects a malformed or clashing entry with a message", () => {
    expect(parseCustomAgent("aider|aider|g|c")).toBe(
      "must be name|process|log glob|cwd key|activity key",
    );
    expect(parseCustomAgent("Bad Name|p|g|c|a")).toMatch(/name/);
    expect(parseCustomAgent("claude|p|g|c|a")).toMatch(/built-in/);
    expect(parseCustomAgent("a|p||c|a")).toMatch(/empty/);
  });
});

describe("genericAdapter", () => {
  const entry = parseCustomAgent("aider|aider|~/.aider/*.jsonl|meta.cwd|tool.name");
  if (typeof entry === "string") throw new Error(entry);

  it("finds the folder and the activity by their keys in a recently written log", () => {
    put(
      join(home, ".aider", "one.jsonl"),
      lines(
        { meta: { cwd: "/work/p" }, text: "secret-prompt" },
        { tool: { name: "Editing a.py" } },
        { tool: { name: "Running tests" } },
      ),
      NOW - 3_000,
    );
    const [one, ...rest] = genericAdapter(entry)(fakeProbe({ home }));
    expect(rest).toEqual([]);
    expect(one).toMatchObject({
      agent: "aider",
      cwd: "/work/p",
      status: "working",
      activity: "Running tests",
    });
    expect(one?.recentActions.map((a) => a.text)).toEqual(["Editing a.py", "Running tests"]);
    expect(JSON.stringify(one)).not.toContain("secret-prompt");
  });

  it("is idle when the log is a minute old, and gone after three without a process", () => {
    put(join(home, ".aider", "one.jsonl"), lines({ meta: { cwd: "/work/p" } }), NOW - 90_000);
    expect(genericAdapter(entry)(fakeProbe({ home }))[0]?.status).toBe("idle");
    put(join(home, ".aider", "one.jsonl"), lines({ meta: { cwd: "/work/p" } }), NOW - 400_000);
    expect(genericAdapter(entry)(fakeProbe({ home }))).toEqual([]);
  });

  it("skips a log without the cwd key", () => {
    put(join(home, ".aider", "one.jsonl"), lines({ other: 1 }), NOW - 1_000);
    expect(genericAdapter(entry)(fakeProbe({ home }))).toEqual([]);
  });
});
