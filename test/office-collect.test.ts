import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { adaptersFor, collectOffice, hostAppOf } from "../src/office/collect.ts";
import type { Adapter, OfficeJson, ProcInfo, RawSession } from "../src/office/types.ts";
import { NOW, fakeProbe } from "./office-builders.ts";

let home: string;
beforeEach(() => {
  home = realpathSync(mkdtempSync(join(tmpdir(), "suica-office-collect-")));
});
afterEach(() => {
  rmSync(home, { recursive: true, force: true });
});

const raw = (over: Partial<RawSession>): RawSession => ({
  agent: "claude",
  sessionId: "s",
  cwd: "/work/suica",
  status: "working",
  activity: "Thinking",
  recentActions: [],
  startedAt: NOW - 60_000,
  updatedAt: NOW - 1_000,
  pid: null,
  ...over,
});

describe("adaptersFor", () => {
  it("runs the built-in adapters that are enabled and every valid custom one", () => {
    const names = adaptersFor({
      agents: ["codex"],
      custom: ["aider|aider|~/.aider/*.jsonl|cwd|tool"],
    }).map((a) => a.name);
    expect(names).toEqual(["codex", "aider"]);
    expect(adaptersFor({ agents: [], custom: [] })).toEqual([]);
  });
});

describe("collectOffice", () => {
  it("puts Sessions in their Room, a subfolder and a worktree with their repository", () => {
    mkdirSync(join(home, "suica", ".git", "worktrees", "topic"), { recursive: true });
    mkdirSync(join(home, "suica", "macos"), { recursive: true });
    mkdirSync(join(home, "suica-topic"), { recursive: true });
    mkdirSync(join(home, "kinsen"), { recursive: true });
    writeFileSync(
      join(home, "suica-topic", ".git"),
      `gitdir: ${join(home, "suica", ".git", "worktrees", "topic")}\n`,
    );
    const adapter: Adapter = () => [
      raw({ sessionId: "a", cwd: join(home, "suica", "macos") }),
      raw({ sessionId: "b", cwd: join(home, "suica-topic"), startedAt: NOW - 120_000 }),
      raw({ sessionId: "c", cwd: join(home, "kinsen"), agent: "codex" }),
    ];
    const doc = collectOffice([{ name: "claude", run: adapter }], fakeProbe({ home }));
    expect(doc.version).toBe(1);
    expect(doc.generatedAt).toBe(NOW);
    expect(doc.sessions.map((s) => [s.sessionId, s.roomName])).toEqual([
      ["c", "kinsen"],
      ["b", "suica"],
      ["a", "suica"],
    ]);
    expect(doc.sessions.every((s) => s.room === join(home, s.roomName))).toBe(true);
  });

  it("keeps the other agents' Sessions when one adapter throws", () => {
    const broken: Adapter = () => {
      throw new Error("unreadable");
    };
    const doc = collectOffice(
      [
        { name: "codex", run: broken },
        { name: "claude", run: () => [raw({ cwd: home })] },
      ],
      fakeProbe({ home }),
    );
    expect(doc.sessions).toHaveLength(1);
  });

  it("lists a Session once when two adapters report it", () => {
    const doc = collectOffice(
      [
        { name: "claude", run: () => [raw({ updatedAt: NOW - 9_000, cwd: home })] },
        { name: "again", run: () => [raw({ updatedAt: NOW - 1_000, cwd: home })] },
      ],
      fakeProbe({ home }),
    );
    expect(doc.sessions).toHaveLength(1);
    expect(doc.sessions[0]?.updatedAt).toBe(NOW - 1_000);
  });

  it("finds the app that hosts a Session from the parent chain", () => {
    const procs: ProcInfo[] = [
      { pid: 10, ppid: 9, command: "/Users/x/.local/bin/claude" },
      { pid: 9, ppid: 8, command: "-zsh" },
      { pid: 8, ppid: 1, command: "/usr/bin/login -fp x" },
      {
        pid: 7,
        ppid: 1,
        command: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
      },
    ];
    const withTerminal = procs.map((p) => (p.pid === 8 ? { ...p, ppid: 7 } : p));
    expect(hostAppOf(10, withTerminal)).toBe("/System/Applications/Utilities/Terminal.app");
    expect(hostAppOf(10, procs)).toBeNull();
    expect(hostAppOf(null, procs)).toBeNull();
    const desktop: ProcInfo[] = [
      {
        pid: 20,
        ppid: 19,
        command:
          "/Users/x/Library/Application Support/Claude/claude-code/2.1/h/claude.app/Contents/MacOS/claude --output-format stream",
      },
      {
        pid: 19,
        ppid: 1,
        command: "/Applications/Claude.app/Contents/Helpers/disclaimer --pgroup -- /x/claude",
      },
    ];
    expect(hostAppOf(20, desktop)).toBe("/Applications/Claude.app");
  });

  it("prints whole milliseconds, which is all the app decodes", () => {
    const doc = collectOffice(
      [
        {
          name: "claude",
          run: () => [
            raw({
              cwd: home,
              startedAt: NOW - 60_000.25,
              updatedAt: NOW - 1_000.5054,
              recentActions: [{ at: NOW - 2_000.75, text: "Reading a.ts" }],
            }),
          ],
        },
      ],
      fakeProbe({ home }),
    );
    const [one] = doc.sessions;
    expect(Number.isInteger(one?.updatedAt)).toBe(true);
    expect(Number.isInteger(one?.startedAt)).toBe(true);
    expect(one?.recentActions.every((a) => Number.isInteger(a.at))).toBe(true);
  });

  it("matches the golden contract file", () => {
    const golden = JSON.parse(readFileSync("contracts/office.v1.json", "utf8")) as OfficeJson;
    const adapter: Adapter = () => [
      raw({
        sessionId: "c1",
        cwd: "/work/suica/macos",
        pid: 4001,
        activity: "Editing OfficeView.swift",
        recentActions: [
          { at: NOW - 40_000, text: "Reading Package.swift" },
          { at: NOW - 3_000, text: "Editing OfficeView.swift" },
        ],
      }),
      raw({
        sessionId: "x1",
        agent: "codex",
        cwd: "/work/kinsen",
        status: "waiting",
        activity: "Running rm -rf build",
        startedAt: null,
        pid: null,
      }),
      raw({
        sessionId: "g1",
        agent: "gemini",
        cwd: "/work/cli-probe",
        status: "idle",
        activity: "",
        updatedAt: NOW - 90_000,
      }),
    ];
    const doc = collectOffice([{ name: "x", run: adapter }], fakeProbe({ home }), {
      roomOf: (cwd) => cwd.replace("/macos", ""),
      hostApp: (pid) => (pid === 4001 ? "/System/Applications/Utilities/Terminal.app" : null),
    });
    expect(JSON.parse(JSON.stringify(doc))).toEqual(golden);
  });
});
