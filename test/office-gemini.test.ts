import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { geminiAdapter } from "../src/office/gemini.ts";
import { NOW, fakeProbe, lines, put } from "./office-builders.ts";

let home: string;
beforeEach(() => {
  home = realpathSync(mkdtempSync(join(tmpdir(), "suica-office-gemini-")));
});
afterEach(() => {
  rmSync(home, { recursive: true, force: true });
});

const iso = (ms: number) => new Date(ms).toISOString();
const chat = (project: string, id: string, entries: unknown[], mtime: number) =>
  put(
    join(home, ".gemini", "tmp", project, "chats", `session-${id}.jsonl`),
    lines(...entries),
    mtime,
  );
const mapping = (projects: Record<string, string>) =>
  put(join(home, ".gemini", "projects.json"), JSON.stringify({ projects }));

describe("geminiAdapter", () => {
  it("maps a chat to its folder through projects.json and shows the last tool call", () => {
    mapping({ "/work/cli-probe": "cli-probe" });
    chat(
      "cli-probe",
      "2026-10-21-abc",
      [
        { type: "user", timestamp: iso(NOW - 30_000), content: "private prompt" },
        {
          type: "gemini",
          timestamp: iso(NOW - 4_000),
          content: "private answer",
          toolCalls: [
            { name: "replace", args: { file_path: "/work/cli-probe/a.py" }, status: "success" },
          ],
        },
      ],
      NOW - 3_000,
    );
    const [one, ...rest] = geminiAdapter(fakeProbe({ home }));
    expect(rest).toEqual([]);
    expect(one).toMatchObject({
      agent: "gemini",
      sessionId: "2026-10-21-abc",
      cwd: "/work/cli-probe",
      status: "working",
      activity: "Editing a.py",
    });
    expect(JSON.stringify([one?.activity, one?.recentActions])).not.toContain("private");
  });

  it("titles a chat by its first prompt, skipping the session context", () => {
    mapping({ "/work/cli-probe": "cli-probe" });
    chat(
      "cli-probe",
      "t",
      [
        {
          $set: {
            messages: [
              {
                type: "user",
                timestamp: iso(NOW - 40_000),
                content: [{ text: "<session_context>\nThe Gemini CLI.\n</session_context>" }],
              },
              { type: "user", timestamp: iso(NOW - 30_000), content: "<other_tag>\nnot it" },
            ],
          },
        },
        { type: "info", timestamp: iso(NOW - 20_000), content: "Opening a browser" },
        {
          type: "user",
          timestamp: iso(NOW - 9_000),
          content: [{ text: "  Probe the CLI\nplease" }],
        },
        { type: "gemini", timestamp: iso(NOW - 2_000), content: "a" },
      ],
      NOW - 2_000,
    );
    expect(geminiAdapter(fakeProbe({ home }))[0]?.title).toBe("Probe the CLI");
    chat("cli-probe", "u", [{ type: "gemini", timestamp: iso(NOW - 1_000), content: "a" }], NOW);
    expect(geminiAdapter(fakeProbe({ home })).find((s) => s.sessionId === "u")?.title).toBeNull();
  });

  it("is idle once the model answered without a tool call", () => {
    mapping({ "/work/cli-probe": "cli-probe" });
    chat(
      "cli-probe",
      "x",
      [
        { type: "user", timestamp: iso(NOW - 9_000), content: "q" },
        { type: "gemini", timestamp: iso(NOW - 2_000), content: "a" },
      ],
      NOW - 2_000,
    );
    expect(geminiAdapter(fakeProbe({ home }))[0]?.status).toBe("idle");
  });

  it("is waiting when the last tool call awaits approval", () => {
    mapping({ "/work/cli-probe": "cli-probe" });
    chat(
      "cli-probe",
      "x",
      [
        {
          type: "gemini",
          timestamp: iso(NOW - 2_000),
          toolCalls: [
            { name: "run_shell_command", args: { command: "rm x" }, status: "awaiting_approval" },
          ],
        },
      ],
      NOW - 2_000,
    );
    const [one] = geminiAdapter(fakeProbe({ home }));
    expect(one).toMatchObject({ status: "waiting", activity: "Running rm x" });
  });

  it("keeps a quiet chat when a gemini process runs in the folder and drops it otherwise", () => {
    mapping({ "/work/cli-probe": "cli-probe" });
    chat("cli-probe", "x", [{ type: "user", timestamp: iso(NOW - 900_000) }], NOW - 900_000);
    expect(geminiAdapter(fakeProbe({ home }))).toEqual([]);
    const probe = fakeProbe({
      home,
      procs: [{ pid: 4, ppid: 1, command: "node /usr/local/bin/gemini" }],
      cwds: { 4: "/work/cli-probe" },
    });
    expect(geminiAdapter(probe)[0]).toMatchObject({ status: "idle", pid: 4 });
  });

  it("skips a project that projects.json does not map, and a missing ~/.gemini", () => {
    expect(geminiAdapter(fakeProbe({ home }))).toEqual([]);
    mapping({ "/work/other": "other" });
    chat("cli-probe", "x", [{ type: "user" }], NOW - 1_000);
    expect(geminiAdapter(fakeProbe({ home }))).toEqual([]);
  });
});
