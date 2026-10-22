import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { Exec, ExecOptions } from "../src/exec.ts";
import {
  MAX_MESSAGE_CHARS,
  SEND_TIMEOUT_MS,
  geminiResumeId,
  sendArgs,
  sendToSession,
  type SendDeps,
} from "../src/office/send.ts";
import type { OfficeSession, OfficeStatus } from "../src/office/types.ts";

const session = (
  agent: string,
  sessionId: string,
  status: OfficeStatus = "waiting",
): OfficeSession => ({
  agent,
  sessionId,
  title: null,
  cwd: "/work/suica",
  status,
  activity: "Waiting for you",
  recentActions: [],
  startedAt: null,
  updatedAt: 1,
  pid: 42,
  room: "/work/suica",
  roomName: "suica",
  hostApp: null,
});

interface Call {
  readonly file: string;
  readonly args: readonly string[];
  readonly options: ExecOptions;
}

function deps(
  sessions: readonly OfficeSession[],
  overrides: Partial<SendDeps> = {},
): { deps: SendDeps; calls: Call[] } {
  const calls: Call[] = [];
  const exec: Exec = (file, args, options) => {
    calls.push({ file, args, options });
    return Promise.resolve({ stdout: "done", stderr: "" });
  };
  return {
    calls,
    deps: {
      sessions: () => sessions,
      cliPath: (agent) => `/bin/${agent}`,
      geminiResumeId: () => "196f9b80-201b-4845-8b7f-e34f7f0e6e88",
      exec,
      ...overrides,
    },
  };
}

describe("sendArgs", () => {
  it("keeps the message after -- or bound to --prompt=, so it can never become a flag", () => {
    expect(sendArgs("claude", "c1", "--dangerously-skip-permissions")).toEqual([
      "-p",
      "--resume",
      "c1",
      "--",
      "--dangerously-skip-permissions",
    ]);
    expect(sendArgs("codex", "x1", "-y")).toEqual([
      "exec",
      "resume",
      "--skip-git-repo-check",
      "x1",
      "--",
      "-y",
    ]);
    expect(sendArgs("gemini", "g1", "--yolo")).toEqual(["--resume", "g1", "--prompt=--yolo"]);
  });
});

describe("sendToSession", () => {
  it("runs one headless turn in the Session's folder and waits for it", async () => {
    const { deps: d, calls } = deps([session("claude", "c1")]);
    expect(await sendToSession(d, "claude", "c1", "  Fix the failing test\n")).toBe("sent");
    expect(calls).toEqual([
      {
        file: "/bin/claude",
        args: ["-p", "--resume", "c1", "--", "Fix the failing test"],
        options: { timeoutMs: SEND_TIMEOUT_MS, cwd: "/work/suica" },
      },
    ]);
  });

  it("resumes a Gemini Session by the full id from its chat file", async () => {
    const { deps: d, calls } = deps([session("gemini", "2026-10-06T08-47-196f9b80", "idle")]);
    expect(await sendToSession(d, "gemini", "2026-10-06T08-47-196f9b80", "hi")).toBe("sent");
    expect(calls[0]?.args).toEqual([
      "--resume",
      "196f9b80-201b-4845-8b7f-e34f7f0e6e88",
      "--prompt=hi",
    ]);
  });

  it("does not start a turn on top of a running one", async () => {
    const { deps: d, calls } = deps([session("codex", "x1", "working")]);
    expect(await sendToSession(d, "codex", "x1", "hi")).toBe("busy");
    expect(calls).toEqual([]);
  });

  it("says why nothing was sent", async () => {
    const live = [session("claude", "c1"), session("aider", "a1"), session("gemini", "g1")];
    const cases: [Partial<SendDeps>, string, string, string, string][] = [
      [{}, "claude", "c1", "  \n ", "empty"],
      [{}, "claude", "c1", "x".repeat(MAX_MESSAGE_CHARS + 1), "too_long"],
      [{}, "aider", "a1", "hi", "unsupported"],
      [{}, "claude", "other", "hi", "not_found"],
      [{}, "codex", "c1", "hi", "not_found"],
      [{ cliPath: () => null }, "claude", "c1", "hi", "agent_missing"],
      [{ geminiResumeId: () => null }, "gemini", "g1", "hi", "not_found"],
    ];
    for (const [overrides, agent, id, message, expected] of cases) {
      const { deps: d, calls } = deps(live, overrides);
      expect(await sendToSession(d, agent, id, message), expected).toBe(expected);
      expect(calls).toEqual([]);
    }
  });

  it("reports a turn that fails or times out", async () => {
    const { deps: d } = deps([session("claude", "c1")], {
      exec: () => Promise.reject(Object.assign(new Error("exit 1"), { code: 1 })),
    });
    expect(await sendToSession(d, "claude", "c1", "hi")).toBe("failed");
  });
});

describe("geminiResumeId", () => {
  let home: string;
  beforeEach(() => {
    home = realpathSync(mkdtempSync(join(tmpdir(), "suica-office-send-")));
  });
  afterEach(() => {
    rmSync(home, { recursive: true, force: true });
  });

  const chat = (name: string, firstLine: string): void => {
    const dir = join(home, ".gemini", "tmp", "proj", "chats");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, `session-${name}.jsonl`), `${firstLine}\n{"$set":{}}\n`);
  };

  it("reads the session id from the chat file's first line", () => {
    chat(
      "2026-10-06T08-47-196f9b80",
      JSON.stringify({ sessionId: "196f9b80-201b-4845-8b7f-e34f7f0e6e88", kind: "main" }),
    );
    expect(geminiResumeId(home, "2026-10-06T08-47-196f9b80")).toBe(
      "196f9b80-201b-4845-8b7f-e34f7f0e6e88",
    );
  });

  it("gives nothing for a missing file, a bad first line, an id that is no UUID or a path", () => {
    chat("bad", "not json");
    chat("noid", JSON.stringify({ sessionId: "latest" }));
    expect(geminiResumeId(home, "missing")).toBeNull();
    expect(geminiResumeId(home, "bad")).toBeNull();
    expect(geminiResumeId(home, "noid")).toBeNull();
    expect(geminiResumeId(home, "../proj/chats/session-bad")).toBeNull();
  });
});
