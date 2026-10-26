import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { parseConfig } from "../src/config.ts";
import type { Exec } from "../src/exec.ts";
import {
  buildFixList,
  cancelFix,
  confirmFix,
  discardFix,
  parseConfirmEdits,
  postMissingReplies,
  recoverStaleConfirms,
  retryFix,
} from "../src/fix-confirm.ts";
import type { ConfirmDeps } from "../src/fix-confirm.ts";
import { fixDir } from "../src/fix-runner.ts";
import type { FixRow } from "../src/fix-store.ts";
import type { Notification } from "../src/format.ts";
import { createLogger } from "../src/log.ts";
import { repeatLookup } from "../src/reviews.ts";
import { openStore } from "../src/store.ts";
import type { Store } from "../src/store.ts";
import { thread } from "./fix-builders.ts";

const NOW = Date.UTC(2026, 9, 21, 10);
const BASE = "0123456789abcdef0123456789abcdef01234567";
const PUSHED = "fedcba9876543210fedcba9876543210fedcba98";
const D1 = "gid://gitlab/Discussion/6a9c1750b37d513a43987b574953fceb50b03ce7";
const D2 = "gid://gitlab/Discussion/1111111111111111111111111111111111111111";
const D3 = "gid://gitlab/Discussion/2222222222222222222222222222222222222222";
const CONFIG = parseConfig("gitlab:\n  hostname: gitlab.example\n");

const folders: string[] = [];
const stores: Store[] = [];
afterEach(() => {
  for (const store of stores.splice(0)) store.close();
  for (const folder of folders.splice(0)) rmSync(folder, { recursive: true, force: true });
});

function detailRaw(headSha: string): unknown {
  return {
    data: {
      project: {
        mergeRequest: {
          title: "Add thing",
          description: "",
          webUrl: "https://gitlab.example/g/p/-/merge_requests/7",
          draft: false,
          sourceBranch: "feat/thing",
          targetBranch: "main",
          createdAt: "",
          updatedAt: "",
          author: { username: "me", name: "Nata" },
          labels: { nodes: [] },
          headPipeline: null,
          diffStatsSummary: null,
          reviewers: { nodes: [] },
          approvedBy: { nodes: [] },
          squashOnMerge: false,
          diffHeadSha: headSha,
          userPermissions: { canApprove: false },
          discussions: { pageInfo: { hasNextPage: false }, nodes: [] },
        },
      },
    },
  };
}

function harness(
  options: {
    head?: string;
    pushFails?: string;
    postFails?: (path: string) => boolean;
    diff?: string;
    owner?: string;
  } = {},
) {
  const folder = mkdtempSync(join(tmpdir(), "suica-fix-confirm-"));
  folders.push(folder);
  const statePath = join(folder, "state.db");
  const db = openStore(":memory:");
  stores.push(db);
  const git: string[][] = [];
  const posts: [string, Readonly<Record<string, string>>][] = [];
  const notifications: Notification[] = [];
  const exec: Exec = (file, args) => {
    git.push([file, ...args]);
    if (args.includes("push") && options.pushFails !== undefined) {
      return Promise.reject(
        Object.assign(new Error("push"), { code: 1, stderr: options.pushFails }),
      );
    }
    if (args.includes("rev-parse")) return Promise.resolve({ stdout: `${PUSHED}\n`, stderr: "" });
    return Promise.resolve({ stdout: "", stderr: "" });
  };
  const deps: ConfirmDeps = {
    store: db,
    config: CONFIG,
    exec,
    graphql: () => Promise.resolve(detailRaw(options.head ?? BASE)),
    rest: () => Promise.resolve([]),
    post: (path, fields) => {
      posts.push([path, fields]);
      return options.postFails?.(path) === true
        ? Promise.reject(new Error("refused"))
        : Promise.resolve({});
    },
    notifier: {
      notify: (n) => {
        notifications.push(n);
        return Promise.resolve();
      },
    },
    log: createLogger({ write: () => undefined }),
    now: () => NOW,
    statePath,
    owner: () => Promise.resolve(options.owner ?? "me"),
  };
  const ready = (): FixRow => {
    const id =
      db.fixes.queue(
        "g/p!7",
        "auto",
        [
          thread(D1, "n1", { action: "changed", reply: "Fixed in {{sha}}: renamed.", post: true }),
          thread(D2, "n2", { action: "reply", reply: "This is on purpose.", post: true }),
          thread(D3, "n3", { action: "reply", reply: "", post: false }),
        ],
        NOW - 1000,
        "Add thing",
      ) ?? 0;
    db.fixes.transition(id, ["queued"], "running", {}, NOW - 900);
    db.fixes.transition(
      id,
      ["running"],
      "ready",
      {
        baseSha: BASE,
        diff: options.diff ?? "diff --git a b\n",
        commitMessage: "Rename the total",
      },
      NOW - 800,
    );
    mkdirSync(join(fixDir(statePath, id), "work", "repo"), { recursive: true });
    const row = db.fixes.get(id);
    if (row === undefined) throw new Error("no row");
    return row;
  };
  return { db, deps, git, posts, notifications, statePath, ready };
}

const KEEP = (row: FixRow) => ({
  commitMessage: row.commitMessage,
  threads: row.threads.map((each) => ({ id: each.id, reply: each.reply, post: each.post })),
});

describe("confirmFix", () => {
  it("refuses before any git command when the branch moved since the fix was made", async () => {
    const h = harness({ head: PUSHED });
    const row = h.ready();
    expect(await confirmFix(h.deps, row.id, KEEP(row))).toBe("branch-moved");
    expect(h.git).toEqual([]);
    expect(h.posts).toEqual([]);
    expect(h.db.fixes.get(row.id)).toMatchObject({
      status: "push-failed",
      detail: "The branch moved since the fix was made; retry to redo it on the new commits.",
    });
    expect(existsSync(fixDir(h.statePath, row.id))).toBe(false);
  });

  it("commits, pushes without force, then replies with the short sha, and skips threads not to post", async () => {
    const h = harness();
    const row = h.ready();
    const edits = KEEP(row);
    edits.commitMessage = "Rename total to sum";
    edits.threads[1] = { id: D2, reply: "Kept on purpose: see the spec.", post: true };
    expect(await confirmFix(h.deps, row.id, edits)).toBe("pushed");
    const dir = fixDir(h.statePath, row.id);
    const at = ["--git-dir", join(dir, "git"), "--work-tree", join(dir, "work", "repo")];
    expect(h.git).toEqual([
      ["git", ...at, "commit", "-q", "-m", "Rename total to sum"],
      ["git", ...at, "push", "origin", "HEAD:refs/heads/feat/thing"],
      ["git", ...at, "rev-parse", "HEAD"],
    ]);
    for (const call of h.git) {
      expect(
        call.some((arg) => arg.startsWith("--force") || arg === "-f" || arg === "--no-verify"),
      ).toBe(false);
    }
    expect(h.posts).toEqual([
      [
        "projects/g%2Fp/merge_requests/7/discussions/6a9c1750b37d513a43987b574953fceb50b03ce7/notes",
        { body: "Fixed in fedcba98: renamed." },
      ],
      [
        "projects/g%2Fp/merge_requests/7/discussions/1111111111111111111111111111111111111111/notes",
        { body: "Kept on purpose: see the spec." },
      ],
    ]);
    const stored = h.db.fixes.get(row.id);
    expect(stored).toMatchObject({
      status: "pushed",
      pushedSha: PUSHED,
      detail: "",
      commitMessage: "Rename total to sum",
    });
    expect(stored?.threads.map((each) => each.posted)).toEqual([true, true, false]);
    expect(h.db.fixes.handledNotes("g/p!7")).toEqual(
      new Map([
        [D1, "n1"],
        [D2, "n2"],
        [D3, "n3"],
      ]),
    );
    expect(existsSync(fixDir(h.statePath, row.id))).toBe(false);
    expect(h.notifications).toEqual([]);
  });

  it("posts only the replies of a fix that changed no code, without git", async () => {
    const h = harness({ diff: "" });
    const row = h.ready();
    expect(await confirmFix(h.deps, row.id, KEEP(row))).toBe("pushed");
    expect(h.git).toEqual([]);
    expect(h.posts).toHaveLength(2);
    expect(h.db.fixes.get(row.id)?.pushedSha).toBeNull();
  });

  it("leaves a refused push as push-failed with the reason, and posts nothing", async () => {
    const h = harness({ pushFails: " ! [rejected]        HEAD -> feat/thing (non-fast-forward)" });
    const row = h.ready();
    expect(await confirmFix(h.deps, row.id, KEEP(row))).toBe("push-failed");
    expect(h.posts).toEqual([]);
    expect(h.db.fixes.get(row.id)).toMatchObject({
      status: "push-failed",
      detail:
        "GitLab refused the push because the branch has newer commits; retry to redo the fix on them.",
    });
  });

  it("keeps the push when a reply fails, and posts only the missing ones later", async () => {
    let refuse = true;
    const h = harness({ postFails: (path) => refuse && path.includes("/1111") });
    const row = h.ready();
    expect(await confirmFix(h.deps, row.id, KEEP(row))).toBe("partial");
    expect(h.db.fixes.get(row.id)).toMatchObject({
      status: "pushed",
      detail: "1 of 2 replies posted.",
    });
    expect(h.notifications.map((n) => n.title)).toEqual(["Perbaikan agen di-push"]);
    refuse = false;
    h.posts.length = 0;
    expect(await postMissingReplies(h.deps, row.id)).toBe("pushed");
    expect(h.posts.map(([path]) => path)).toEqual([
      "projects/g%2Fp/merge_requests/7/discussions/1111111111111111111111111111111111111111/notes",
    ]);
    expect(h.posts[0]?.[1]).toEqual({ body: "This is on purpose." });
    expect(h.db.fixes.get(row.id)?.detail).toBe("");
    expect(await postMissingReplies(h.deps, row.id)).toBe("nothing");
  });

  it("refuses a fix that is not ready, and edits naming a thread the fix does not have", async () => {
    const h = harness();
    const row = h.ready();
    const edits = KEEP(row);
    expect(
      await confirmFix(h.deps, row.id, {
        ...edits,
        threads: [{ id: "gid://gitlab/Discussion/9", reply: "x", post: true }],
      }),
    ).toBe("bad-request");
    expect(await confirmFix(h.deps, row.id, edits)).toBe("pushed");
    expect(await confirmFix(h.deps, row.id, edits)).toBe("nothing");
  });
});

describe("confirm keeps a record of what reached GitLab", () => {
  it("marks the threads handled when the push fails, so no automatic fix runs beside it", async () => {
    const h = harness({ head: PUSHED });
    const row = h.ready();
    await confirmFix(h.deps, row.id, KEEP(row));
    expect(h.db.fixes.handledNotes("g/p!7").size).toBe(3);
  });

  it("stores each reply as posted right after GitLab took it", async () => {
    const h = harness();
    const row = h.ready();
    const seen: boolean[][] = [];
    const deps = {
      ...h.deps,
      post: (path: string, fields: Readonly<Record<string, string>>) => {
        seen.push(h.db.fixes.get(row.id)?.threads.map((each) => each.posted) ?? []);
        return h.deps.post(path, fields);
      },
    };
    await confirmFix(deps, row.id, KEEP(row));
    expect(seen).toEqual([
      [false, false, false],
      [true, false, false],
    ]);
  });

  it("escapes GitLab quick actions in replies, so a reply never runs a command as you", async () => {
    const h = harness();
    const row = h.ready();
    const edits = KEEP(row);
    edits.threads[1] = { id: D2, reply: "Done.\n/merge\n  /approve\nsee a/b path", post: true };
    await confirmFix(h.deps, row.id, edits);
    expect(h.posts[1]?.[1]).toEqual({ body: "Done.\n\\/merge\n  \\/approve\nsee a/b path" });
  });

  it("ends a stale reply-only confirm as pushed, not as a failed push", () => {
    const h = harness({ diff: "" });
    const row = h.ready();
    h.db.fixes.transition(row.id, ["ready"], "confirming", {}, NOW - 20 * 60_000);
    expect(recoverStaleConfirms(h.db, NOW)).toBe(1);
    expect(h.db.fixes.get(row.id)?.status).toBe("pushed");
  });
});

describe("confirmFix on someone else's MR", () => {
  it("refuses before any git command or reply", async () => {
    const h = harness({ owner: "somebody-else" });
    const row = h.ready();
    expect(await confirmFix(h.deps, row.id, KEEP(row))).toBe("not-yours");
    expect(h.git).toEqual([]);
    expect(h.posts).toEqual([]);
    expect(h.db.fixes.get(row.id)?.status).toBe("push-failed");
  });
});

describe("parseConfirmEdits", () => {
  it("reads the Owner's edits and refuses anything else", () => {
    expect(
      parseConfirmEdits('{"commitMessage":"m","threads":[{"id":"d","reply":"r","post":true}]}'),
    ).toEqual({
      commitMessage: "m",
      threads: [{ id: "d", reply: "r", post: true }],
    });
    expect(parseConfirmEdits("nope")).toBeUndefined();
    expect(parseConfirmEdits('{"commitMessage":1,"threads":[]}')).toBeUndefined();
  });
});

describe("a fix of a failed pipeline", () => {
  const PIPELINE = {
    iid: "41",
    url: "https://gitlab.example/g/p/-/pipelines/2921",
    sha: "fedcba9876543210fedcba9876543210fedcba98",
    jobs: [{ name: "test:unit", stage: "test", url: "https://gitlab.example/g/p/-/jobs/25138" }],
    summary: "A test expects 3.",
  };
  const readyPipeline = (h: ReturnType<typeof harness>): FixRow => {
    const id = h.db.fixes.queue("g/p!7", "auto", [], NOW - 1000, "Add thing", "", PIPELINE) ?? 0;
    h.db.fixes.transition(id, ["queued"], "running", {}, NOW - 900);
    h.db.fixes.transition(
      id,
      ["running"],
      "ready",
      { baseSha: BASE, diff: "diff --git a b\n", commitMessage: "Fix the test" },
      NOW - 800,
    );
    mkdirSync(join(fixDir(h.statePath, id), "work", "repo"), { recursive: true });
    const row = h.db.fixes.get(id);
    if (row === undefined) throw new Error("no row");
    return row;
  };

  it("commits and pushes with no reply to post", async () => {
    const h = harness();
    const row = readyPipeline(h);
    expect(await confirmFix(h.deps, row.id, KEEP(row))).toBe("pushed");
    expect(h.git.some((args) => args.includes("push"))).toBe(true);
    expect(h.posts).toEqual([]);
    expect(h.db.fixes.get(row.id)).toMatchObject({ status: "pushed", pushedSha: PUSHED });
  });

  it("retries with the same pipeline, read afresh", () => {
    const h = harness();
    const row = readyPipeline(h);
    const retried = retryFix(h.deps, row.id, "the test is right; fix the code");
    const id = retried.status === "queued" ? retried.id : 0;
    expect(h.db.fixes.get(id)?.pipeline).toEqual({
      iid: "41",
      url: PIPELINE.url,
      sha: null,
      jobs: [],
      summary: "",
    });
  });
});

describe("retry, discard, cancel and recovery", () => {
  it("retries a ready fix as a new manual fix with the note, its answers cleared", () => {
    const h = harness();
    const row = h.ready();
    const retried = retryFix(h.deps, row.id, "only rename, no reply");
    expect(retried.status).toBe("queued");
    const id = retried.status === "queued" ? retried.id : 0;
    expect(h.db.fixes.get(row.id)?.status).toBe("discarded");
    expect(existsSync(fixDir(h.statePath, row.id))).toBe(false);
    const next = h.db.fixes.get(id ?? 0);
    expect(next).toMatchObject({
      status: "queued",
      trigger: "manual",
      note: "only rename, no reply",
      mrTitle: "Add thing",
    });
    expect(next?.threads.map((each) => [each.id, each.action, each.reply, each.post])).toEqual([
      [D1, null, "", false],
      [D2, null, "", false],
      [D3, null, "", false],
    ]);
    expect(retryFix(h.deps, row.id, "again")).toEqual({ status: "nothing" });
  });

  it("says busy and keeps the row when another fix of the MR is open", () => {
    const h = harness();
    const row = h.ready();
    h.db.fixes.transition(row.id, ["ready"], "push-failed", {}, NOW);
    const other = h.db.fixes.queue("g/p!7", "auto", [thread(D1, "n9")], NOW) ?? 0;
    expect(other).not.toBe(row.id);
    expect(retryFix(h.deps, row.id, "note")).toEqual({ status: "busy" });
    expect(h.db.fixes.get(row.id)?.status).toBe("push-failed");
  });

  it("discards a ready fix, marks its threads handled and deletes its checkout", () => {
    const h = harness();
    const row = h.ready();
    expect(discardFix(h.deps, row.id)).toBe(true);
    expect(h.db.fixes.get(row.id)?.status).toBe("discarded");
    expect(h.db.fixes.handledNotes("g/p!7").size).toBe(3);
    expect(existsSync(fixDir(h.statePath, row.id))).toBe(false);
    expect(discardFix(h.deps, row.id)).toBe(false);
  });

  it("cancels a queued or running fix only", () => {
    const h = harness();
    const queued = h.db.fixes.queue("g/p!9", "auto", [thread(D1, "n1")], NOW) ?? 0;
    expect(cancelFix(h.db, queued, NOW)).toBe(true);
    expect(h.db.fixes.get(queued)).toMatchObject({
      status: "cancelled",
      detail: "Cancelled by you.",
    });
    expect(cancelFix(h.db, h.ready().id, NOW)).toBe(false);
    // Your cancel sticks: the next poll does not queue the same threads again.
    expect(h.db.fixes.handledNotes("g/p!9")).toEqual(new Map([[D1, "n1"]]));
  });

  it("ends a confirm cut off long ago: pushed when it had pushed, else push-failed", () => {
    const h = harness();
    const stale = h.ready();
    h.db.fixes.transition(stale.id, ["ready"], "confirming", {}, NOW - 20 * 60_000);
    const fresh = h.db.fixes.queue("g/p!8", "auto", [thread(D1, "n1")], NOW) ?? 0;
    h.db.fixes.transition(fresh, ["queued"], "confirming", {}, NOW - 60_000);
    const pushed = h.db.fixes.queue("g/p!9", "auto", [thread(D1, "n1")], NOW) ?? 0;
    h.db.fixes.transition(
      pushed,
      ["queued"],
      "confirming",
      { pushedSha: PUSHED },
      NOW - 20 * 60_000,
    );
    expect(recoverStaleConfirms(h.db, NOW)).toBe(2);
    expect(h.db.fixes.get(stale.id)).toMatchObject({
      status: "push-failed",
      detail: "Suica stopped while pushing. Check the branch in GitLab before you retry.",
    });
    expect(h.db.fixes.get(fresh)?.status).toBe("confirming");
    expect(h.db.fixes.get(pushed)?.status).toBe("pushed");
  });
});

describe("buildFixList", () => {
  it("matches the golden contract, with the diff only on a ready fix", () => {
    const h = harness();
    const row = h.ready();
    h.db.fixes.appendActivity(row.id, NOW, "never shown: not running");
    const done = h.db.fixes.queue("g/p!8", "auto", [thread(D1, "n1")], NOW - 500) ?? 0;
    h.db.fixes.transition(
      done,
      ["queued"],
      "failed",
      { detail: "the model gave no answer block", diff: "x" },
      NOW - 400,
    );
    const pipeline = {
      iid: "41",
      url: "https://gitlab.example/g/p/-/pipelines/2921",
      sha: null,
      jobs: [],
      summary: "",
    };
    const piped =
      h.db.fixes.queue("g/p!9", "manual", [], NOW - 300, "Bump deps", "", pipeline) ?? 0;
    h.db.fixes.transition(
      piped,
      ["queued"],
      "skipped",
      {
        detail: "A runner lost its network.",
        pipeline: {
          ...pipeline,
          sha: "fedcba9876543210fedcba9876543210fedcba98",
          jobs: [
            { name: "test:unit", stage: "test", url: "https://gitlab.example/g/p/-/jobs/25138" },
          ],
          summary: "A runner lost its network.",
        },
      },
      NOW - 200,
    );
    // The first thread of g/p!7 repeats a lesson flagged once before, in g/api.
    const lessonId = h.db.lessons.createLesson(
      { scope: "/w/acme", title: "Name things for what they do", rule: "r", topics: [], globs: [] },
      NOW,
    );
    const occurrence = (sourceKey: string, mrKey: string, at = NOW) => ({
      sourceKey,
      source: "thread" as const,
      mrKey,
      mrTitle: "T",
      mrUrl: "",
      path: null,
      line: null,
      severity: "",
      title: "t",
      text: "t",
      outcome: "open" as const,
      at,
    });
    h.db.lessons.addOccurrences([
      occurrence(`thread:g/p!7:${D1}`, "g/p!7"),
      occurrence("review:1:1", "g/api!2", NOW - 1000),
    ]);
    h.db.lessons.attach(
      [`thread:g/p!7:${D1}`, "review:1:1"].map(
        (key) => h.db.lessons.occurrenceBySource(key)?.id ?? 0,
      ),
      lessonId,
      NOW,
    );
    const golden: unknown = JSON.parse(readFileSync("contracts/fixes.v1.json", "utf8"));
    expect(
      JSON.parse(
        JSON.stringify(buildFixList(h.db.fixes.list(0), repeatLookup(true, h.db.lessons))),
      ),
    ).toEqual(golden);
  });

  it("looks thread repeats up once for the whole list, and gives null without lessons", () => {
    const h = harness();
    h.ready();
    h.db.fixes.queue("g/p!8", "auto", [thread(D2, "n2")], NOW);
    const calls: string[][] = [];
    const list = buildFixList(h.db.fixes.list(0), (keys) => {
      calls.push([...keys]);
      return new Map();
    });
    expect(calls).toHaveLength(1);
    expect(calls[0]).toContain(`thread:g/p!8:${D2}`);
    expect(calls[0]).toContain(`thread:g/p!7:${D1}`);
    const threads = buildFixList(h.db.fixes.list(0)).fixes.flatMap((fix) => fix.threads);
    expect(threads.length).toBeGreaterThan(1);
    expect(threads.every((each) => each.repeat === null)).toBe(true);
    expect(list.fixes.flatMap((fix) => fix.threads).every((each) => each.repeat === null)).toBe(
      true,
    );
  });
});
