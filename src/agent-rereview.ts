import { z } from "zod";
import type { MergeRequest } from "./domain.ts";
import type { RestRunner } from "./gitlab.ts";
import { OPEN_STATUSES, parseDiffs, parseMrKey } from "./reviews.ts";
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

/** True when the newest posted-or-discarded review was posted at a commit other than `head`. */
function movedPastPosted(base: AgentReviewRow | undefined, head: string | null): boolean {
  return (
    head !== null && base?.status === "posted" && base.headSha !== null && base.headSha !== head
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
      if (
        !mr.draft &&
        old.queuedHead !== head &&
        input.now - old.changedAt >= input.afterMs &&
        movedPastPosted(input.bases.get(mr.key), head)
      ) {
        due.push(mr);
      }
    }
  }
  return { heads, due: due.sort(byAge) };
}

/** Why an automatic Agent Re-review has not run yet; see contracts/reviews.v1.json. */
export type RereviewWaitingJson =
  | { readonly reason: "waiting"; readonly dueAt: number }
  | { readonly reason: "daily-cap" | "approved" | "draft" };

export interface RereviewWaitingInput extends RereviewInput {
  /** MRs the Owner approved in GitLab, by hand or by the agent approving as the Owner. */
  readonly approved: ReadonlySet<string>;
  /** True when automatic reviews in the last 24 hours reached `review.maxPerDay`. */
  readonly capReached: boolean;
}

/**
 * Why each MR whose head moved past its last posted Agent Review has no automatic Agent Re-review
 * yet, by the rules of `planRereviews` and the queue: approved (never re-reviewed), a draft, still
 * inside `afterMs` of its last push (`dueAt` in epoch milliseconds), or due but held by the daily
 * cap. Leaves out MRs with an open review, a head already queued once, and a due MR the next poll
 * queues. A head that moved since the tracking was saved counts as pushed at `now`, as the next
 * poll records it.
 */
export function rereviewWaiting(input: RereviewWaitingInput): Map<string, RereviewWaitingJson> {
  const plan = planRereviews(input);
  const waiting = new Map<string, RereviewWaitingJson>();
  for (const mr of input.mrs) {
    const tracked = plan.heads.get(mr.key);
    const latest = input.latest.get(mr.key);
    if (
      tracked === undefined ||
      tracked.queuedHead === mr.headSha ||
      !movedPastPosted(input.bases.get(mr.key), mr.headSha) ||
      (latest !== undefined && OPEN_STATUSES.includes(latest.status))
    ) {
      continue;
    }
    if (input.approved.has(mr.key)) waiting.set(mr.key, { reason: "approved" });
    else if (mr.draft) waiting.set(mr.key, { reason: "draft" });
    else if (!plan.due.includes(mr)) {
      waiting.set(mr.key, { reason: "waiting", dueAt: tracked.changedAt + input.afterMs });
    } else if (input.capReached) waiting.set(mr.key, { reason: "daily-cap" });
  }
  return waiting;
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
