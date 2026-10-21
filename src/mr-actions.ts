import { FetchFailure } from "./gitlab.ts";
import type { PostRunner, PutRunner } from "./gitlab.ts";
import { parseMrKey } from "./reviews.ts";

export type CommentOutcome = "posted" | "empty" | "bad-key" | "failed";
export type MergeOutcome =
  | "merged"
  | "scheduled"
  | "not-mergeable"
  | "sha-mismatch"
  | "bad-key"
  | "failed";

export interface MergeOptions {
  readonly squash: boolean;
  readonly removeSourceBranch: boolean;
  /** The squash or merge commit message; blank leaves GitLab's default. */
  readonly message: string;
  /** Merge once the running pipeline succeeds, instead of now. */
  readonly whenPipelineSucceeds: boolean;
}

const SHA_PATTERN = /^[0-9a-f]{7,64}$/;

function mrPath(key: string): string | undefined {
  const parts = parseMrKey(key);
  return parts === undefined
    ? undefined
    : `projects/${encodeURIComponent(parts.projectPath)}/merge_requests/${parts.iid}`;
}

/** Posts a general comment on the MR as the Owner. */
export async function commentOnMergeRequest(
  post: PostRunner,
  key: string,
  body: string,
): Promise<CommentOutcome> {
  const path = mrPath(key);
  if (path === undefined) return "bad-key";
  if (body.trim() === "") return "empty";
  try {
    await post(`${path}/notes`, { body });
    return "posted";
  } catch {
    return "failed";
  }
}

/**
 * Merges the MR at `sha`, the commit the Owner saw, so a newer push is never merged by surprise
 * (GitLab answers 409). 405 and 406 mean GitLab will not merge it now.
 */
export async function mergeMergeRequest(
  put: PutRunner,
  key: string,
  sha: string,
  options: MergeOptions,
): Promise<MergeOutcome> {
  const path = mrPath(key);
  if (path === undefined || !SHA_PATTERN.test(sha)) return "bad-key";
  const message = options.message.trim();
  const fields: Record<string, string> = {
    sha,
    squash: String(options.squash),
    should_remove_source_branch: String(options.removeSourceBranch),
  };
  if (message !== "") {
    fields[options.squash ? "squash_commit_message" : "merge_commit_message"] = options.message;
  }
  if (options.whenPipelineSucceeds) fields["merge_when_pipeline_succeeds"] = "true";
  let reply: unknown;
  try {
    reply = await put(`${path}/merge`, fields);
  } catch (error) {
    const status = error instanceof FetchFailure ? error.httpStatus : undefined;
    if (status === 405 || status === 406) return "not-mergeable";
    if (status === 409) return "sha-mismatch";
    return "failed";
  }
  const state =
    typeof reply === "object" && reply !== null && "state" in reply ? reply.state : undefined;
  return state === "merged" ? "merged" : "scheduled";
}
