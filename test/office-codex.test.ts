import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { codexAdapter } from "../src/office/codex.ts";
import { NOW, fakeProbe, lines, put } from "./office-builders.ts";

let home: string;
beforeEach(() => {
  home = realpathSync(mkdtempSync(join(tmpdir(), "suica-office-codex-")));
});
afterEach(() => {
  rmSync(home, { recursive: true, force: true });
});

const iso = (ms: number) => new Date(ms).toISOString();
const day = new Date(NOW);
const folder = (home_: string) =>
  join(
    home_,
    ".codex",
    "sessions",
    String(day.getFullYear()),
    String(day.getMonth() + 1).padStart(2, "0"),
    String(day.getDate()).padStart(2, "0"),
  );

const meta = (id: string, cwd: string, at: number) => ({
  timestamp: iso(at),
  type: "session_meta",
  payload: { id, cwd, timestamp: iso(at) },
});
const call = (name: string, args: unknown, at: number) => ({
  timestamp: iso(at),
  type: "response_item",
  payload: { type: "function_call", name, arguments: JSON.stringify(args), call_id: "c" },
});
const event = (type: string, at: number, extra: Record<string, unknown> = {}) => ({
  timestamp: iso(at),
  type: "event_msg",
  payload: { type, ...extra },
});

function rollout(id: string, entries: unknown[], mtime: number): string {
  const path = join(folder(home), `rollout-2026-10-21T00-00-00-${id}.jsonl`);
  put(path, lines(...entries), mtime);
  return path;
}

describe("codexAdapter", () => {
  it("lists a rollout written a moment ago as working, with its last tool call", () => {
    rollout(
      "aaa",
      [
        meta("aaa", "/work/kinsen", NOW - 120_000),
        event("user_message", NOW - 100_000, { message: "private prompt" }),
        call("shell", { command: ["bash", "-lc", "npm test"] }, NOW - 5_000),
      ],
      NOW - 4_000,
    );
    const [one, ...rest] = codexAdapter(fakeProbe({ home }));
    expect(rest).toEqual([]);
    expect(one).toMatchObject({
      agent: "codex",
      sessionId: "aaa",
      cwd: "/work/kinsen",
      status: "working",
      activity: "Running npm test",
      startedAt: NOW - 120_000,
    });
    expect(JSON.stringify(one)).not.toContain("private prompt");
  });

  it("is idle after task_complete", () => {
    rollout(
      "bbb",
      [
        meta("bbb", "/work/kinsen", NOW - 120_000),
        call("shell", { command: ["ls"] }, NOW - 20_000),
        event("task_complete", NOW - 10_000),
      ],
      NOW - 10_000,
    );
    const [one] = codexAdapter(fakeProbe({ home }));
    expect(one?.status).toBe("idle");
    expect(one?.activity).toBe("");
  });

  it("is waiting when an approval request is the last thing in the log", () => {
    rollout(
      "ccc",
      [
        meta("ccc", "/work/kinsen", NOW - 120_000),
        call("shell", { command: ["rm", "-rf", "build"] }, NOW - 9_000),
        event("exec_approval_request", NOW - 8_000, { command: ["rm", "-rf", "build"] }),
      ],
      NOW - 8_000,
    );
    const [one] = codexAdapter(fakeProbe({ home }));
    expect(one?.status).toBe("waiting");
    expect(one?.activity).toBe("Running rm -rf build");
  });

  it("describes a patch and a local shell call", () => {
    rollout(
      "ddd",
      [
        meta("ddd", "/work/kinsen", NOW - 120_000),
        {
          timestamp: iso(NOW - 6_000),
          type: "response_item",
          payload: { type: "local_shell_call", action: { command: ["git", "status"] } },
        },
        {
          timestamp: iso(NOW - 3_000),
          type: "response_item",
          payload: { type: "custom_tool_call", name: "apply_patch", input: "*** Begin Patch" },
        },
      ],
      NOW - 3_000,
    );
    const [one] = codexAdapter(fakeProbe({ home }));
    expect(one?.recentActions.map((a) => a.text)).toEqual(["Running git status", "Editing files"]);
  });

  it("does not count the app-server daemon as a Session", () => {
    const probe = fakeProbe({
      home,
      procs: [
        { pid: 5, ppid: 1, command: "/h/.codex/packages/x/bin/codex app-server --listen unix://" },
        {
          pid: 6,
          ppid: 1,
          command: "/h/.codex/packages/x/bin/codex app-server daemon pid-update-loop",
        },
      ],
      cwds: { 5: "/", 6: "/" },
    });
    expect(codexAdapter(probe)).toEqual([]);
  });

  it("keeps a quiet rollout when a codex process runs in its folder, and drops it otherwise", () => {
    rollout("eee", [meta("eee", "/work/kinsen", NOW - 900_000)], NOW - 400_000);
    expect(codexAdapter(fakeProbe({ home }))).toEqual([]);
    const probe = fakeProbe({
      home,
      procs: [{ pid: 9, ppid: 1, command: "/usr/local/bin/codex" }],
      cwds: { 9: "/work/kinsen" },
    });
    const [one] = codexAdapter(probe);
    expect(one).toMatchObject({ sessionId: "eee", status: "idle", pid: 9 });
  });

  it("drops a rollout written ten minutes ago with no process", () => {
    rollout("fff", [meta("fff", "/work/kinsen", NOW - 900_000)], NOW - 600_000);
    expect(codexAdapter(fakeProbe({ home }))).toEqual([]);
  });

  it("has no sessions without ~/.codex, and skips a rollout with no session_meta", () => {
    expect(codexAdapter(fakeProbe({ home }))).toEqual([]);
    rollout("ggg", [call("shell", { command: ["ls"] }, NOW - 1_000)], NOW - 1_000);
    expect(codexAdapter(fakeProbe({ home }))).toEqual([]);
  });
});
