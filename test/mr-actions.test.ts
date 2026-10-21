import { describe, expect, it } from "vitest";
import { FetchFailure } from "../src/gitlab.ts";
import { commentOnMergeRequest, mergeMergeRequest } from "../src/mr-actions.ts";
import type { MergeOptions } from "../src/mr-actions.ts";

type Call = [string, Readonly<Record<string, string>>];

function recorder(reply: unknown = {}): {
  calls: Call[];
  run: (path: string, fields: Readonly<Record<string, string>>) => Promise<unknown>;
} {
  const calls: Call[] = [];
  return {
    calls,
    run: (path, fields) => {
      calls.push([path, fields]);
      return Promise.resolve(reply);
    },
  };
}

function refusing(status: number | undefined) {
  return (): Promise<unknown> =>
    Promise.reject(new FetchFailure("gitlab-error", "glab failed", status));
}

const OPTIONS: MergeOptions = {
  squash: true,
  removeSourceBranch: true,
  message: "Add thing",
  whenPipelineSucceeds: false,
};

describe("commentOnMergeRequest", () => {
  it("posts the body as a note on the MR", async () => {
    const { calls, run } = recorder();
    expect(await commentOnMergeRequest(run, "g/p!7", "Looks **good**")).toBe("posted");
    expect(calls).toEqual([["projects/g%2Fp/merge_requests/7/notes", { body: "Looks **good**" }]]);
  });

  it("refuses a blank body and a bad key without calling GitLab", async () => {
    const { calls, run } = recorder();
    expect(await commentOnMergeRequest(run, "g/p!7", "  \n ")).toBe("empty");
    expect(await commentOnMergeRequest(run, "nope", "hi")).toBe("bad-key");
    expect(calls).toEqual([]);
  });

  it("reports a refused post as failed", async () => {
    expect(await commentOnMergeRequest(refusing(500), "g/p!7", "hi")).toBe("failed");
  });
});

describe("mergeMergeRequest", () => {
  it("sends the sha, the options and the squash message", async () => {
    const { calls, run } = recorder({ state: "merged" });
    expect(await mergeMergeRequest(run, "g/p!7", "0123abc", OPTIONS)).toBe("merged");
    expect(calls).toEqual([
      [
        "projects/g%2Fp/merge_requests/7/merge",
        {
          sha: "0123abc",
          squash: "true",
          should_remove_source_branch: "true",
          squash_commit_message: "Add thing",
        },
      ],
    ]);
  });

  it("sends a merge commit message without squash, and asks to wait for the pipeline only when told", async () => {
    const { calls, run } = recorder({ state: "opened", merge_when_pipeline_succeeds: true });
    const outcome = await mergeMergeRequest(run, "g/p!7", "0123abc", {
      squash: false,
      removeSourceBranch: false,
      message: "Merge it",
      whenPipelineSucceeds: true,
    });
    expect(outcome).toBe("scheduled");
    expect(calls[0]?.[1]).toEqual({
      sha: "0123abc",
      squash: "false",
      should_remove_source_branch: "false",
      merge_commit_message: "Merge it",
      merge_when_pipeline_succeeds: "true",
    });
  });

  it("leaves the message out when it is blank, so GitLab uses its default", async () => {
    const { calls, run } = recorder({ state: "merged" });
    await mergeMergeRequest(run, "g/p!7", "0123abc", { ...OPTIONS, message: " " });
    expect(calls[0]?.[1]).not.toHaveProperty("squash_commit_message");
  });

  it("maps GitLab's refusals: 405 and 406 not mergeable, 409 a newer push, anything else failed", async () => {
    expect(await mergeMergeRequest(refusing(405), "g/p!7", "0123abc", OPTIONS)).toBe(
      "not-mergeable",
    );
    expect(await mergeMergeRequest(refusing(406), "g/p!7", "0123abc", OPTIONS)).toBe(
      "not-mergeable",
    );
    expect(await mergeMergeRequest(refusing(409), "g/p!7", "0123abc", OPTIONS)).toBe(
      "sha-mismatch",
    );
    expect(await mergeMergeRequest(refusing(undefined), "g/p!7", "0123abc", OPTIONS)).toBe(
      "failed",
    );
  });

  it("refuses a bad key or sha without calling GitLab", async () => {
    const { calls, run } = recorder();
    expect(await mergeMergeRequest(run, "nope", "0123abc", OPTIONS)).toBe("bad-key");
    expect(await mergeMergeRequest(run, "g/p!7", "-x", OPTIONS)).toBe("bad-key");
    expect(calls).toEqual([]);
  });
});
