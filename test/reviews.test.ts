import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { FetchFailure } from "../src/gitlab.ts";
import { createLogger } from "../src/log.ts";
import {
  approveMergeRequest,
  buildReviewList,
  fetchMrDetail,
  MR_DETAIL_QUERY,
  parseDiffs,
  parseMrKey,
} from "../src/reviews.ts";
import { mr, person, reviewer, snapshot } from "./builders.ts";

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
          headPipeline: { status: "SUCCESS" },
          diffStatsSummary: { additions: 3, deletions: 1 },
          reviewers: {
            nodes: [{ username: "me", name: "Nata", mergeRequestInteraction: null }],
          },
          approvedBy: { nodes: [bob] },
          squashOnMerge: true,
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

describe("buildReviewList", () => {
  it("matches the golden contract", () => {
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
        authored: [mr(8)],
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
            startedAt: 1792148500000,
            cli: "claude",
            headSha: "0123456789abcdef0123456789abcdef01234567",
            previousSha: null,
            body: "# Code review: g/p!7\n\n## Findings\n1. `src/a.ts:4`: Blocker.",
            detail: "",
            createdAt: 1792148400000,
            updatedAt: 1792152000000,
          },
        ],
        [
          "g/p!9",
          {
            id: 4,
            mrKey: "g/p!9",
            trigger: "auto",
            status: "posted",
            mrTitle: "MR 9",
            model: null,
            startedAt: 1792152100000,
            cli: "claude",
            headSha: "89abcdef0123456789abcdef0123456789abcdef",
            previousSha: "0123456789abcdef0123456789abcdef01234567",
            body: "# Code review: g/p!9\n\nNo new findings.",
            detail: "",
            createdAt: 1792152050000,
            updatedAt: 1792152200000,
          },
        ],
      ]),
    );
    expect(list).toEqual(golden("reviews.v1.json"));
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
