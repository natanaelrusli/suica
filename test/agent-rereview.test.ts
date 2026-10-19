import { describe, expect, it } from "vitest";
import { fetchSinceDiff, planRereviews } from "../src/agent-rereview.ts";
import type { RereviewInput } from "../src/agent-rereview.ts";
import type { AgentReviewRow, AgentReviewStatus, ReviewHead } from "../src/store.ts";
import { mr } from "./builders.ts";

const NOW = Date.UTC(2026, 9, 19, 9);
const MINUTE = 60_000;
const AFTER = 10 * MINUTE;

function base(status: AgentReviewStatus, headSha: string | null, mrKey = "g/p!1"): AgentReviewRow {
  return {
    id: 1,
    mrKey,
    trigger: "auto",
    status,
    mrTitle: null,
    model: null,
    startedAt: null,
    cli: null,
    headSha,
    previousSha: null,
    body: null,
    detail: "",
    createdAt: NOW - 60 * MINUTE,
    updatedAt: NOW - 60 * MINUTE,
  };
}

/** Plans one poll of `g/p!1` and the given tracking, with defaults for everything else. */
function plan(overrides: Partial<RereviewInput>) {
  return planRereviews({
    mrs: [mr(1)],
    heads: new Map(),
    bases: new Map([["g/p!1", base("posted", "sha-1-a")]]),
    latest: new Map(),
    now: NOW,
    afterMs: AFTER,
    ...overrides,
  });
}

/** `g/p!1` at head `sha-1-b`, unchanged for 20 minutes, after a review queued for `sha-1-a`. */
const settled = new Map<string, ReviewHead>([
  ["g/p!1", { head: "sha-1-b", changedAt: NOW - 20 * MINUTE, queuedHead: "sha-1-a" }],
]);

describe("planRereviews", () => {
  it("records a first-seen MR's head as already queued and makes nothing due", () => {
    const result = plan({ mrs: [mr(1, { headSha: "sha-1-b" })] });
    expect(result.heads.get("g/p!1")).toEqual({
      head: "sha-1-b",
      changedAt: NOW,
      queuedHead: "sha-1-b",
    });
    expect(result.due).toEqual([]);
  });

  it("waits rereviewAfterMinutes after the last head change, so a burst of pushes makes one re-review of the last head", () => {
    let heads: ReadonlyMap<string, ReviewHead> = new Map([
      ["g/p!1", { head: "sha-1-a", changedAt: NOW - 60 * MINUTE, queuedHead: "sha-1-a" }],
    ]);
    const poll = (headSha: string, minutes: number) => {
      const result = plan({ mrs: [mr(1, { headSha })], heads, now: NOW + minutes * MINUTE });
      heads = result.heads;
      return result.due.map((each) => each.headSha);
    };
    expect(poll("sha-1-b", 0)).toEqual([]);
    expect(heads.get("g/p!1")).toEqual({
      head: "sha-1-b",
      changedAt: NOW,
      queuedHead: "sha-1-a",
    });
    expect(poll("sha-1-c", 5)).toEqual([]);
    expect(poll("sha-1-c", 14)).toEqual([]);
    expect(poll("sha-1-c", 15)).toEqual(["sha-1-c"]);
  });

  it("is due only when the newest posted-or-discarded review is posted at another commit", () => {
    const at = (row: AgentReviewRow | undefined) =>
      plan({
        mrs: [mr(1, { headSha: "sha-1-b" })],
        heads: settled,
        bases: new Map(row === undefined ? [] : [["g/p!1", row]]),
      }).due.length;
    expect(at(base("posted", "sha-1-a"))).toBe(1);
    expect(at(base("discarded", "sha-1-a"))).toBe(0);
    expect(at(undefined)).toBe(0);
    expect(at(base("posted", "sha-1-b"))).toBe(0);
    expect(at(base("posted", null))).toBe(0);
  });

  it("never makes the same head due twice", () => {
    const queued = new Map<string, ReviewHead>([
      ["g/p!1", { head: "sha-1-b", changedAt: NOW - 20 * MINUTE, queuedHead: "sha-1-b" }],
    ]);
    const result = plan({ mrs: [mr(1, { headSha: "sha-1-b" })], heads: queued });
    expect(result.due).toEqual([]);
    expect(result.heads.get("g/p!1")?.queuedHead).toBe("sha-1-b");
  });

  it("counts a head whose newest review is ready, being posted or posted as queued, as when the Owner reviewed it by hand during the wait", () => {
    const newest = (row: AgentReviewRow) =>
      plan({
        mrs: [mr(1, { headSha: "sha-1-b" })],
        heads: settled,
        latest: new Map([["g/p!1", row]]),
      });
    for (const status of ["ready", "posting", "posted"] as const) {
      const covered = newest({ ...base(status, "sha-1-b"), id: 2 });
      expect(covered.due).toEqual([]);
      expect(covered.heads.get("g/p!1")).toEqual({
        ...settled.get("g/p!1"),
        queuedHead: "sha-1-b",
      });
    }
    // Before the wait is over too, so the head never becomes due.
    const early = plan({
      mrs: [mr(1, { headSha: "sha-1-b" })],
      heads: new Map([
        ["g/p!1", { head: "sha-1-b", changedAt: NOW - MINUTE, queuedHead: "sha-1-a" }],
      ]),
      latest: new Map([["g/p!1", { ...base("ready", "sha-1-b"), id: 2 }]]),
    });
    expect(early.heads.get("g/p!1")?.queuedHead).toBe("sha-1-b");
    for (const row of [
      { ...base("ready", "sha-1-z"), id: 2 },
      { ...base("skipped", "sha-1-b"), id: 2 },
      { ...base("failed", "sha-1-b"), id: 2 },
      { ...base("running", null), id: 2 },
    ]) {
      expect(newest(row).due.map((each) => each.key)).toEqual(["g/p!1"]);
    }
  });

  it("does not re-review a head that a queued re-review reached by running after a later push", () => {
    // Queued at sha-1-b, the run checked out sha-1-c, pushed meanwhile; that review is now ready.
    let heads: ReadonlyMap<string, ReviewHead> = new Map([
      ["g/p!1", { head: "sha-1-b", changedAt: NOW - 20 * MINUTE, queuedHead: "sha-1-b" }],
    ]);
    const latest = new Map([["g/p!1", { ...base("ready", "sha-1-c"), id: 2 }]]);
    const poll = (minutes: number) => {
      const result = plan({
        mrs: [mr(1, { headSha: "sha-1-c" })],
        heads,
        latest,
        now: NOW + minutes * MINUTE,
      });
      heads = result.heads;
      return result.due.length;
    };
    expect(poll(0)).toBe(0);
    expect(poll(10)).toBe(0);
    expect(heads.get("g/p!1")?.queuedHead).toBe("sha-1-c");
  });

  it("skips drafts but keeps tracking their head, and an MR whose head GitLab has not computed keeps its entry", () => {
    const draft = plan({ mrs: [mr(1, { headSha: "sha-1-b", draft: true })], heads: settled });
    expect(draft.due).toEqual([]);
    expect(draft.heads.get("g/p!1")).toEqual(settled.get("g/p!1"));

    const moved = plan({ mrs: [mr(1, { headSha: "sha-1-c", draft: true })], heads: settled });
    expect(moved.heads.get("g/p!1")).toEqual({
      head: "sha-1-c",
      changedAt: NOW,
      queuedHead: "sha-1-a",
    });

    const unknown = plan({
      mrs: [mr(1, { headSha: null }), mr(2, { headSha: null })],
      heads: settled,
    });
    expect(unknown.due).toEqual([]);
    expect(unknown.heads.get("g/p!1")).toEqual(settled.get("g/p!1"));
    expect(unknown.heads.has("g/p!2")).toBe(false);
  });

  it("drops MRs that are no longer review requested, and lists due MRs oldest first", () => {
    const heads = new Map<string, ReviewHead>([
      ...settled,
      ["g/p!2", { head: "sha-2-b", changedAt: NOW - 20 * MINUTE, queuedHead: "sha-2-a" }],
      ["g/p!9", { head: "sha-9-a", changedAt: NOW - 20 * MINUTE, queuedHead: "sha-9-a" }],
    ]);
    const result = plan({
      mrs: [
        mr(1, { headSha: "sha-1-b", createdAt: "2026-10-17T10:00:00Z" }),
        mr(2, { headSha: "sha-2-b", createdAt: "2026-10-16T10:00:00Z" }),
      ],
      heads,
      bases: new Map([
        ["g/p!1", base("posted", "sha-1-a")],
        ["g/p!2", base("posted", "sha-2-a", "g/p!2")],
      ]),
    });
    expect([...result.heads.keys()].sort()).toEqual(["g/p!1", "g/p!2"]);
    expect(result.due.map((each) => each.key)).toEqual(["g/p!2", "g/p!1"]);
  });
});

describe("fetchSinceDiff", () => {
  const FROM = "a".repeat(40);
  const TO = "b".repeat(40);
  const COMPARE = {
    commit: { id: TO },
    diffs: [
      {
        old_path: "x.ts",
        new_path: "y.ts",
        new_file: false,
        renamed_file: true,
        deleted_file: false,
        diff: "@@ -1 +1 @@\n-a\n+b\n",
      },
    ],
  };
  /** A REST fake that records each path and answers merge_base with `mergeBase`. */
  function rest(mergeBase: string | Error = FROM) {
    const paths: string[] = [];
    const run = (path: string): Promise<unknown> => {
      paths.push(path);
      if (path.includes("/merge_base?")) {
        return mergeBase instanceof Error
          ? Promise.reject(mergeBase)
          : Promise.resolve({ id: mergeBase });
      }
      return Promise.resolve(COMPARE);
    };
    return { run, paths };
  }

  it("fetchSinceDiff makes no request for a malformed SHA and says why when GitLab fails", async () => {
    for (const [key, from, to] of [
      ["g/p!1", "--upload-pack=x", TO],
      ["g/p!1", FROM, "ABCDEF1"],
      ["g/p!1", "abc", TO],
      ["g/p!1", FROM, `${TO}&x=1`],
      ["not a key", FROM, TO],
    ] as const) {
      const fake = rest();
      expect(await fetchSinceDiff(fake.run, key, from, to)).toBe("error");
      expect(fake.paths).toEqual([]);
    }
    const failing = rest(new Error("glab"));
    expect(await fetchSinceDiff(failing.run, "g/p!1", FROM, TO)).toBe("error");
    // An answer GitLab would not give is a failure too.
    expect(await fetchSinceDiff(() => Promise.resolve({ nope: 1 }), "g/p!1", FROM, TO)).toBe(
      "error",
    );
  });

  it("fetchSinceDiff returns the compare diff only when the previous commit is the merge base", async () => {
    const ancestor = rest();
    expect(await fetchSinceDiff(ancestor.run, "g/sub/p!1", FROM, TO)).toEqual([
      {
        oldPath: "x.ts",
        newPath: "y.ts",
        newFile: false,
        renamedFile: true,
        deletedFile: false,
        diff: "@@ -1 +1 @@\n-a\n+b\n",
      },
    ]);
    expect(ancestor.paths).toEqual([
      `projects/g%2Fsub%2Fp/repository/merge_base?refs%5B%5D=${FROM}&refs%5B%5D=${TO}`,
      `projects/g%2Fsub%2Fp/repository/compare?from=${FROM}&to=${TO}`,
    ]);

    const rebased = rest("c".repeat(40));
    expect(await fetchSinceDiff(rebased.run, "g/p!1", FROM, TO)).toBe("not-ancestor");
    expect(rebased.paths).toHaveLength(1);
  });

  it("fetchSinceDiff treats a compare GitLab cut off by its timeout as unavailable, not as a complete diff", async () => {
    const timedOut = (path: string): Promise<unknown> =>
      Promise.resolve(
        path.includes("/merge_base?") ? { id: FROM } : { ...COMPARE, compare_timeout: true },
      );
    expect(await fetchSinceDiff(timedOut, "g/p!1", FROM, TO)).toBe("timeout");
    const inTime = (path: string): Promise<unknown> =>
      Promise.resolve(
        path.includes("/merge_base?") ? { id: FROM } : { ...COMPARE, compare_timeout: false },
      );
    expect(await fetchSinceDiff(inTime, "g/p!1", FROM, TO)).toHaveLength(1);
  });
});
