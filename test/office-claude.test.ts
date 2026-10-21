import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { claudeAdapter } from "../src/office/claude.ts";
import { NOW, fakeProbe, lines, put } from "./office-builders.ts";

let home: string;
beforeEach(() => {
  home = realpathSync(mkdtempSync(join(tmpdir(), "suica-office-claude-")));
});
afterEach(() => {
  rmSync(home, { recursive: true, force: true });
});

const CWD = "/work/suica";
const SLUG = "-work-suica";

const session = (pid: number, extra: Record<string, unknown> = {}) =>
  JSON.stringify({
    pid,
    sessionId: `sid-${pid}`,
    cwd: CWD,
    startedAt: NOW - 600_000,
    status: "busy",
    updatedAt: NOW - 2_000,
    entrypoint: "cli",
    ...extra,
  });

const toolUse = (name: string, input: unknown, at: number) => ({
  type: "assistant",
  timestamp: new Date(at).toISOString(),
  message: { role: "assistant", content: [{ type: "tool_use", id: "t", name, input }] },
});

function transcript(sessionId: string, text: string, mtime = NOW - 1_000): void {
  put(join(home, ".claude", "projects", SLUG, `${sessionId}.jsonl`), text, mtime);
}

describe("claudeAdapter", () => {
  it("lists a busy session with its current tool as the activity and the last five actions", () => {
    put(join(home, ".claude", "sessions", "100.json"), session(100));
    const entries = [1, 2, 3, 4, 5, 6].map((n) =>
      toolUse("Edit", { file_path: `/work/suica/f${n}.ts` }, NOW - (10 - n) * 1000),
    );
    transcript(
      "sid-100",
      lines(...entries, { type: "user", message: { role: "user", content: "private prompt" } }),
    );
    const [one, ...rest] = claudeAdapter(fakeProbe({ home, alive: [100] }));
    expect(rest).toEqual([]);
    expect(one).toMatchObject({
      agent: "claude",
      sessionId: "sid-100",
      cwd: CWD,
      status: "working",
      pid: 100,
      startedAt: NOW - 600_000,
    });
    expect(one?.activity).toBe("Editing f6.ts");
    expect(one?.recentActions.map((a) => a.text)).toEqual([
      "Editing f2.ts",
      "Editing f3.ts",
      "Editing f4.ts",
      "Editing f5.ts",
      "Editing f6.ts",
    ]);
    expect(JSON.stringify(one)).not.toContain("private prompt");
  });

  it("says Thinking when the last tool call is no longer fresh", () => {
    put(join(home, ".claude", "sessions", "100.json"), session(100));
    transcript("sid-100", lines(toolUse("Read", { file_path: "/a/b.ts" }, NOW - 90_000)));
    const [one] = claudeAdapter(fakeProbe({ home, alive: [100] }));
    expect(one?.status).toBe("working");
    expect(one?.activity).toBe("Thinking");
  });

  it("maps idle, waiting and unknown statuses", () => {
    put(join(home, ".claude", "sessions", "1.json"), session(1, { status: "idle" }));
    put(join(home, ".claude", "sessions", "2.json"), session(2, { status: "waiting" }));
    put(join(home, ".claude", "sessions", "3.json"), session(3, { status: "shell" }));
    const found = claudeAdapter(fakeProbe({ home, alive: [1, 2, 3] }));
    expect(Object.fromEntries(found.map((s) => [s.pid, s.status]))).toEqual({
      1: "idle",
      2: "waiting",
      3: "idle",
    });
    expect(found.find((s) => s.pid === 1)?.activity).toBe("");
  });

  it("keeps a session whose process exited a minute ago as exited, and drops an old one", () => {
    put(join(home, ".claude", "sessions", "7.json"), session(7, { updatedAt: NOW - 60_000 }));
    put(join(home, ".claude", "sessions", "8.json"), session(8, { updatedAt: NOW - 3_600_000 }));
    const found = claudeAdapter(fakeProbe({ home }));
    expect(found.map((s) => [s.pid, s.status])).toEqual([[7, "exited"]]);
  });

  it("does not trust a pid that now belongs to another program", () => {
    put(join(home, ".claude", "sessions", "9.json"), session(9, { updatedAt: NOW - 3_600_000 }));
    const probe = fakeProbe({ home, procs: [{ pid: 9, ppid: 1, command: "/usr/bin/vim a.txt" }] });
    expect(claudeAdapter(probe)).toEqual([]);
  });

  it("reads the tail of a transcript whose last lines are huge request blobs", () => {
    put(join(home, ".claude", "sessions", "100.json"), session(100));
    const blob = { type: "api-request", params: { text: "x".repeat(700_000) } };
    transcript(
      "sid-100",
      lines(toolUse("Bash", { command: "npm test" }, NOW - 3_000), blob, blob, blob),
    );
    const [one] = claudeAdapter(fakeProbe({ home, alive: [100] }));
    expect(one?.activity).toBe("Running npm test");
  });

  it("falls back to the process list and the newest transcript when the session file lacks fields", () => {
    put(join(home, ".claude", "sessions", "50.json"), JSON.stringify({ pid: 50 }));
    transcript(
      "old-one",
      lines(toolUse("Read", { file_path: "/a/old.ts" }, NOW - 500_000)),
      NOW - 500_000,
    );
    transcript(
      "new-one",
      lines(toolUse("Edit", { file_path: "/a/new.ts" }, NOW - 4_000)),
      NOW - 4_000,
    );
    const probe = fakeProbe({
      home,
      procs: [{ pid: 50, ppid: 1, command: "/Users/x/.local/bin/claude --resume" }],
      cwds: { 50: CWD },
    });
    const [one, ...rest] = claudeAdapter(probe);
    expect(rest).toEqual([]);
    expect(one).toMatchObject({ sessionId: "new-one", cwd: CWD, pid: 50, status: "working" });
    expect(one?.activity).toBe("Editing new.ts");
  });

  it("finds a claude process that has no session file at all", () => {
    transcript("lonely", lines(toolUse("Grep", { pattern: "TODO" }, NOW - 70_000)), NOW - 70_000);
    const probe = fakeProbe({
      home,
      procs: [{ pid: 60, ppid: 1, command: "/Users/x/.local/bin/claude" }],
      cwds: { 60: CWD },
    });
    const [one] = claudeAdapter(probe);
    expect(one).toMatchObject({ sessionId: "lonely", status: "idle", pid: 60 });
  });

  it("has no sessions when there is no ~/.claude", () => {
    expect(claudeAdapter(fakeProbe({ home }))).toEqual([]);
  });
});
