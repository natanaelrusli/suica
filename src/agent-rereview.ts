import { z } from "zod";
import type { MergeRequest } from "./domain.ts";
import type { RestRunner } from "./gitlab.ts";
import { parseDiffs, parseMrKey } from "./reviews.ts";
import type { DiffFileJson } from "./reviews.ts";
import type { AgentReviewRow, ReviewHead } from "./store.ts";

export interface RereviewInput {
  readonly mrs: readonly MergeRequest[]; // snapshot.reviewRequested
  readonly heads: ReadonlyMap<string, ReviewHead>;
  readonly bases: ReadonlyMap<string, AgentReviewRow>;
  /** The newest review of each MR, of any status. */
  readonly latest: ReadonlyMap<string, AgentReviewRow>;
  readonly now: number;
  readonly afterMs: number;
}

export interface RereviewPlan {
  /** Tracking for every MR in `mrs`; the caller sets `queuedHead` for what it queued. */
  readonly heads: Map<string, ReviewHead>;
  /** Oldest first, as `byAge` sorts today. */
  readonly due: MergeRequest[];
}

/** Oldest first; an MR without a creation date goes last. */
export function byAge(a: MergeRequest, b: MergeRequest): number {
  const at = (mr: MergeRequest): number =>
    mr.createdAt === null ? Infinity : Date.parse(mr.createdAt);
  return at(a) - at(b) || a.key.localeCompare(b.key);
}

/** True when `review` is ready, being posted or posted at `head`, so `head` needs no other review. */
export function coversHead(review: AgentReviewRow | undefined, head: string | null): boolean {
  return (
    head !== null &&
    review?.headSha === head &&
    (review.status === "ready" || review.status === "posting" || review.status === "posted")
  );
}

/**
 * Tracks the head of each review-requested MR and finds the MRs due for an Agent Re-review: not a
 * draft, the head unchanged for `afterMs` and never queued, and the newest posted-or-discarded
 * review posted at another commit. A first sighting counts as queued, so an existing database
 * never re-reviews a head that has not moved since the upgrade. So does a head whose newest review
 * is ready, being posted or posted at it (pressed by hand during the wait, or a queued re-review
 * that ran after a later push): reviewing it again would only be skipped.
 */
export function planRereviews(input: RereviewInput): RereviewPlan {
  const heads = new Map<string, ReviewHead>();
  const due: MergeRequest[] = [];
  for (const mr of input.mrs) {
    const old = input.heads.get(mr.key);
    const head = mr.headSha;
    if (head === null) {
      if (old !== undefined) heads.set(mr.key, old);
    } else if (old === undefined) {
      heads.set(mr.key, { head, changedAt: input.now, queuedHead: head });
    } else if (old.head !== head) {
      heads.set(mr.key, { head, changedAt: input.now, queuedHead: old.queuedHead });
    } else if (coversHead(input.latest.get(mr.key), head)) {
      heads.set(mr.key, { ...old, queuedHead: head });
    } else {
      heads.set(mr.key, old);
      const base = input.bases.get(mr.key);
      if (
        !mr.draft &&
        old.queuedHead !== head &&
        input.now - old.changedAt >= input.afterMs &&
        base?.status === "posted" &&
        base.headSha !== null &&
        base.headSha !== head
      ) {
        due.push(mr);
      }
    }
  }
  return { heads, due: due.sort(byAge) };
}

const SHA = /^[0-9a-f]{7,64}$/;
const mergeBaseSchema = z.object({ id: z.string() });
const compareSchema = z.object({ diffs: z.unknown(), compare_timeout: z.boolean().optional() });

/** Why the diff since the previous review is not available: logged, never shown to the model. */
export type SinceDiffUnavailable = "not-ancestor" | "timeout" | "error";

/**
 * The diff from the previously reviewed commit to the new head, from GitLab's compare API (the
 * clone is shallow). Otherwise why not: `not-ancestor` when `fromSha` is not an ancestor of
 * `toSha` (a rebase or force-push), `timeout` when GitLab cut the compare off, so its diff may be
 * partial, and `error` when an input is malformed or GitLab fails; the caller logs.
 */
export async function fetchSinceDiff(
  rest: RestRunner,
  mrKey: string,
  fromSha: string,
  toSha: string,
): Promise<DiffFileJson[] | SinceDiffUnavailable> {
  const parts = parseMrKey(mrKey);
  if (parts === undefined || !SHA.test(fromSha) || !SHA.test(toSha)) return "error";
  const repo = `projects/${encodeURIComponent(parts.projectPath)}/repository`;
  try {
    const base = mergeBaseSchema.parse(
      await rest(`${repo}/merge_base?refs%5B%5D=${fromSha}&refs%5B%5D=${toSha}`),
    );
    if (base.id !== fromSha) return "not-ancestor";
    const compare = compareSchema.parse(await rest(`${repo}/compare?from=${fromSha}&to=${toSha}`));
    if (compare.compare_timeout === true) return "timeout";
    return parseDiffs(compare.diffs).files;
  } catch {
    return "error";
  }
}
