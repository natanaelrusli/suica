import { UNREVIEWED } from "../domain.ts";
import type { MergeRequest, Snapshot } from "../domain.ts";
import { myReviewState, reviewerKey } from "../events.ts";
import type { PreviousState } from "../events.ts";
import type { Intent, IntentMr, Round, TeamsPlan, TeamsState, TemplateName } from "./types.ts";

export interface PlanConfig {
  readonly maxMessagesPerReviewer: number;
  readonly reminderAfterMs: number;
  readonly noticeDebounceMs: number;
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

/**
 * Pure: decides which Teams messages are due and how the ledger changes. Nothing is queued until
 * both the Plan 1 baseline and the Teams baseline exist, so switching Teams on later never
 * announces history.
 */
export function planTeams(input: PlanInput): TeamsPlan {
  const { snapshot, previous, state, now, config } = input;
  const live = previous.baselineDone && state.baselineDone;
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

  return { intents, nudgeUpdates, roundUpdates, keepNudges, keepRounds, baselineDone: true };
}
