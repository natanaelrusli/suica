import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { FetchFailure } from "../src/gitlab.ts";
import { createLogger } from "../src/log.ts";
import {
  approveMergeRequest,
  buildReviewActivity,
  buildReviewList,
  changedSinceReview,
  readyToApprove,
  repeatLookup,
  fetchAllDiscussions,
  fetchMrDetail,
  MR_DETAIL_QUERY,
  parseDiffs,
  parseMrKey,
  resolveOwnThreads,
} from "../src/reviews.ts";
import type { MergeRequest } from "../src/domain.ts";
import type { AgentReviewRow } from "../src/store.ts";
import { openStore } from "../src/store.ts";
import type { LessonStore, NewOccurrence } from "../src/lesson-store.ts";
import { mr, person, reviewer, snapshot } from "./builders.ts";
import { thread } from "./fix-builders.ts";

function golden(name: string): unknown {
  const parsed: unknown = JSON.parse(readFileSync(`contracts/${name}`, "utf8"));
  return parsed;
}

function file(path: string, diff: string, extra: Record<string, unknown> = {}): unknown {
  return {
    old_path: path,
    new_path: path,
    new_file: false,
    renamed_file: false,
    deleted_file: false,
    diff,
    ...extra,
  };
}

function detailResponse(): unknown {
  const alice = { username: "alice", name: "Alice" };
  const bob = { username: "bob", name: "Bob" };
  return {
    data: {
      project: {
        squashReadOnly: false,
        mergeRequest: {
          title: "Add thing",
          description: "## What\nAdds the thing.",
          webUrl: "https://gitlab.example/g/p/-/merge_requests/7",
          draft: false,
          sourceBranch: "feat/thing",
          targetBranch: "main",
          createdAt: "2026-10-16T11:36:48+07:00",
          updatedAt: "2026-10-16T13:26:54+07:00",
          author: alice,
          labels: { nodes: [{ title: "backend" }] },
          headPipeline: {
            iid: "41",
            status: "RUNNING",
            path: "/g/p/-/pipelines/2921",
            startedAt: "2026-10-16T13:27:00+07:00",
            finishedAt: null,
            stages: {
              nodes: [
                {
                  name: "test",
                  status: "running",
                  jobs: {
                    nodes: [
                      {
                        name: "unit",
                        status: "SUCCESS",
                        allowFailure: false,
                        webPath: "/g/p/-/jobs/7",
                        startedAt: "2026-10-16T13:27:00+07:00",
                        finishedAt: "2026-10-16T13:28:10+07:00",
                        retried: false,
                      },
                      {
                        name: "unit",
                        status: "FAILED",
                        allowFailure: false,
                        webPath: "/g/p/-/jobs/6",
                        startedAt: "2026-10-16T13:20:00+07:00",
                        finishedAt: "2026-10-16T13:21:00+07:00",
                        retried: true,
                      },
                      {
                        name: "lint",
                        status: "RUNNING",
                        allowFailure: true,
                        webPath: null,
                        startedAt: "2026-10-16T13:27:05+07:00",
                        finishedAt: null,
                        retried: false,
                      },
                    ],
                  },
                },
                { name: "deploy", status: "created", jobs: { nodes: [] } },
              ],
            },
          },
          diffStatsSummary: { additions: 3, deletions: 1 },
          reviewers: {
            nodes: [{ username: "me", name: "Nata", mergeRequestInteraction: null }],
          },
          approvedBy: { nodes: [bob] },
          squashOnMerge: true,
          detailedMergeStatus: "MERGEABLE",
          forceRemoveSourceBranch: true,
          defaultMergeCommitMessage: "Merge branch 'feat/thing' into 'main'",
          defaultSquashCommitMessage: "Add thing",
          diffHeadSha: "0123456789abcdef0123456789abcdef01234567",
          userPermissions: { canApprove: true },
          discussions: {
            pageInfo: { hasNextPage: false },
            nodes: [
              {
                id: "gid://gitlab/Discussion/1",
                resolvable: false,
                resolved: false,
                notes: {
                  nodes: [
                    {
                      id: "gid://gitlab/Note/1",
                      body: "requested review from @me",
                      system: true,
                      createdAt: "2026-10-16T11:36:48+07:00",
                      author: alice,
                      position: null,
                    },
                  ],
                },
              },
              {
                id: "gid://gitlab/Discussion/2",
                resolvable: true,
                resolved: false,
                notes: {
                  nodes: [
                    {
                      id: "gid://gitlab/DiffNote/2",
                      body: "Why **here**?",
                      system: false,
                      createdAt: "2026-10-16T13:26:54+07:00",
                      author: bob,
                      position: { filePath: "src/a.ts", newLine: 2, oldLine: 1 },
                    },
                  ],
                },
              },
            ],
          },
        },
      },
    },
  };
}

describe("parseMrKey", () => {
  it("splits a key into project path and iid", () => {
    expect(parseMrKey("group/sub/proj!42")).toEqual({ projectPath: "group/sub/proj", iid: "42" });
  });

  it("rejects anything that could shape a request", () => {
    for (const key of [
      "proj!1",
      "g/p!x",
      "g/p",
      "g/p!1 --x",
      "g/../p!1",
      "g/p!1?a=b",
      "-f/p!1",
      "",
    ]) {
      expect(parseMrKey(key)).toBeUndefined();
    }
  });
});

const POSTED_NINE: AgentReviewRow = {
  id: 4,
  mrKey: "g/p!9",
  trigger: "auto",
  status: "posted",
  mrTitle: "MR 9",
  model: null,
  skill: null,
  modelChoice: null,
  startedAt: 1792152100000,
  cli: "claude",
  headSha: "89abcdef0123456789abcdef0123456789abcdef",
  previousSha: "0123456789abcdef0123456789abcdef01234567",
  descriptionSha: null,
  approved: false,
  approval: null,
  body: "# Code review: g/p!9\n\nNo new findings.",
  detail: "",
  activity: [],
  createdAt: 1792152050000,
  updatedAt: 1792152200000,
};

/** The posted review of the golden: a Major and a Minor finding, both numbered 1. */
const POSTED_NINE_FINDINGS: AgentReviewRow = {
  ...POSTED_NINE,
  body: "# Code review: g/p!9\n\n## Findings\n### Major\n1. `src/http.ts:12` — the client has no timeout.\n### Minor\n1. `src/log.ts:3` — a debug line is left in.",
};

function lessonOccurrence(sourceKey: string, mrKey: string): NewOccurrence {
  return {
    sourceKey,
    source: "review",
    mrKey,
    mrTitle: "T",
    mrUrl: "",
    path: "src/http.ts",
    line: 1,
    severity: "Major",
    title: "t",
    text: "t",
    outcome: "open",
    at: 1,
  };
}

/** A lesson of `scope` holding the given occurrences, as [sourceKey, mrKey]. */
function seedLesson(
  lessons: LessonStore,
  title: string,
  rows: readonly (readonly [string, string])[],
  scope = "/w/acme",
): number {
  const id = lessons.createLesson({ scope, title, rule: "r", topics: [], globs: [] }, 1);
  lessons.addOccurrences(rows.map(([key, mrKey]) => lessonOccurrence(key, mrKey)));
  lessons.attach(
    rows.map(([key]) => lessons.occurrenceBySource(key)?.id ?? 0),
    id,
    1,
  );
  return id;
}

describe("buildReviewList", () => {
  it("matches the golden contract", () => {
    const store = openStore(":memory:");
    // The posted review's Major finding repeats a lesson seen three times before in two repos;
    // its Minor finding (key "1#2") is a lesson's only occurrence.
    seedLesson(store.lessons, "HTTP clients need an explicit timeout", [
      ["review:4:1", "g/p!9"],
      ["review:1:2", "g/api!3"],
      ["thread:g/web!5:d1", "g/web!5"],
      ["review:2:1", "g/api!4"],
    ]);
    seedLesson(store.lessons, "Remove debug output", [["review:4:1#2", "g/p!9"]]);
    const list = buildReviewList(
      snapshot({
        reviewRequested: [
          mr(7, {
            draft: true,
            createdAt: "2026-10-14T09:00:00Z",
            author: person("alice", "Alice"),
            reviewers: [reviewer("me", "UNREVIEWED")],
          }),
          mr(9, {
            createdAt: "2026-10-14T10:00:00Z",
            author: person("alice", "Alice"),
            reviewers: [reviewer("me", "UNREVIEWED")],
          }),
        ],
        authored: [
          mr(8, {
            pipeline: {
              iid: "41",
              status: "FAILED",
              url: "https://gitlab.example/g/p/-/pipelines/2921",
            },
          }),
          mr(10),
        ],
      }),
      new Map([
        [
          "g/p!7",
          {
            id: 3,
            mrKey: "g/p!7",
            trigger: "manual",
            status: "ready",
            mrTitle: "MR 7",
            model: "claude-opus-5-5",
            skill: "madhani:madhani-code-review",
            modelChoice: null,
            startedAt: 1792148500000,
            cli: "claude",
            headSha: "0123456789abcdef0123456789abcdef01234567",
            previousSha: null,
            descriptionSha: null,
            approved: false,
            approval: null,
            body: "# Code review: g/p!7\n\n## Findings\n1. `src/a.ts:4`: Blocker.",
            detail: "",
            activity: [],
            createdAt: 1792148400000,
            updatedAt: 1792152000000,
          },
        ],
        ["g/p!9", POSTED_NINE_FINDINGS],
      ]),
      new Map([["g/p!9", POSTED_NINE_FINDINGS]]),
      new Map([["g/p!9", { reason: "waiting", dueAt: 1792152800000 }]]),
      new Map([
        [
          "g/p!8",
          {
            id: 5,
            mrKey: "g/p!8",
            mrTitle: "MR 8",
            trigger: "auto",
            status: "ready",
            threads: [
              thread("gid://gitlab/Discussion/a1", "n1", { action: "changed" }),
              thread("gid://gitlab/Discussion/a2", "n2", { action: "reply" }),
            ],
            pipeline: null,
            note: "",
            baseSha: "0123456789abcdef0123456789abcdef01234567",
            commitMessage: "Rename",
            diff: "diff --git a b",
            pushedSha: null,
            cli: "claude",
            model: null,
            detail: "",
            activity: [],
            createdAt: 1792152000000,
            updatedAt: 1792152100000,
            startedAt: 1792152010000,
          },
        ],
      ]),
      "minor",
      (key) => key !== "g/p!10",
      repeatLookup(true, store.lessons),
    );
    expect(list).toEqual(golden("reviews.v1.json"));
  });

  const reviewOf = (key: string, id: number, body: string): AgentReviewRow => ({
    ...POSTED_NINE,
    id,
    mrKey: key,
    body,
  });
  const twoReviews = new Map([
    ["g/p!7", reviewOf("g/p!7", 3, "## Findings\n1. `a.ts:1` — one.\n2. `b.ts:2` — two.")],
    ["g/p!9", reviewOf("g/p!9", 4, "## Findings\n1. `c.ts:3` — three.")],
  ]);
  const twoMrs = snapshot({ reviewRequested: [mr(7), mr(9)] });

  it("looks repeats up once per document, with every review's finding keys", () => {
    const calls: string[][] = [];
    const list = buildReviewList(
      twoMrs,
      twoReviews,
      new Map(),
      new Map(),
      new Map(),
      "minor",
      () => true,
      (keys) => {
        calls.push([...keys]);
        return new Map([
          ["review:4:1", { lessonId: 2, title: "Lesson", before: 1, repos: ["g/q"] }],
        ]);
      },
    );
    expect(calls).toEqual([["review:3:1", "review:3:2", "review:4:1"]]);
    expect(list.mergeRequests.map((each) => each.agentReview?.repeats)).toEqual([
      [],
      [{ finding: "1", lessonId: 2, title: "Lesson", before: 1, repos: ["g/q"] }],
    ]);
  });

  it("a finding of a lone lesson, archived lesson or lesson without a scope carries no repeat", () => {
    const store = openStore(":memory:");
    seedLesson(store.lessons, "Lone", [["review:3:1", "g/p!7"]]);
    const archived = seedLesson(store.lessons, "Archived", [
      ["review:3:2", "g/p!7"],
      ["review:1:1", "g/q!1"],
    ]);
    store.lessons.archive(archived, 2);
    seedLesson(
      store.lessons,
      "Unscoped",
      [
        ["review:4:1", "g/p!9"],
        ["review:1:2", "g/q!1"],
      ],
      "",
    );
    const list = buildReviewList(
      twoMrs,
      twoReviews,
      new Map(),
      new Map(),
      new Map(),
      "minor",
      () => true,
      repeatLookup(true, store.lessons),
    );
    expect(list.mergeRequests.map((each) => each.agentReview?.repeats)).toEqual([[], []]);
  });

  it("reads no lesson table while lessons are off", () => {
    const untouchable = new Proxy({} as Pick<LessonStore, "repeatsBySource">, {
      get: () => {
        throw new Error("read the lesson tables");
      },
    });
    const lookup = repeatLookup(false, untouchable);
    expect(lookup).toBeUndefined();
    const list = buildReviewList(
      twoMrs,
      twoReviews,
      new Map(),
      new Map(),
      new Map(),
      "minor",
      () => true,
      lookup,
    );
    expect(list.mergeRequests.map((each) => each.agentReview?.repeats)).toEqual([[], []]);
  });
});

describe("readyToApprove", () => {
  const MINOR_ONLY = "## Findings\n### Minor\n1. `a.ts:1` — a name.";
  const posted = (overrides: Partial<AgentReviewRow> = {}): AgentReviewRow => ({
    ...POSTED_NINE,
    headSha: "sha-9-a",
    descriptionSha: "d1",
    body: MINOR_ONLY,
    ...overrides,
  });
  const current = (state = "UNREVIEWED", overrides: Partial<MergeRequest> = {}) =>
    mr(9, {
      headSha: "sha-9-a",
      descriptionSha: "d1",
      reviewers: [reviewer("me", state)],
      ...overrides,
    });
  const ME_ = person("me", "Me");

  it("is true for a posted review with only minor findings left on an unchanged MR you have not approved", () => {
    expect(readyToApprove(current(), ME_, posted(), posted())).toBe(true);
  });

  it("is false once you or the agent approved, the MR changed, or a newer review is open", () => {
    expect(readyToApprove(current("APPROVED"), ME_, posted(), posted())).toBe(false);
    const approved = posted({ approved: true });
    expect(readyToApprove(current(), ME_, approved, approved)).toBe(false);
    expect(
      readyToApprove(current("UNREVIEWED", { headSha: "sha-9-b" }), ME_, posted(), posted()),
    ).toBe(false);
    expect(readyToApprove(current(), ME_, posted({ id: 5, status: "ready" }), posted())).toBe(
      false,
    );
  });

  it("is false with a Major finding, without a posted review, and after a discard", () => {
    const major = posted({ body: "## Findings\n### Major\n1. x" });
    expect(readyToApprove(current(), ME_, major, major)).toBe(false);
    expect(readyToApprove(current(), ME_, undefined, undefined)).toBe(false);
    const discarded = posted({ status: "discarded" });
    expect(readyToApprove(current(), ME_, discarded, discarded)).toBe(false);
  });

  it("follows review.approveWhen: a Minor finding is not ready under nit or clean", () => {
    expect(readyToApprove(current(), ME_, posted(), posted(), "nit")).toBe(false);
    expect(readyToApprove(current(), ME_, posted(), posted(), "clean")).toBe(false);
    const clean = posted({ body: "## Findings\nNone." });
    expect(readyToApprove(current(), ME_, clean, clean, "clean")).toBe(true);
  });

  it("still holds when a later run failed without reviewing anything new", () => {
    expect(
      readyToApprove(current(), ME_, posted({ id: 5, status: "failed", body: null }), posted()),
    ).toBe(true);
  });
});

describe("buildReviewList once you approved", () => {
  it("does not mark an MR you approved as changed since the agent's review", () => {
    const posted: AgentReviewRow = { ...POSTED_NINE, headSha: "sha-9-a" };
    const failed: AgentReviewRow = { ...POSTED_NINE, id: 6, status: "failed", headSha: null };
    const list = (state: "APPROVED" | "UNREVIEWED") =>
      buildReviewList(
        snapshot({
          reviewRequested: [mr(9, { headSha: "sha-9-b", reviewers: [reviewer("me", state)] })],
        }),
        new Map([["g/p!9", failed]]),
        new Map([["g/p!9", posted]]),
      ).mergeRequests[0];
    expect(list("UNREVIEWED")?.changedSinceReview).toEqual({ code: true, description: false });
    expect(list("APPROVED")?.changedSinceReview).toBeNull();
  });
});

describe("changedSinceReview", () => {
  const base = (overrides: Partial<AgentReviewRow> = {}): AgentReviewRow => ({
    ...POSTED_NINE,
    headSha: "sha-9-a",
    descriptionSha: "d1",
    ...overrides,
  });
  const current = (overrides: Partial<MergeRequest> = {}) =>
    mr(9, { headSha: "sha-9-a", descriptionSha: "d1", ...overrides });

  it("is null while nothing changed, without a posted base, or while GitLab has no head", () => {
    expect(changedSinceReview(current(), base(), base())).toBeNull();
    expect(changedSinceReview(current({ headSha: "sha-9-b" }), undefined, undefined)).toBeNull();
    const discarded = base({ status: "discarded", headSha: "sha-9-z" });
    expect(changedSinceReview(current(), discarded, discarded)).toBeNull();
    expect(changedSinceReview(current({ headSha: null }), base(), base())).toBeNull();
  });

  it("says which of the code and the description changed", () => {
    expect(changedSinceReview(current({ headSha: "sha-9-b" }), base(), base())).toEqual({
      code: true,
      description: false,
    });
    expect(changedSinceReview(current({ descriptionSha: "d2" }), base(), base())).toEqual({
      code: false,
      description: true,
    });
    expect(
      changedSinceReview(current({ headSha: "sha-9-b", descriptionSha: "d2" }), base(), base()),
    ).toEqual({ code: true, description: true });
  });

  it("compares the head only when the base or the snapshot has no description hash", () => {
    const old = base({ descriptionSha: null });
    expect(changedSinceReview(current({ descriptionSha: "d2" }), old, old)).toBeNull();
    expect(changedSinceReview(current({ descriptionSha: null }), base(), base())).toBeNull();
    expect(changedSinceReview(current({ headSha: "sha-9-b" }), old, old)).toEqual({
      code: true,
      description: false,
    });
  });

  it("is null while a newer review is open, and set again once that review failed or was skipped", () => {
    const pushed = current({ headSha: "sha-9-b" });
    for (const status of ["queued", "running", "ready", "posting"] as const) {
      expect(changedSinceReview(pushed, base({ id: 5, status, headSha: null }), base())).toBeNull();
    }
    for (const status of ["failed", "skipped"] as const) {
      expect(changedSinceReview(pushed, base({ id: 5, status }), base())).toEqual({
        code: true,
        description: false,
      });
    }
  });
});

describe("parseDiffs", () => {
  it("leaves out diffs GitLab marks too large and those past the per-file budget", () => {
    const { files } = parseDiffs([
      file("a", "@@ x", { too_large: true }),
      file("b", "x".repeat(200_001)),
      file("c", "@@ y"),
      file("d", ""),
    ]);
    expect(files.map((f) => f.diff)).toEqual([null, null, "@@ y", null]);
  });

  it("stops adding diff text once the total budget is spent", () => {
    const chunk = "x".repeat(200_000);
    const { files } = parseDiffs(Array.from({ length: 9 }, (_, i) => file(`f${i}`, chunk)));
    expect(files.filter((f) => f.diff !== null)).toHaveLength(7);
    expect(files[8]?.diff).toBeNull();
  });

  it("flags a full page as truncated", () => {
    expect(parseDiffs(Array.from({ length: 100 }, () => file("a", "@@"))).truncated).toBe(true);
    expect(parseDiffs([file("a", "@@")]).truncated).toBe(false);
  });

  it("rejects an unexpected shape", () => {
    expect(() => parseDiffs({ message: "404" })).toThrow(FetchFailure);
  });
});

describe("fetchMrDetail", () => {
  it("passes the key as variables and an encoded path, and matches the golden contract", async () => {
    const graphqlCalls: unknown[] = [];
    const restCalls: string[] = [];
    const detail = await fetchMrDetail(
      (query, variables) => {
        graphqlCalls.push([query, variables]);
        return Promise.resolve(detailResponse());
      },
      (path) => {
        restCalls.push(path);
        return Promise.resolve([
          file("src/a.ts", "@@ -1,2 +1,4 @@\n a\n-b\n+c\n+d\n+e\n"),
          file("big.lock", "", { too_large: true }),
        ]);
      },
      "g/p!7",
    );
    expect(graphqlCalls).toEqual([[MR_DETAIL_QUERY, { path: "g/p", iid: "7" }]]);
    expect(restCalls).toEqual(["projects/g%2Fp/merge_requests/7/diffs?per_page=100"]);
    expect(detail).toEqual(golden("mr-detail.v1.json"));
  });

  it("fails on a malformed key without calling GitLab", async () => {
    const never = (): Promise<unknown> => Promise.reject(new Error("called"));
    await expect(fetchMrDetail(never, never, "nope")).rejects.toThrow("malformed");
  });

  it("fails when the merge request does not exist", async () => {
    await expect(
      fetchMrDetail(
        () => Promise.resolve({ data: { project: null } }),
        () => Promise.resolve([]),
        "g/p!7",
      ),
    ).rejects.toThrow("not found");
  });
});

describe("approveMergeRequest", () => {
  const SHA = "0123456789abcdef0123456789abcdef01234567";
  const log = createLogger({ write: () => undefined });
  const rejecting = (httpStatus?: number) => (): Promise<unknown> =>
    Promise.reject(new FetchFailure("gitlab-error", "glab failed", httpStatus));

  it("approves at the commit the Owner saw, on an encoded path", async () => {
    const calls: unknown[] = [];
    const post = (path: string, fields: Readonly<Record<string, string>>): Promise<unknown> => {
      calls.push([path, fields]);
      return Promise.resolve({});
    };
    await expect(approveMergeRequest({ post, log }, "g/sub/p!7", SHA)).resolves.toBe("approved");
    expect(calls).toEqual([["projects/g%2Fsub%2Fp/merge_requests/7/approve", { sha: SHA }]]);
  });

  it("reports a push the Owner has not seen", async () => {
    await expect(approveMergeRequest({ post: rejecting(409), log }, "g/p!7", SHA)).resolves.toBe(
      "head-changed",
    );
  });

  it("reports any other GitLab failure as failed", async () => {
    await expect(approveMergeRequest({ post: rejecting(401), log }, "g/p!7", SHA)).resolves.toBe(
      "failed",
    );
    await expect(approveMergeRequest({ post: rejecting(), log }, "g/p!7", SHA)).resolves.toBe(
      "failed",
    );
  });

  it("refuses a malformed key or commit without calling GitLab", async () => {
    const post = (): Promise<unknown> => Promise.reject(new Error("called"));
    await expect(approveMergeRequest({ post, log }, "nope", SHA)).resolves.toBe("bad-request");
    await expect(approveMergeRequest({ post, log }, "g/p!7", "-X DELETE")).resolves.toBe(
      "bad-request",
    );
  });
});

describe("resolveOwnThreads", () => {
  const log = createLogger({ write: () => undefined });
  const page = (ids: string[], next: string | null) => ({
    data: {
      currentUser: { username: "me" },
      project: {
        mergeRequest: {
          discussions: {
            pageInfo: { hasNextPage: next !== null, endCursor: next },
            nodes: ids.map((id) => ({
              id,
              resolvable: true,
              resolved: false,
              notes: { nodes: [{ author: { username: "me" } }] },
            })),
          },
        },
      },
    },
  });

  it("reads every page of discussions on the encoded MR and resolves each open thread you started", async () => {
    const calls: [string, Readonly<Record<string, string>>][] = [];
    const graphql = (query: string, variables: Readonly<Record<string, string>> = {}) => {
      calls.push([query.includes("discussionToggleResolve") ? "resolve" : "list", variables]);
      if (query.includes("discussionToggleResolve")) {
        return Promise.resolve({ data: { discussionToggleResolve: { errors: [] } } });
      }
      return Promise.resolve(
        variables["after"] === undefined ? page(["a"], "c1") : page(["b"], null),
      );
    };
    await expect(resolveOwnThreads({ graphql, log }, "g/sub/p!7")).resolves.toEqual({
      resolved: 2,
      complete: true,
    });
    expect(calls).toEqual([
      ["list", { path: "g/sub/p", iid: "7" }],
      ["list", { path: "g/sub/p", iid: "7", after: "c1" }],
      ["resolve", { id: "a" }],
      ["resolve", { id: "b" }],
    ]);
  });

  it("resolves nothing when the discussions cannot be read, and never throws", async () => {
    const graphql = () => Promise.reject(new FetchFailure("gitlab-error", "glab failed"));
    await expect(resolveOwnThreads({ graphql, log }, "g/p!7")).resolves.toEqual({
      resolved: 0,
      complete: false,
    });
    await expect(resolveOwnThreads({ graphql, log }, "not a key")).resolves.toEqual({
      resolved: 0,
      complete: false,
    });
  });
});

describe("buildReviewList activity", () => {
  it("passes a running review's activity through, oldest first", () => {
    const running: AgentReviewRow = {
      ...POSTED_NINE,
      status: "running",
      activity: [
        { at: 1, text: "Cloning the source branch" },
        { at: 2, text: "Reading src/a.ts" },
      ],
    };
    const list = buildReviewList(
      snapshot({ reviewRequested: [mr(9, { reviewers: [reviewer("me", "UNREVIEWED")] })] }),
      new Map([["g/p!9", running]]),
    );
    expect(list.mergeRequests[0]?.agentReview?.activity).toEqual(running.activity);
  });
});

describe("buildReviewActivity", () => {
  it("names the running review's newest step, or null before its first", () => {
    const running: AgentReviewRow = {
      ...POSTED_NINE,
      status: "running",
      activity: [
        { at: 1, text: "Cloning the source branch" },
        { at: 2, text: "Reading src/a.ts" },
      ],
    };
    expect(
      buildReviewActivity({ running: [running], queued: [] }, undefined).running?.latestActivity,
    ).toBe("Reading src/a.ts");
    expect(
      buildReviewActivity({ running: [{ ...running, activity: [] }], queued: [] }, undefined)
        .running?.latestActivity,
    ).toBeNull();
  });

  it("lists every running review oldest first, and keeps the oldest as running", () => {
    const first: AgentReviewRow = { ...POSTED_NINE, id: 3, status: "running", activity: [] };
    const second: AgentReviewRow = { ...first, id: 4, mrKey: "g/p!10" };
    const activity = buildReviewActivity({ running: [first, second], queued: [] }, undefined);
    expect(activity.running?.id).toBe(3);
    expect(activity.runningReviews.map((each) => each.id)).toEqual([3, 4]);
    expect(buildReviewActivity({ running: [], queued: [] }, undefined)).toMatchObject({
      running: null,
      runningReviews: [],
    });
  });
});

describe("fetchAllDiscussions", () => {
  const page = (ids: string[], next: string | null) => ({
    data: {
      project: {
        mergeRequest: {
          discussions: {
            pageInfo: { hasNextPage: next !== null, endCursor: next },
            nodes: ids.map((id) => ({
              id,
              resolvable: true,
              resolved: false,
              notes: {
                nodes: [
                  {
                    id: `note-${id}`,
                    body: "b",
                    system: false,
                    createdAt: "2026-10-21T09:00:00Z",
                    author: { username: "bob", name: "Bob" },
                    position: null,
                  },
                ],
              },
            })),
          },
        },
      },
    },
  });

  it("reads every page, with each note in full, so the newest threads of a long MR are not cut off", async () => {
    const calls: unknown[] = [];
    const pages = [page(["d1", "d2"], "c1"), page(["d3"], null)];
    const all = await fetchAllDiscussions((_query, variables) => {
      calls.push(variables);
      return Promise.resolve(pages.shift());
    }, "g/p!7");
    expect(all.map((each) => each.id)).toEqual(["d1", "d2", "d3"]);
    expect(all[2]?.notes[0]).toEqual({
      id: "note-d3",
      body: "b",
      system: false,
      createdAt: "2026-10-21T09:00:00Z",
      author: { username: "bob", name: "Bob" },
      filePath: null,
      line: null,
    });
    expect(calls).toEqual([
      { path: "g/p", iid: "7" },
      { path: "g/p", iid: "7", after: "c1" },
    ]);
  });
});

describe("buildReviewList agentReviewPosted", () => {
  it("keeps a posted review in view when a later run was skipped, and not after a discard", () => {
    const posted: AgentReviewRow = { ...POSTED_NINE, headSha: "sha-9-a" };
    const skipped: AgentReviewRow = { ...POSTED_NINE, id: 6, status: "skipped", headSha: null };
    const list = (base: AgentReviewRow | undefined) =>
      buildReviewList(
        snapshot({
          reviewRequested: [
            mr(9, { headSha: "sha-9-a", reviewers: [reviewer("me", "UNREVIEWED")] }),
          ],
        }),
        new Map([["g/p!9", skipped]]),
        base === undefined ? new Map() : new Map([["g/p!9", base]]),
      ).mergeRequests[0];
    expect(list(posted)?.agentReviewPosted).toBe(true);
    expect(list(posted)?.changedSinceReview).toBeNull();
    expect(list({ ...posted, status: "discarded" })?.agentReviewPosted).toBe(false);
    expect(list(undefined)?.agentReviewPosted).toBe(false);
  });
});
