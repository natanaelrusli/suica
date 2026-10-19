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

const SHA = /^[0-9a-f]{7,64}$/;
const mergeBaseSchema = z.object({ id: z.string() });
const compareSchema = z.object({ diffs: z.unknown() });

/**
 * The diff from the previously reviewed commit to the new head, from GitLab's compare API (the
 * clone is shallow). Undefined when `fromSha` is not an ancestor of `toSha` (a rebase or
 * force-push), when an input is malformed, or when GitLab fails; the caller logs.
 */
export async function fetchSinceDiff(
  rest: RestRunner,
  mrKey: string,
  fromSha: string,
  toSha: string,
): Promise<DiffFileJson[] | undefined> {
  const parts = parseMrKey(mrKey);
  if (parts === undefined || !SHA.test(fromSha) || !SHA.test(toSha)) return undefined;
  const repo = `projects/${encodeURIComponent(parts.projectPath)}/repository`;
  try {
    const base = mergeBaseSchema.parse(
      await rest(`${repo}/merge_base?refs%5B%5D=${fromSha}&refs%5B%5D=${toSha}`),
    );
    if (base.id !== fromSha) return undefined;
    const compare = compareSchema.parse(await rest(`${repo}/compare?from=${fromSha}&to=${toSha}`));
    return parseDiffs(compare.diffs).files;
  } catch {
    return undefined;
  }
}
