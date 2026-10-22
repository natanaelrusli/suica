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

  it("queues with --auto as an automatic review, within review.maxPerDay", () => {
    writeFileSync(
      configPath,
      `gitlab:\n  hostname: h\nstatePath: ${statePath}\nreview:\n  maxPerDay: 1\n`,
    );
    // Pushes the agent tracks and has not queued a re-review for yet.
    const seeded = openStore(statePath);
    seeded.saveReviewHeads(
      new Map([
        ["g/p!7", { head: "b7", changedAt: 1, queuedHead: "a7" }],
        ["g/p!8", { head: "b8", changedAt: 1, queuedHead: "a8" }],
      ]),
    );
    seeded.close();
    const reply = (key: string) => suica(["review", "queue", key, "--auto", "--json"]);
    expect(reply("g/p!7")).toEqual({ status: 0, line: '{"status":"queued"}' });
    expect(reply("g/p!8")).toEqual({ status: 1, line: '{"status":"daily-cap"}' });

    const store = openStore(statePath);
    const queued = store.agentReviewActivity().queued;
    store.close();
    expect(queued.map((row) => [row.mrKey, row.trigger])).toEqual([["g/p!7", "auto"]]);
  }, 20_000);

  it("does not queue with --auto a head the agent already queued or a review covers", () => {
    const store = openStore(statePath);
    const posted = (key: string, head: string): void => {
      const id = store.queueAgentReview(key, "auto", 1, undefined) ?? 0;
      store.transitionAgentReview(id, ["queued"], "running", {}, 1);
      store.transitionAgentReview(id, ["running"], "ready", { headSha: head }, 1);
      store.transitionAgentReview(id, ["ready"], "posting", {}, 1);
      store.transitionAgentReview(id, ["posting"], "posted", {}, 1);
    };
    // !1: the agent queued its head itself; !2: a review is posted at its head; !3: a push after
    // the posted review that the agent has not queued yet; !4: never tracked by the agent.
    posted("g/p!1", "a1");
    posted("g/p!2", "a2");
    posted("g/p!3", "a3");
    store.saveReviewHeads(
      new Map([
        ["g/p!1", { head: "b1", changedAt: 1, queuedHead: "b1" }],
        ["g/p!2", { head: "a2", changedAt: 1, queuedHead: "" }],
        ["g/p!3", { head: "b3", changedAt: 1, queuedHead: "" }],
      ]),
    );
    store.close();

    const reply = (key: string) => suica(["review", "queue", key, "--auto", "--json"]);
    expect(reply("g/p!1")).toEqual({ status: 0, line: '{"status":"covered"}' });
    expect(reply("g/p!2")).toEqual({ status: 0, line: '{"status":"covered"}' });
    expect(reply("g/p!4")).toEqual({ status: 0, line: '{"status":"covered"}' });
    expect(reply("g/p!3")).toEqual({ status: 0, line: '{"status":"queued"}' });
    // Pressed by hand, a review is queued whatever the agent tracked.
    expect(suica(["review", "queue", "g/p!1", "--json"])).toEqual({
      status: 0,
      line: '{"status":"queued"}',
    });
  }, 20_000);
});
