import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { parseConfig } from "../src/config.ts";
import type { Exec, ExecOptions } from "../src/exec.ts";
import type { Notification } from "../src/format.ts";
import type { FixRow } from "../src/fix-store.ts";
import {
  buildFixPrompt,
  cleanFixDirs,
  createFixWorker,
  fixDir,
  parseFixAnswer,
  runAgentFix,
} from "../src/fix-runner.ts";
import type { FixDeps } from "../src/fix-runner.ts";
import { createLogger } from "../src/log.ts";
import type { DetectedCli } from "../src/model-cli.ts";
import { buildInvocation } from "../src/review-runner.ts";
import { openStore } from "../src/store.ts";
import type { Store } from "../src/store.ts";
import { thread } from "./fix-builders.ts";

const NOW = Date.UTC(2026, 9, 21, 9);
const SHA = "0123456789abcdef0123456789abcdef01234567";
const DIFF = "diff --git a/src/a.ts b/src/a.ts\n@@ -1 +1 @@\n-old\n+new\n";
const CLAUDE: DetectedCli = { id: "claude", name: "Claude Code", path: "/bin/claude" };
const GEMINI: DetectedCli = { id: "gemini", name: "Gemini CLI", path: "/bin/gemini" };
const CONFIG = parseConfig("gitlab:\n  hostname: gitlab.example\nmodel:\n  cli: claude\n");

const folders: string[] = [];
const stores: Store[] = [];
afterEach(() => {
  for (const store of stores.splice(0)) store.close();
  for (const folder of folders.splice(0)) rmSync(folder, { recursive: true, force: true });
});

function answer(
  threads: { id: string; action: string; reply: string }[],
  commitMessage = "Rename the total",
): string {
  return `I renamed it.\n\n\`\`\`json\n${JSON.stringify({ commitMessage, threads })}\n\`\`\`\n`;
}

function detailRaw(): unknown {
  return {
    data: {
      project: {
        squashReadOnly: false,
        mergeRequest: {
          title: "Add thing",
          description: "Adds the thing.",
          webUrl: "https://gitlab.example/g/p/-/merge_requests/7",
          draft: false,
          sourceBranch: "feat/thing",
          targetBranch: "main",
          createdAt: "2026-10-16T11:36:48+07:00",
          updatedAt: "2026-10-16T13:26:54+07:00",
          author: { username: "me", name: "Nata" },
          labels: { nodes: [] },
          headPipeline: null,
          diffStatsSummary: { additions: 3, deletions: 1 },
          reviewers: { nodes: [] },
          approvedBy: { nodes: [] },
          squashOnMerge: false,
          diffHeadSha: SHA,
          userPermissions: { canApprove: false },
          discussions: { pageInfo: { hasNextPage: false }, nodes: [] },
        },
      },
    },
  };
}

interface Call {
  readonly file: string;
  readonly args: readonly string[];
  readonly options: ExecOptions;
}

function harness(
  options: {
    result?: string;
    diff?: string;
    cliFails?: boolean;
    clis?: DetectedCli[];
    beforeCli?: () => void;
  } = {},
) {
  const folder = mkdtempSync(join(tmpdir(), "suica-fix-runner-"));
  folders.push(folder);
  const statePath = join(folder, "state.db");
  const db = openStore(":memory:");
  stores.push(db);
  const calls: Call[] = [];
  const notifications: Notification[] = [];
  const seenFiles = new Map<string, string>();
  const exec: Exec = (file, args, execOptions) => {
    calls.push({ file, args, options: execOptions });
    if (file === "git" && args.includes("clone")) {
      mkdirSync(args.at(-1) ?? "", { recursive: true });
      return Promise.resolve({ stdout: "", stderr: "" });
    }
    if (file === "git" && args.includes("rev-parse"))
      return Promise.resolve({ stdout: `${SHA}\n`, stderr: "" });
    if (file === "git" && args.includes("diff"))
      return Promise.resolve({ stdout: options.diff ?? DIFF, stderr: "" });
    if (file === "git") return Promise.resolve({ stdout: "", stderr: "" });
    for (const name of ["mr.md", "threads.md", "notes.md"]) {
      const path = join(execOptions.cwd ?? "", name);
      if (existsSync(path)) seenFiles.set(name, readFileSync(path, "utf8"));
    }
    options.beforeCli?.();
    // The real exec kills the CLI and rejects once the signal aborts.
    if (execOptions.signal?.aborted === true)
      return Promise.reject(Object.assign(new Error("aborted"), { code: "ABORT_ERR" }));
    if (options.cliFails === true)
      return Promise.reject(Object.assign(new Error("x"), { code: 1 }));
    const stdout = JSON.stringify({
      is_error: false,
      result:
        options.result ??
        answer([{ id: "d1", action: "changed", reply: "Fixed in {{sha}}: renamed it." }]),
      modelUsage: { m: { inputTokens: 100, outputTokens: 20 } },
    });
    execOptions.onStdoutLine?.(stdout);
    return Promise.resolve({ stdout, stderr: "" });
  };
  const controller = new AbortController();
  const deps: FixDeps = {
    store: db,
    config: CONFIG,
    exec,
    graphql: () => Promise.resolve(detailRaw()),
    rest: (path) =>
      Promise.resolve(
        path.endsWith("/diffs?per_page=100")
          ? []
          : { ssh_url_to_repo: "ssh://git@gitlab.example:2222/g/p.git" },
      ),
    notifier: {
      notify: (n) => {
        notifications.push(n);
        return Promise.resolve();
      },
    },
    log: createLogger({ write: () => undefined }),
    now: () => NOW,
    detectClis: () => options.clis ?? [CLAUDE],
    statePath,
    signal: controller.signal,
    cancelCheckMs: 5,
  };
  const queue = (note = ""): FixRow => {
    const id =
      db.fixes.queue(
        "g/p!7",
        "auto",
        [thread("d1", "n1"), thread("d2", "n2")],
        NOW,
        "Add thing",
        note,
      ) ?? 0;
    const row = db.fixes.get(id);
    if (row === undefined) throw new Error("not queued");
    return row;
  };
  return { db, deps, calls, notifications, seenFiles, statePath, queue, controller };
}

describe("parseFixAnswer", () => {
  const threads = [thread("d1", "n1"), thread("d2", "n2")];

  it("reads the last json block and keeps every thread of the fix, in order", () => {
    const parsed = parseFixAnswer(
      `\`\`\`json\n{"commitMessage":"old","threads":[]}\n\`\`\`\n${answer([
        { id: "d2", action: "reply", reply: "This is on purpose." },
        { id: "d1", action: "changed", reply: "Fixed in {{sha}}." },
      ])}`,
      threads,
    );
    expect(parsed?.commitMessage).toBe("Rename the total");
    expect(parsed?.threads.map((each) => [each.id, each.action, each.reply, each.post])).toEqual([
      ["d1", "changed", "Fixed in {{sha}}.", true],
      ["d2", "reply", "This is on purpose.", true],
    ]);
  });

  it("drops a thread id the fix was not given, and leaves a missing thread with an empty reply that is not posted", () => {
    const parsed = parseFixAnswer(
      answer([
        { id: "d1", action: "changed", reply: "Done." },
        { id: "gid://gitlab/Discussion/999", action: "reply", reply: "sneaky" },
      ]),
      threads,
    );
    expect(parsed?.threads.map((each) => each.id)).toEqual(["d1", "d2"]);
    expect(parsed?.threads[1]).toMatchObject({ action: "reply", reply: "", post: false });
  });

  it("gives undefined without a valid json block", () => {
    expect(parseFixAnswer("I changed things.", threads)).toBeUndefined();
    expect(parseFixAnswer("```json\n{not json}\n```", threads)).toBeUndefined();
    expect(parseFixAnswer('```json\n{"threads":"x"}\n```', threads)).toBeUndefined();
  });

  it("falls back to a plain commit message when the model left it blank", () => {
    expect(parseFixAnswer(answer([], " "), threads)?.commitMessage).toBe("Address review comments");
  });
});

describe("buildInvocation for a fix", () => {
  it("lets claude read and edit files, and codex write inside its sandbox", () => {
    const claude = buildInvocation("claude", "p", "/w", undefined, "medium", "fix").args;
    const tools = claude.slice(claude.indexOf("--tools") + 1, claude.indexOf("--allowedTools"));
    expect(tools).toEqual(["Read", "Glob", "Grep", "Edit", "Write"]);
    expect(claude).not.toContain("Bash");
    const codex = buildInvocation("codex", "p", "/w", undefined, "medium", "fix").args;
    expect(codex[codex.indexOf("--sandbox") + 1]).toBe("workspace-write");
  });
});

describe("buildFixPrompt", () => {
  it("points at the files, marks them untrusted and asks for the json block", () => {
    const prompt = buildFixPrompt("g/p!7", "feat/thing", SHA, true);
    expect(prompt).toContain("./repo");
    expect(prompt).toContain("./threads.md");
    expect(prompt).toContain("./notes.md");
    expect(prompt).toContain("untrusted");
    expect(prompt).toContain("{{sha}}");
    expect(buildFixPrompt("g/p!7", "feat/thing", SHA, false)).not.toContain("./notes.md");
  });
});

describe("runAgentFix", () => {
  it("clones the branch, runs the CLI with edit tools and keeps the checkout of a ready fix", async () => {
    const h = harness();
    const row = h.queue("keep it small");
    await runAgentFix(h.deps, row);
    const stored = h.db.fixes.get(row.id);
    expect(stored).toMatchObject({
      status: "ready",
      baseSha: SHA,
      diff: DIFF,
      commitMessage: "Rename the total",
      cli: "claude",
      model: "m",
      mrTitle: "Add thing",
    });
    expect(stored?.threads.map((each) => [each.id, each.action])).toEqual([
      ["d1", "changed"],
      ["d2", "reply"],
    ]);
    const clone = h.calls.find((call) => call.args.includes("clone"));
    expect(clone?.args).toContain("--branch=feat/thing");
    expect(clone?.args.at(-1)).toBe(join(fixDir(h.statePath, row.id), "repo"));
    const cli = h.calls.find((call) => call.file === "/bin/claude");
    expect(cli?.args).toContain("Edit");
    expect(cli?.options.timeoutMs).toBe(20 * 60_000);
    expect(h.seenFiles.get("threads.md")).toContain("Rename this");
    expect(h.seenFiles.get("notes.md")).toBe("keep it small");
    expect(existsSync(join(fixDir(h.statePath, row.id), "repo"))).toBe(true);
    expect(h.db.loadTokenUsage(0)[0]?.purpose).toBe("fix");
    expect(h.notifications.map((n) => n.title)).toEqual(["Perbaikan agen siap"]);
  });

  it("turns changed into reply when the code did not change", async () => {
    const h = harness({ diff: "" });
    const row = h.queue();
    await runAgentFix(h.deps, row);
    const stored = h.db.fixes.get(row.id);
    expect(stored?.status).toBe("ready");
    expect(stored?.diff).toBe("");
    expect(stored?.threads.every((each) => each.action === "reply")).toBe(true);
  });

  it("fails a change too large to show, marks its threads handled and deletes the checkout", async () => {
    const h = harness({ diff: "x".repeat(500_001) });
    const row = h.queue();
    await runAgentFix(h.deps, row);
    expect(h.db.fixes.get(row.id)).toMatchObject({
      status: "failed",
      detail: "the change is too large to show",
    });
    expect(h.db.fixes.handledNotes("g/p!7")).toEqual(
      new Map([
        ["d1", "n1"],
        ["d2", "n2"],
      ]),
    );
    expect(existsSync(fixDir(h.statePath, row.id))).toBe(false);
    expect(h.notifications.map((n) => n.title)).toEqual(["Perbaikan agen gagal"]);
  });

  it("fails when the model gives no answer block", async () => {
    const h = harness({ result: "I fixed everything." });
    const row = h.queue();
    await runAgentFix(h.deps, row);
    expect(h.db.fixes.get(row.id)).toMatchObject({
      status: "failed",
      detail: "the model gave no answer block",
    });
  });

  it("fails when the CLI fails, and refuses Gemini CLI", async () => {
    const failing = harness({ cliFails: true });
    const row = failing.queue();
    await runAgentFix(failing.deps, row);
    expect(failing.db.fixes.get(row.id)?.status).toBe("failed");
    expect(existsSync(fixDir(failing.statePath, row.id))).toBe(false);

    const gemini = harness({ clis: [GEMINI] });
    const other = gemini.queue();
    await runAgentFix({ ...gemini.deps, config: { ...CONFIG, model: { cli: "gemini" } } }, other);
    expect(gemini.db.fixes.get(other.id)?.detail).toMatch(/Gemini/);
  });

  it("goes back to the queue and deletes its checkout when the agent shuts down during the run", async () => {
    let h = harness();
    h = harness({ beforeCli: () => h.controller.abort() });
    const row = h.queue();
    await runAgentFix(h.deps, row);
    expect(h.db.fixes.get(row.id)).toMatchObject({ status: "queued", startedAt: null });
    expect(existsSync(fixDir(h.statePath, row.id))).toBe(false);
  });

  it("stops and stays cancelled when the Owner cancels it while it runs", async () => {
    let h = harness();
    h = harness({
      beforeCli: () => {
        h.db.fixes.transition(h.db.fixes.nextQueued()?.id ?? 1, ["running"], "cancelled", {}, NOW);
      },
    });
    const row = h.queue();
    h.db.fixes.transition(row.id, ["queued"], "queued", {}, NOW);
    await runAgentFix(h.deps, row);
    expect(h.db.fixes.get(row.id)?.status).toBe("cancelled");
    expect(existsSync(fixDir(h.statePath, row.id))).toBe(false);
  });
});

describe("cleanFixDirs and the worker", () => {
  it("deletes checkouts of fixes that are no longer running or ready", () => {
    const h = harness();
    const ready = h.queue();
    h.db.fixes.transition(ready.id, ["queued"], "ready", {}, NOW);
    const done = h.db.fixes.queue("g/p!8", "auto", [thread("d1", "n1")], NOW) ?? 0;
    h.db.fixes.transition(done, ["queued"], "pushed", {}, NOW);
    for (const id of [ready.id, done, 99])
      mkdirSync(join(fixDir(h.statePath, id), "repo"), { recursive: true });
    expect(cleanFixDirs(h.db, h.statePath)).toBe(2);
    expect(existsSync(fixDir(h.statePath, ready.id))).toBe(true);
    expect(existsSync(fixDir(h.statePath, done))).toBe(false);
    expect(existsSync(fixDir(h.statePath, 99))).toBe(false);
  });

  it("runs one fix at a time", async () => {
    const h = harness();
    const first = h.queue();
    const second = h.db.fixes.queue("g/p!8", "auto", [thread("d1", "n1")], NOW) ?? 0;
    const worker = createFixWorker(h.deps);
    worker.tick();
    expect(h.db.fixes.get(first.id)?.status).toBe("running");
    expect(h.db.fixes.get(second)?.status).toBe("queued");
    await worker.idle();
    expect(h.db.fixes.get(second)?.status).not.toBe("queued");
  });
});
