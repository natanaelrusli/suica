import { UNREVIEWED } from "../domain.ts";
import type { MergeRequest, ReviewState, Snapshot } from "../domain.ts";
import { myReviewState, reviewerKey } from "../events.ts";
import { countFindings } from "../inline-review.ts";
import type { PreviousState } from "../events.ts";
import type {
  Intent,
  IntentMr,
  RereviewMr,
  RereviewReviewer,
  Round,
  TeamsPlan,
  TeamsState,
  TemplateName,
} from "./types.ts";
import { describeFindings } from "./templates.ts";

export interface PlanConfig {
  readonly maxMessagesPerReviewer: number;
  readonly reminderAfterMs: number;
  readonly noticeDebounceMs: number;
  readonly rereviewAfterMs: number;
}

export interface PlanInput {
  readonly snapshot: Snapshot;
  readonly previous: PreviousState;
  readonly state: TeamsState;
  readonly now: number;
  readonly config: PlanConfig;
}

const APPROVED = "APPROVED";
const REQUESTED_CHANGES = "REQUESTED_CHANGES";
const UNAPPROVED = "UNAPPROVED";

function intentMr(mr: MergeRequest): IntentMr {
  return { key: mr.key, iid: mr.iid, projectPath: mr.projectPath, title: mr.title, url: mr.url };
}

function noticeVariant(round: Round): TemplateName | undefined {
  if (round.myState === APPROVED && round.noticedState !== APPROVED) return "notice.approved";
  if (round.myState === REQUESTED_CHANGES && round.noticedState !== REQUESTED_CHANGES) {
    return "notice.changes";
  }
  if (round.myNotes > round.noticedNotes) return "notice.comments";
  return undefined;
}

interface RereviewPlan {
  readonly intents: readonly Intent[];
  readonly mrs: ReadonlyMap<string, RereviewMr>;
  readonly reviewers: ReadonlyMap<string, RereviewReviewer>;
  /** Reviewers a Re-review Nudge is still due for: a plain Reviewer Nudge would repeat it. */
  readonly awaiting: ReadonlySet<string>;
}

function hasReviewed(state: ReviewState, notes: number): boolean {
  return state !== UNREVIEWED || notes > 0;
}

/**
 * A new note, or a move to a review state. A move to UNAPPROVED or UNREVIEWED is not review
 * activity: GitLab can reset them when the Owner pushes.
 */
function isReviewActivity(before: RereviewReviewer, state: ReviewState, notes: number): boolean {
  const movedToReview = state !== before.state && state !== UNREVIEWED && state !== UNAPPROVED;
  return notes > before.notes || movedToReview;
}

/** What the ledger holds for a Reviewer after this poll, given what it held before. */
function advanceReviewer(
  before: RereviewReviewer | undefined,
  state: ReviewState,
  notes: number,
  head: string,
  headChanged: boolean,
): RereviewReviewer {
  if (before === undefined) {
    // First sighting: what exists counts as already seen.
    return { reviewedHead: hasReviewed(state, notes) ? head : null, state, notes, nudged: false };
  }
  if (isReviewActivity(before, state, notes)) {
    return { reviewedHead: head, state, notes, nudged: false };
  }
  const reRequested = before.state !== UNREVIEWED && state === UNREVIEWED && !headChanged;
  if (reRequested && before.reviewedHead !== null) {
    // The Owner pressed GitLab's re-request: the plain Reviewer Nudge asks for this head, so the
    // round is closed and a waiting Re-review Nudge is no longer needed.
    return { reviewedHead: head, state, notes, nudged: false };
  }
  return { ...before, state, notes };
}

/**
 * Pure: the Re-review Nudge ledger after this poll and the nudges due. A Reviewer who reviewed an
 * older head is nudged once the head has stood for `rereviewAfterMs`; a new review (or a GitLab
 * re-request) closes the round. Nothing is due until both baselines exist, and the ledger of a
 * poll that is not live is rebuilt from the snapshot, so history is never announced.
 */
function planRereview(input: PlanInput): RereviewPlan {
  const { snapshot, previous, state, now, config } = input;
  const live = previous.baselineDone && state.baselineDone;
  const intents: Intent[] = [];
  const mrs = new Map<string, RereviewMr>();
  const reviewers = new Map<string, RereviewReviewer>();
  const awaiting = new Set<string>();

  for (const mr of snapshot.authored) {
    const known = live ? state.rereviewMrs.get(mr.key) : undefined;
    const others = mr.reviewers.filter((reviewer) => reviewer.username !== snapshot.me.username);
    const { headSha } = mr;
    if (headSha === null) {
      // GitLab has not computed the head yet: keep what is known and decide on the next poll.
      if (known !== undefined) mrs.set(mr.key, known);
      for (const reviewer of others) {
        const key = reviewerKey(mr.key, reviewer.username);
        const kept = live ? state.rereviewReviewers.get(key) : undefined;
        if (kept !== undefined) reviewers.set(key, kept);
      }
      continue;
    }
    const headChanged = known !== undefined && known.head !== headSha;
    // While a draft the head keeps counting as just pushed, so a ready MR waits the debounce too.
    const becameReady = !mr.draft && !previous.trackedAuthored.has(mr.key);
    const current: RereviewMr =
      known === undefined || headChanged || mr.draft || becameReady
        ? { head: headSha, changedAt: now }
        : known;
    mrs.set(mr.key, current);

    for (const reviewer of others) {
      const key = reviewerKey(mr.key, reviewer.username);
      const notes = mr.notes.filter(
        (note) => !note.system && note.author.username === reviewer.username,
      ).length;
      const before = known === undefined ? undefined : state.rereviewReviewers.get(key);
      let next = advanceReviewer(before, reviewer.state, notes, headSha, headChanged);
      const owed = next.reviewedHead !== null && next.reviewedHead !== headSha && !next.nudged;
      if (owed) awaiting.add(key);
      if (live && owed && !mr.draft && now - current.changedAt >= config.rereviewAfterMs) {
        intents.push({
          dedupeKey: `rereview:${key}:${headSha}`,
          kind: "rereview",
          variant: "rereview",
          mr: intentMr(mr),
          recipient: { username: reviewer.username, name: reviewer.name },
        });
        next = { ...next, nudged: true };
      }
      reviewers.set(key, next);
    }
  }
  return { intents, mrs, reviewers, awaiting };
}

/**
 * Pure: decides which Teams messages are due and how the ledger changes. Nothing is queued until
 * both the Plan 1 baseline and the Teams baseline exist, so switching Teams on later never
 * announces history.
 */
export function planTeams(input: PlanInput): TeamsPlan {
  const { snapshot, previous, state, now, config } = input;
  const live = previous.baselineDone && state.baselineDone;
  const rereview = planRereview(input);
  const intents: Intent[] = [];
  const nudgeUpdates: { key: string; record: { sentCount: number; lastSentAt: number } }[] = [];
  const roundUpdates: { mrKey: string; round: Round }[] = [];
  const keepNudges: string[] = [];
  const keepRounds: string[] = [];

  for (const mr of snapshot.authored) {
    if (mr.draft) continue;
    for (const reviewer of mr.reviewers) {
      if (reviewer.username === snapshot.me.username) continue;
      const key = reviewerKey(mr.key, reviewer.username);
      keepNudges.push(key);
      if (!live || reviewer.state !== UNREVIEWED) continue;
      const record = state.nudges.get(key);
      const sent = record?.sentCount ?? 0;
      if (sent >= config.maxMessagesPerReviewer) continue;
      // Not UNREVIEWED before (or not there at all) and UNREVIEWED now: added, or asked again.
      const asking = previous.reviewerStates.get(key) !== UNREVIEWED;
      const reminderDue =
        record !== undefined &&
        sent === 1 &&
        !state.undelivered.has(key) &&
        previous.reviewerStates.get(key) === UNREVIEWED &&
        now - record.lastSentAt >= config.reminderAfterMs;
      if (!asking && !reminderDue) continue;
      // A Reviewer who reviewed an older head is asked by the Re-review Nudge, not twice.
      if (asking && rereview.awaiting.has(key)) continue;
      const slot = sent + 1;
      intents.push({
        dedupeKey: `nudge:${key}:${slot}`,
        kind: asking ? "nudge" : "reminder",
        variant: asking ? "nudge" : "reminder",
        mr: intentMr(mr),
        recipient: { username: reviewer.username, name: reviewer.name },
      });
      nudgeUpdates.push({ key, record: { sentCount: slot, lastSentAt: now } });
    }
  }

  for (const mr of snapshot.reviewRequested) {
    if (mr.draft) continue;
    keepRounds.push(mr.key);
    const myState = myReviewState(snapshot, mr);
    const myNotes = mr.notes.filter(
      (note) => !note.system && note.author.username === snapshot.me.username,
    ).length;
    const existing = state.rounds.get(mr.key);
    if (existing === undefined) {
      // First sighting: while seeding, what exists counts as announced; afterwards an MR starts
      // as "nothing announced", so a review given before the agent saw it is still announced.
      const seeded = state.baselineDone
        ? { state: UNREVIEWED, notes: 0 }
        : { state: myState, notes: myNotes };
      roundUpdates.push({
        mrKey: mr.key,
        round: {
          myState,
          myNotes,
          changedAt: now,
          noticedState: seeded.state,
          noticedNotes: seeded.notes,
          // An Agent Review posted before the round started is history, never announced.
          announcedReview: state.postedReviews.get(mr.key)?.id ?? null,
        },
      });
      continue;
    }
    let round = existing;
    if (myState !== existing.myState || myNotes !== existing.myNotes) {
      round = { ...existing, myState, myNotes, changedAt: now };
      if (myState === UNREVIEWED && existing.myState !== UNREVIEWED) {
        // A new Review Request after an earlier review: do not announce the old comments again.
        round = { ...round, noticedState: UNREVIEWED, noticedNotes: myNotes };
      }
    }
    // An Agent Review is announced with its findings once its comments show (or, should they
    // never be counted, after the debounce), and that announces those comments too. A re-review
    // the agent approved after says so, and that announces the approval too.
    const posted = state.postedReviews.get(mr.key);
    if (
      live &&
      posted !== undefined &&
      posted.id > (round.announcedReview ?? 0) &&
      (round.myNotes > round.noticedNotes || now - posted.postedAt >= config.noticeDebounceMs)
    ) {
      intents.push({
        dedupeKey: `findings:${posted.id}`,
        kind: "notice",
        variant: posted.approved
          ? "notice.reapproved"
          : posted.rereview
            ? "notice.refindings"
            : "notice.findings",
        mr: intentMr(mr),
        recipient: mr.author,
        findings: describeFindings(countFindings(posted.body), posted.rereview),
      });
      round = {
        ...round,
        noticedNotes: round.myNotes,
        announcedReview: posted.id,
        ...(posted.approved ? { noticedState: APPROVED } : {}),
      };
    }
    const variant = noticeVariant(round);
    if (live && variant !== undefined && now - round.changedAt >= config.noticeDebounceMs) {
      intents.push({
        dedupeKey: `notice:${mr.key}:${myState}:${myNotes}`,
        kind: "notice",
        variant,
        mr: intentMr(mr),
        recipient: mr.author,
      });
      round = { ...round, noticedState: myState, noticedNotes: myNotes };
    }
    if (round !== existing) roundUpdates.push({ mrKey: mr.key, round });
  }

  return {
    intents: [...intents, ...rereview.intents],
    nudgeUpdates,
    roundUpdates,
    keepNudges,
    keepRounds,
    rereviewMrs: rereview.mrs,
    rereviewReviewers: rereview.reviewers,
    baselineDone: true,
  };
}
