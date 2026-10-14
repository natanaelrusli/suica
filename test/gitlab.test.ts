import { describe, expect, it } from "vitest";
import type { Exec } from "../src/exec.ts";
import { FetchFailure, glabRunner, parseSnapshot } from "../src/gitlab.ts";

const config = { hostname: "gitlab.example", glabPath: "glab", timeoutSeconds: 60 };

function reviewerNode(username: string, state: string | null): Record<string, unknown> {
  return {
    username,
    name: `Name ${username}`,
    mergeRequestInteraction: state === null ? null : { reviewState: state },
  };
}

function node(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    iid: "7",
    title: "Add thing",
    webUrl: "https://gitlab.example/g/p/-/merge_requests/7",
    draft: false,
    project: { fullPath: "g/p" },
    author: { username: "alice", name: "Alice" },
    reviewers: { nodes: [reviewerNode("me", "UNREVIEWED")] },
    ...overrides,
  };
}

function payload(
  parts: { reviewRequested?: unknown[]; authored?: unknown[]; hasNext?: boolean } = {},
): unknown {
  return {
    data: {
      currentUser: {
        username: "me",
        name: "Nata",
        reviewRequestedMergeRequests: {
          pageInfo: { hasNextPage: parts.hasNext ?? false },
          nodes: parts.reviewRequested ?? [],
        },
        authoredMergeRequests: {
          pageInfo: { hasNextPage: false },
          nodes: parts.authored ?? [],
        },
      },
    },
  };
}

function kindOf(fn: () => unknown): string {
  try {
    fn();
  } catch (error) {
    if (error instanceof FetchFailure) return error.kind;
    throw error;
  }
  return "no-failure";
}

describe("parseSnapshot", () => {
  it("maps review-requested and authored MRs", () => {
    const snapshot = parseSnapshot(
      payload({
        reviewRequested: [node()],
        authored: [
          node({
            iid: "9",
            notes: {
              nodes: [
                {
                  id: "gid://gitlab/Note/1",
                  system: true,
                  author: { username: "bob", name: "Bob" },
                },
              ],
            },
          }),
        ],
      }),
    );
    expect(snapshot.me).toEqual({ username: "me", name: "Nata" });
    expect(snapshot.reviewRequested[0]).toMatchObject({
      key: "g/p!7",
      iid: 7,
      title: "Add thing",
      draft: false,
      author: { username: "alice", name: "Alice" },
      reviewers: [{ username: "me", state: "UNREVIEWED" }],
      notes: [],
    });
    expect(snapshot.authored[0]?.notes).toEqual([
      { id: "gid://gitlab/Note/1", system: true, author: { username: "bob", name: "Bob" } },
    ]);
  });

  it("survives a deleted author, a null review state and a null interaction", () => {
    const snapshot = parseSnapshot(
      payload({
        reviewRequested: [
          node({
            author: null,
            reviewers: { nodes: [reviewerNode("me", null), reviewerNode("x", "APPROVED")] },
            notes: { nodes: [{ id: "n1", system: false, author: null }] },
          }),
        ],
      }),
    );
    const found = snapshot.reviewRequested[0];
    expect(found?.author.username).toBe("ghost");
    expect(found?.reviewers.map((r) => r.state)).toEqual(["UNREVIEWED", "APPROVED"]);
    expect(found?.notes[0]?.author.username).toBe("ghost");
  });

  it("fails loudly when there is another page instead of silently truncating", () => {
    expect(kindOf(() => parseSnapshot(payload({ hasNext: true })))).toBe("gitlab-error");
  });

  it("fails on GraphQL errors, a missing current user and a malformed payload", () => {
    expect(kindOf(() => parseSnapshot({ errors: [{ message: "boom" }] }))).toBe("gitlab-error");
    expect(kindOf(() => parseSnapshot({ data: { currentUser: null } }))).toBe("gitlab-auth");
    expect(kindOf(() => parseSnapshot({ data: "nope" }))).toBe("gitlab-error");
  });

  it("refuses a web URL that is not http(s)", () => {
    expect(
      kindOf(() =>
        parseSnapshot(payload({ reviewRequested: [node({ webUrl: "javascript:alert(1)" })] })),
      ),
    ).toBe("gitlab-error");
  });
});

describe("glabRunner", () => {
  const failing =
    (error: object): Exec =>
    () =>
      Promise.reject(Object.assign(new Error("exec failed"), error));

  async function kindOfRun(exec: Exec): Promise<string> {
    try {
      await glabRunner(config, exec)("query { x }");
    } catch (error) {
      if (error instanceof FetchFailure) return error.kind;
      throw error;
    }
    return "no-failure";
  }

  it("passes the host and the query to glab and parses the JSON output", async () => {
    const calls: string[][] = [];
    const run = glabRunner(config, (file, args) => {
      calls.push([file, ...args]);
      return Promise.resolve({ stdout: '{"ok":true}', stderr: "" });
    });
    await expect(run("query { x }")).resolves.toEqual({ ok: true });
    expect(calls).toEqual([
      ["glab", "api", "graphql", "--hostname", "gitlab.example", "-f", "query=query { x }"],
    ]);
  });

  it("classifies failures", async () => {
    expect(await kindOfRun(failing({ code: "ENOENT" }))).toBe("glab-missing");
    expect(await kindOfRun(failing({ killed: true }))).toBe("gitlab-unreachable");
    expect(
      await kindOfRun(
        failing({ code: 1, stderr: "dial tcp: lookup gitlab.example: no such host" }),
      ),
    ).toBe("gitlab-unreachable");
    expect(await kindOfRun(failing({ code: 1, stderr: "HTTP 401 Unauthorized" }))).toBe(
      "gitlab-auth",
    );
    expect(await kindOfRun(failing({ code: 1, stderr: "something odd" }))).toBe("gitlab-error");
  });

  it("treats non-JSON output as a GitLab error", async () => {
    expect(await kindOfRun(() => Promise.resolve({ stdout: "<html>", stderr: "" }))).toBe(
      "gitlab-error",
    );
  });
});
