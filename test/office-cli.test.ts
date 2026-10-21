import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { OfficeChatJson } from "../src/office/chat.ts";
import type { OfficeJson } from "../src/office/types.ts";

let dir: string;
beforeEach(() => {
  dir = realpathSync(mkdtempSync(join(tmpdir(), "suica-office-cli-")));
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

interface Run {
  readonly status: number | null;
  readonly stdout: string;
  readonly stderr: string;
}

function suica(config: string, args: readonly string[]): Run {
  const configPath = join(dir, "config.yaml");
  writeFileSync(configPath, `gitlab:\n  hostname: h\n${config}`);
  const result = spawnSync("node", [join(process.cwd(), "src/cli.ts"), ...args], {
    encoding: "utf8",
    env: { ...process.env, SUICA_CONFIG: configPath, HOME: dir },
  });
  return { status: result.status, stdout: result.stdout, stderr: result.stderr };
}

const office = (config: string): Run => suica(config, ["office", "--json"]);

describe("suica office --json", () => {
  it("prints the Sessions of this Mac as one document", () => {
    mkdirSync(join(dir, "proj", ".git"), { recursive: true });
    mkdirSync(join(dir, ".claude", "sessions"), { recursive: true });
    writeFileSync(
      join(dir, ".claude", "sessions", "4194000.json"),
      JSON.stringify({
        pid: 4194000,
        sessionId: "sid",
        cwd: join(dir, "proj"),
        status: "busy",
        updatedAt: Date.now() - 30_000,
      }),
    );
    const result = office("");
    expect(result.status).toBe(0);
    const document = JSON.parse(result.stdout) as OfficeJson;
    expect(document.version).toBe(1);
    expect(document.sessions).toHaveLength(1);
    expect(document.sessions[0]).toMatchObject({
      agent: "claude",
      status: "exited",
      room: join(dir, "proj"),
      roomName: "proj",
    });
  });

  it("shows nothing for an agent that is switched off", () => {
    mkdirSync(join(dir, ".claude", "sessions"), { recursive: true });
    writeFileSync(
      join(dir, ".claude", "sessions", "4194000.json"),
      JSON.stringify({ pid: 4194000, sessionId: "sid", cwd: dir, updatedAt: Date.now() }),
    );
    const result = office("office:\n  agents: [codex]\n");
    expect((JSON.parse(result.stdout) as OfficeJson).sessions).toEqual([]);
  });

  it("is an empty office on a Mac with no agents", () => {
    const result = office("");
    expect(result.status).toBe(0);
    expect((JSON.parse(result.stdout) as OfficeJson).sessions).toEqual([]);
  });
});

describe("suica office chat <agent> <sessionId> --json", () => {
  it("prints one Session's conversation as one document", () => {
    mkdirSync(join(dir, ".claude", "projects", "-proj"), { recursive: true });
    writeFileSync(
      join(dir, ".claude", "projects", "-proj", "sid.jsonl"),
      `${JSON.stringify({
        type: "user",
        timestamp: "2026-10-21T10:00:00.000Z",
        message: { role: "user", content: "Say hello" },
      })}\n${JSON.stringify({
        type: "assistant",
        timestamp: "2026-10-21T10:00:05.000Z",
        message: { role: "assistant", content: [{ type: "text", text: "Hello" }] },
      })}\n`,
    );
    const result = suica("", ["office", "chat", "claude", "sid", "--json"]);
    expect(result.status).toBe(0);
    expect(JSON.parse(result.stdout) as OfficeChatJson).toEqual({
      version: 1,
      agent: "claude",
      sessionId: "sid",
      title: "Say hello",
      messages: [
        { at: Date.parse("2026-10-21T10:00:00.000Z"), role: "user", text: "Say hello" },
        { at: Date.parse("2026-10-21T10:00:05.000Z"), role: "assistant", text: "Hello" },
      ],
    });
  });

  it("is an empty conversation for a Session it cannot find, and usage without arguments", () => {
    const missing = suica("", ["office", "chat", "codex", "nope", "--json"]);
    expect(missing.status).toBe(0);
    expect(JSON.parse(missing.stdout) as OfficeChatJson).toEqual({
      version: 1,
      agent: "codex",
      sessionId: "nope",
      title: null,
      messages: [],
    });
    const bare = suica("", ["office", "chat", "--json"]);
    expect(bare.status).toBe(2);
    expect(bare.stdout).toBe("");
    expect(bare.stderr).toMatch(/^usage: suica/);
    expect(suica("", ["office", "chat", "claude", "--json"]).status).toBe(2);
  });
});
