import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { OfficeJson } from "../src/office/types.ts";

let dir: string;
beforeEach(() => {
  dir = realpathSync(mkdtempSync(join(tmpdir(), "suica-office-cli-")));
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

function office(config: string): { status: number | null; stdout: string; stderr: string } {
  const configPath = join(dir, "config.yaml");
  writeFileSync(configPath, `gitlab:\n  hostname: h\n${config}`);
  const result = spawnSync("node", [join(process.cwd(), "src/cli.ts"), "office", "--json"], {
    encoding: "utf8",
    env: { ...process.env, SUICA_CONFIG: configPath, HOME: dir },
  });
  return { status: result.status, stdout: result.stdout, stderr: result.stderr };
}

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
