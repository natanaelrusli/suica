import { UNREVIEWED } from "./domain.ts";
import type { MergeRequest, Person, ReviewState, Snapshot } from "./domain.ts";

/** Everything the diff needs to know about the previous poll. */
export interface PreviousState {
  readonly baselineDone: boolean;
  /** Keys of the Owner's non-draft MRs seen in the previous poll. */
  readonly trackedAuthored: ReadonlySet<string>;
  /** MR key -> the Owner's own review state, for non-draft MRs where the Owner is a Reviewer. */
  readonly myReviewStates: ReadonlyMap<string, ReviewState>;
  /** `reviewerKey(mrKey, username)` -> state, for the Owner's MRs. */
  readonly reviewerStates: ReadonlyMap<string, ReviewState>;
  readonly seenNotes: ReadonlySet<string>;
}

export type ActivityEvent =
  | { readonly kind: "review-requested"; readonly mr: MergeRequest }
  | {
      readonly kind: "reviewer-state";
      readonly mr: MergeRequest;
      readonly reviewer: Person;
      readonly to: ReviewState;
    }
  | {
      readonly kind: "comment";
      readonly mr: MergeRequest;
      readonly noteId: string;
      readonly author: Person;
    };

export interface DetectOptions {
  readonly ignoreAuthors: ReadonlySet<string>;
}

export function reviewerKey(mrKey: string, username: string): string {
  return `${mrKey}|${username}`;
}

export function myReviewState(snapshot: Snapshot, mr: MergeRequest): ReviewState {
  return mr.reviewers.find((r) => r.username === snapshot.me.username)?.state ?? UNREVIEWED;
}

export function countPendingReviews(snapshot: Snapshot): number {
  return snapshot.reviewRequested.filter(
    (mr) => !mr.draft && myReviewState(snapshot, mr) === UNREVIEWED,
  ).length;
}

function reviewRequestEvents(snapshot: Snapshot, previous: PreviousState): ActivityEvent[] {
  const events: ActivityEvent[] = [];
  for (const mr of snapshot.reviewRequested) {
    if (mr.draft) continue;
    const isWaiting = myReviewState(snapshot, mr) === UNREVIEWED;
    if (isWaiting && previous.myReviewStates.get(mr.key) !== UNREVIEWED) {
      events.push({ kind: "review-requested", mr });
    }
  }
  return events;
}

function authoredEvents(
  snapshot: Snapshot,
  previous: PreviousState,
  options: DetectOptions,
): ActivityEvent[] {
  const events: ActivityEvent[] = [];
  for (const mr of snapshot.authored) {
    // A draft is ignored; an MR seen for the first time is only recorded, so its history never alerts.
    if (mr.draft || !previous.trackedAuthored.has(mr.key)) continue;
    for (const reviewer of mr.reviewers) {
      if (reviewer.username === snapshot.me.username) continue;
      // A Reviewer added since the last poll starts out UNREVIEWED, so a review given between two
      // polls still shows up as a change.
      const before =
        previous.reviewerStates.get(reviewerKey(mr.key, reviewer.username)) ?? UNREVIEWED;
      if (before !== reviewer.state && reviewer.state !== UNREVIEWED) {
        events.push({
          kind: "reviewer-state",
          mr,
          reviewer: { username: reviewer.username, name: reviewer.name },
          to: reviewer.state,
        });
      }
    }
    for (const note of mr.notes) {
      const ignored =
        note.system ||
        note.author.username === snapshot.me.username ||
        options.ignoreAuthors.has(note.author.username) ||
        previous.seenNotes.has(note.id);
      if (!ignored) events.push({ kind: "comment", mr, noteId: note.id, author: note.author });
    }
  }
  return events;
}

export function detectEvents(
  snapshot: Snapshot,
  previous: PreviousState,
  options: DetectOptions,
): ActivityEvent[] {
  if (!previous.baselineDone) return [];
  return [
    ...reviewRequestEvents(snapshot, previous),
    ...authoredEvents(snapshot, previous, options),
  ];
}
