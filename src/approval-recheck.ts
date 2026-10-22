import { buildJudgePrompt } from "./approval-judge.ts";
import type { ApprovalVerdict } from "./approval-judge.ts";
import type { Config } from "./config.ts";
import { APPROVED, type MergeRequest, type Snapshot } from "./domain.ts";
import type { Logger } from "./log.ts";
import { changedSinceReview, OPEN_STATUSES } from "./reviews.ts";
import type { ApproveOutcome, DiscussionJson } from "./reviews.ts";
import type { AgentReviewRow, Store } from "./store.ts";

/**
 * Approval recheck: on every poll, the agent reads each reviewed MR's posted Agent Review again
 * together with the MR's discussion, and approves the MR as the Owner when it is now ready. See
 * docs/superpowers/specs/2026-10-22-approval-recheck-design.md.
 */

/** Changes the Owner asked for are theirs to lift. */
const REQUESTED_CHANGES = "REQUESTED_CHANGES";
const NOTE_MAX = 1_500;
const DISCUSSION_MAX = 40_000;

export interface RecheckCandidate {
  readonly mr: MergeRequest;
  /** The posted review the verdict is about. */
  readonly review: AgentReviewRow & { readonly headSha: string; readonly body: string };
}

/**
 * The MRs to check, oldest snapshot order: waiting for the Owner, not a draft, the Owner neither
 * approved nor asked for changes, and the newest posted-or-discarded review posted, unapproved and
 * covering the current head and description, with no review open. Empty unless `review.approve`
 * is on and the agent decides (`review.approveBy: agent`).
 */
export function recheckCandidates(
  snapshot: Snapshot,
  bases: ReadonlyMap<string, AgentReviewRow>,
  latest: ReadonlyMap<string, AgentReviewRow>,
  review: Pick<Config["review"], "approve" | "approveBy">,
): RecheckCandidate[] {
  if (!review.approve || review.approveBy !== "agent") return [];
  return snapshot.reviewRequested.flatMap((mr) => {
    const base = bases.get(mr.key);
    const mine = mr.reviewers.find((each) => each.username === snapshot.me.username)?.state;
    if (
      mr.draft ||
      mine === APPROVED ||
      mine === REQUESTED_CHANGES ||
      base?.status !== "posted" ||
      base.approved ||
      base.headSha === null ||
      base.body === null ||
      base.headSha !== mr.headSha ||
      changedSinceReview(mr, latest.get(mr.key), base) !== null
    ) {
      return [];
    }
    const open = latest.get(mr.key);
    if (open !== undefined && OPEN_STATUSES.includes(open.status)) return [];
    return [{ mr, review: { ...base, headSha: base.headSha, body: base.body } }];
  });
}

function cut(text: string, max: number): string {
  return text.length <= max ? text : `${text.slice(0, max - 1)}…`;
}

/**
 * The MR's threads for the judge, oldest first, system notes left out: each with whether it is
 * resolved and each note's author and text. A note is cut at 1,500 characters, and the oldest
 * threads are dropped so the whole stays within 40,000.
 */
export function formatDiscussion(discussions: readonly DiscussionJson[]): string {
  const threads = discussions
    .map((discussion) => ({
      resolved: discussion.resolved,
      notes: discussion.notes.filter((note) => !note.system),
    }))
    .filter((thread) => thread.notes.length > 0);
  if (threads.length === 0) return "(no comments)";
  const blocks = threads.map((thread, index) =>
    [
      `Thread ${index + 1} (${thread.resolved ? "resolved" : "open"}):`,
      ...thread.notes.map((note) => `- ${note.author.name}: ${cut(note.body.trim(), NOTE_MAX)}`),
    ].join("\n"),
  );
  const kept: string[] = [];
  let length = 0;
  for (const block of blocks.reverse()) {
    const added = block.length + (kept.length === 0 ? 0 : 2);
    if (length + added > DISCUSSION_MAX) break;
    kept.unshift(block);
    length += added;
  }
  return kept.join("\n\n");
}

export interface RecheckDeps {
  readonly store: Pick<Store, "rereviewBases" | "latestAgentReviews" | "transitionAgentReview">;
  readonly config: {
    readonly review: Pick<
      Config["review"],
      "approve" | "approveBy" | "approveWhen" | "approveRules"
    >;
  };
  readonly log: Logger;
  readonly now: () => number;
  /** Every thread of the MR. */
  readonly discussions: (key: string) => Promise<DiscussionJson[]>;
  /** The verdict on a judge prompt; may throw, which counts as not approving. */
  readonly judge: (prompt: string) => Promise<ApprovalVerdict>;
  readonly approve: (key: string, sha: string) => Promise<ApproveOutcome>;
  /** Resolves the Owner's own threads after an approval; the sentence for the row's note. */
  readonly resolveOwnThreads: (key: string) => Promise<string>;
}

export interface ApprovalRecheck {
  /** Checks every candidate of the snapshot in turn; does nothing while a round runs. */
  run(snapshot: Snapshot): Promise<void>;
}

export function createApprovalRecheck(deps: RecheckDeps): ApprovalRecheck {
  let running = false;

  const check = async ({ mr, review }: RecheckCandidate): Promise<void> => {
    const { config, log } = deps;
    const prompt = buildJudgePrompt(
      review.body,
      config.review.approveWhen,
      config.review.approveRules,
      formatDiscussion(await deps.discussions(mr.key)),
    );
    let verdict: ApprovalVerdict;
    try {
      verdict = await deps.judge(prompt);
    } catch {
      verdict = { approve: false, reason: "the agent that decides failed." };
    }
    if (!verdict.approve) {
      log.info("approval rechecked", { mr_key: mr.key, approve: false });
      return;
    }
    const outcome = await deps.approve(mr.key, review.headSha);
    log.info("approval rechecked", { mr_key: mr.key, approve: true, outcome });
    if (outcome !== "approved") return;
    const resolved = await deps.resolveOwnThreads(mr.key);
    deps.store.transitionAgentReview(
      review.id,
      ["posted"],
      "posted",
      {
        approved: true,
        approval: verdict,
        detail:
          `Approved as you after rechecking the review and discussion at commit ${review.headSha.slice(0, 8)}. ${resolved}`.trim(),
      },
      deps.now(),
    );
  };

  return {
    async run(snapshot) {
      if (running) return;
      running = true;
      try {
        const candidates = recheckCandidates(
          snapshot,
          deps.store.rereviewBases(),
          deps.store.latestAgentReviews(),
          deps.config.review,
        );
        for (const candidate of candidates) {
          try {
            await check(candidate);
          } catch (error) {
            deps.log.warn("approval recheck failed", {
              mr_key: candidate.mr.key,
              reason: error instanceof Error ? error.name : "unknown",
            });
          }
        }
      } finally {
        running = false;
      }
    },
  };
}
