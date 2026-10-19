import type { MergeRequest } from "./domain.ts";
import type { AgentReviewRow, ReviewHead } from "./store.ts";

export interface RereviewInput {
  readonly mrs: readonly MergeRequest[]; // snapshot.reviewRequested
  readonly heads: ReadonlyMap<string, ReviewHead>;
  readonly bases: ReadonlyMap<string, AgentReviewRow>;
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

/**
 * Tracks the head of each review-requested MR and finds the MRs due for an Agent Re-review: not a
 * draft, the head unchanged for `afterMs` and never queued, and the newest posted-or-discarded
 * review posted at another commit. A first sighting counts as queued, so an existing database
 * never re-reviews a head that has not moved since the upgrade.
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
