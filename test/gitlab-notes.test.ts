import { describe, expect, it } from "vitest";
import { SNAPSHOT_QUERY, fetchSnapshot, parseSnapshot } from "../src/gitlab.ts";

describe("SNAPSHOT_QUERY", () => {
  it("asks for notes once, in the fragment shared by both lists", () => {
    expect(SNAPSHOT_QUERY.match(/notes\(last: 50\)/g)).toHaveLength(1);
    const fragment = SNAPSHOT_QUERY.slice(SNAPSHOT_QUERY.indexOf("fragment MrFields"));
    expect(fragment).toContain("notes(last: 50)");
  });
});

describe("parseSnapshot notes on review-requested MRs", () => {
  it("keeps the notes of an MR the Owner was asked to review", () => {
    const node = {
      iid: "7",
      title: "Add thing",
      webUrl: "https://gitlab.example/g/p/-/merge_requests/7",
      draft: false,
      project: { fullPath: "g/p" },
      author: { username: "alice", name: "Alice" },
      reviewers: { nodes: [] },
      notes: {
        nodes: [{ id: "n1", system: false, author: { username: "me", name: "Nata" } }],
      },
    };
    const snapshot = parseSnapshot({
      data: {
        currentUser: {
          username: "me",
          name: "Nata",
          reviewRequestedMergeRequests: { pageInfo: { hasNextPage: false }, nodes: [node] },
          authoredMergeRequests: { pageInfo: { hasNextPage: false }, nodes: [] },
        },
      },
    });
    expect(snapshot.reviewRequested[0]?.notes).toEqual([
      { id: "n1", system: false, author: { username: "me", name: "Nata" } },
    ]);
  });
});

describe("fetchSnapshot without notes", () => {
  const empty = {
    data: {
      currentUser: {
        username: "me",
        name: "Nata",
        reviewRequestedMergeRequests: { pageInfo: { hasNextPage: false }, nodes: [] },
        authoredMergeRequests: { pageInfo: { hasNextPage: false }, nodes: [] },
      },
    },
  };

  it("leaves notes out of the query, the costly part for GitLab, and keeps the rest", async () => {
    const queries: string[] = [];
    await fetchSnapshot(
      (query) => {
        queries.push(query);
        return Promise.resolve(empty);
      },
      { notes: false },
    );
    expect(queries[0]).not.toContain("notes(");
    expect(queries[0]).toContain("diffHeadSha");
    expect(queries[0]).toContain("description");
  });

  it("asks for notes by default, as the poller needs them", async () => {
    const queries: string[] = [];
    await fetchSnapshot((query) => {
      queries.push(query);
      return Promise.resolve(empty);
    });
    expect(queries).toEqual([SNAPSHOT_QUERY]);
  });
});
