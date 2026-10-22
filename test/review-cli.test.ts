import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { openStore } from "../src/store.ts";

let dir: string;
let configPath: string;
let statePath: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "suica-review-cli-"));
  configPath = join(dir, "config.yaml");
  statePath = join(dir, "state", "state.db");
  writeFileSync(
    configPath,
    `gitlab:\n  hostname: h\nstatePath: ${statePath}\nmodel:\n  cli: claude\nreview:\n  skill: go-review\n`,
  );
  mkdirSync(join(dir, ".claude/skills/go-review"), { recursive: true });
  writeFileSync(join(dir, ".claude/skills/go-review/SKILL.md"), "---\ndescription: Go\n---\n");
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

/** The reply line; log lines come before it. */
function suica(args: string[]): { status: number | null; line: string | undefined } {
  const result = spawnSync("node", ["src/cli.ts", ...args], {
    encoding: "utf8",
    env: { ...process.env, SUICA_CONFIG: configPath, HOME: dir },
  });
  return { status: result.status, line: result.stdout.trimEnd().split("\n").at(-1) };
}

describe("suica review options and queue", () => {
  it("lists the installed skills with the defaults", () => {
    const { status, line } = suica(["review", "options", "--json"]);
    expect(status).toBe(0);
    const doc = JSON.parse(line ?? "") as {
      defaults: { skill: string; model: string | null };
      skills: { name: string }[];
    };
    expect(doc.defaults).toEqual({ skill: "go-review", model: null });
    expect(doc.skills.map((skill) => skill.name)).toEqual(["go-review"]);
  });

  it("queues with an installed skill and a model, and refuses others", () => {
    const reply = (args: string[]) => suica(["review", "queue", "g/p!7", ...args, "--json"]);
    expect(reply(["--skill", "flutter-review"])).toEqual({
      status: 1,
      line: '{"status":"bad-skill"}',
    });
    expect(reply(["--model", "-x"])).toEqual({ status: 1, line: '{"status":"bad-model"}' });
    expect(reply(["--skill", "go-review", "--model", "opus"])).toEqual({
      status: 0,
      line: '{"status":"queued"}',
    });
    // The queued review takes the newer choice.
    expect(reply(["--model", "haiku"])).toEqual({ status: 0, line: '{"status":"queued"}' });
    expect(reply([])).toEqual({ status: 0, line: '{"status":"already-queued"}' });

    const store = openStore(statePath);
    const queued = store.agentReviewActivity().queued;
    store.close();
    expect(queued.map((row) => [row.mrKey, row.skill, row.modelChoice])).toEqual([
      ["g/p!7", null, "haiku"],
    ]);
  });
});
