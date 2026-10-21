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
    expect(JSON.stringify([one?.activity, one?.recentActions])).not.toContain("private prompt");
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

  it("titles a rollout by its first UserMessage item", () => {
    rollout(
      "ttt",
      [
        meta("ttt", "/work/kinsen", NOW - 120_000),
        {
          timestamp: iso(NOW - 110_000),
          type: "response_item",
          payload: {
            type: "message",
            role: "user",
            content: [{ type: "input_text", text: "Earlier message item" }],
          },
        },
        event("item_completed", NOW - 100_000, {
          item: { type: "UserMessage", content: [{ type: "text", text: "  Port the\nlock SDK " }] },
        }),
      ],
      NOW - 4_000,
    );
    expect(codexAdapter(fakeProbe({ home }))[0]?.title).toBe("Port the");
  });

  it("falls back to the first user message item that is not a preamble, else no title", () => {
    const userItem = (text: string, at: number) => ({
      timestamp: iso(at),
      type: "response_item",
      payload: { type: "message", role: "user", content: [{ type: "input_text", text }] },
    });
    rollout(
      "uuu",
      [
        meta("uuu", "/work/kinsen", NOW - 120_000),
        userItem("# AGENTS.md instructions", NOW - 110_000),
        userItem("<permissions instructions>", NOW - 109_000),
        userItem(">>> review preamble", NOW - 108_000),
        userItem("Make the tests green", NOW - 100_000),
      ],
      NOW - 4_000,
    );
    rollout("vvv", [meta("vvv", "/work/other", NOW - 120_000)], NOW - 3_000);
    const titles = Object.fromEntries(
      codexAdapter(fakeProbe({ home })).map((s) => [s.sessionId, s.title]),
    );
    expect(titles).toEqual({ uuu: "Make the tests green", vvv: null });
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

  it("finds the rollout a process has open, however old its folder", () => {
    const old = new Date(NOW - 3 * 86_400_000);
    const path = join(
      home,
      ".codex",
      "sessions",
      String(old.getFullYear()),
      String(old.getMonth() + 1).padStart(2, "0"),
      String(old.getDate()).padStart(2, "0"),
      "rollout-old-hhh.jsonl",
    );
    put(path, lines(meta("hhh", "/work/kinsen", NOW - 4 * 86_400_000)), NOW - 200_000);
    const probe = fakeProbe({
      home,
      procs: [{ pid: 12, ppid: 1, command: "/usr/local/bin/codex resume" }],
      cwds: { 12: "/work/kinsen" },
      files: { 12: [path] },
    });
    expect(codexAdapter(probe)[0]).toMatchObject({ sessionId: "hhh", pid: 12 });
  });

  it("gives a wrapper and its child one Session, not two", () => {
    rollout("new", [meta("new", "/work/kinsen", NOW - 90_000)], NOW - 30_000);
    rollout("old", [meta("old", "/work/kinsen", NOW - 900_000)], NOW - 500_000);
    const probe = fakeProbe({
      home,
      procs: [
        { pid: 20, ppid: 1, command: "node /usr/local/bin/codex" },
        { pid: 21, ppid: 20, command: "/usr/local/lib/codex/bin/codex" },
      ],
      cwds: { 20: "/work/kinsen", 21: "/work/kinsen" },
    });
    expect(codexAdapter(probe).map((s) => s.sessionId)).toEqual(["new"]);
  });
});
