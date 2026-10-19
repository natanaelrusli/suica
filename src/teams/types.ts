import type { Person, ReviewState } from "../domain.ts";

export const TEMPLATE_NAMES = [
  "nudge",
  "reminder",
  "notice.approved",
  "notice.changes",
  "notice.comments",
  "notice.findings",
  "notice.refindings",
  "rereview",
] as const;
export type TemplateName = (typeof TEMPLATE_NAMES)[number];

export const OUTBOX_KINDS = ["nudge", "reminder", "notice", "rereview"] as const;
export type OutboxKind = (typeof OUTBOX_KINDS)[number];

export const OUTBOX_STATUSES = [
  "queued",
  "pending",
  "sending",
  "sent",
  "skipped",
  "failed",
  "unresolved",
  "dry-run",
] as const;
export type OutboxStatus = (typeof OUTBOX_STATUSES)[number];

/** Rows that need the Owner's attention; `suica pending` lists these by default. */
export const ATTENTION_STATUSES: readonly OutboxStatus[] = [
  "pending",
  "unresolved",
  "failed",
  "sending",
];

export function isTemplateName(value: string): value is TemplateName {
  return (TEMPLATE_NAMES as readonly string[]).includes(value);
}
export function isOutboxKind(value: string): value is OutboxKind {
  return (OUTBOX_KINDS as readonly string[]).includes(value);
}
export function isOutboxStatus(value: string): value is OutboxStatus {
  return (OUTBOX_STATUSES as readonly string[]).includes(value);
}

export interface IntentMr {
  readonly key: string;
  readonly iid: number;
  readonly projectPath: string;
  readonly title: string;
  readonly url: string;
}

/** A message the planner wants to send; stored idempotently under `dedupeKey`. */
export interface Intent {
  readonly dedupeKey: string;
  readonly kind: OutboxKind;
  readonly variant: TemplateName;
  readonly mr: IntentMr;
  readonly recipient: Person;
  /** The `review.findings` value of a `notice.findings` or `notice.refindings` message. */
  readonly findings?: string;
}

export interface NudgeRecord {
  readonly sentCount: number;
  readonly lastSentAt: number;
}

/** The Owner's review activity on one MR where the Owner is a Reviewer. */
export interface Round {
  readonly myState: ReviewState;
  readonly myNotes: number;
  readonly changedAt: number;
  readonly noticedState: ReviewState;
  readonly noticedNotes: number;
  /**
   * The latest Agent Review of the MR whose findings were announced, or that was already posted
   * when the round started; null when there was none.
   */
  readonly announcedReview: number | null;
}

/** The latest posted Agent Review of an MR, for the Review Notice that reports its findings. */
export interface PostedReview {
  readonly id: number;
  readonly postedAt: number;
  readonly body: string;
  /** True when it followed an earlier posted review of the same MR. */
  readonly rereview: boolean;
}

/** What the ledger knows about one of the Owner's MRs, drafts included, for Re-review Nudges. */
export interface RereviewMr {
  /** The head commit at the latest poll. */
  readonly head: string;
  /** When the head last changed, or the MR was last a draft or became ready. */
  readonly changedAt: number;
}

/** What the ledger knows about one Reviewer of such an MR. */
export interface RereviewReviewer {
  /** The head commit at their latest review activity; null until they have reviewed. */
  readonly reviewedHead: string | null;
  /** The state seen at the latest poll, to tell a new review from a reset. */
  readonly state: ReviewState;
  /** Their non-system notes seen at the latest poll. */
  readonly notes: number;
  /** A Re-review Nudge was queued since their latest review activity. */
  readonly nudged: boolean;
}

export interface TeamsState {
  /** False until the first plan has been applied: history is recorded, never announced. */
  readonly baselineDone: boolean;
  /**
   * Key is `reviewerKey(mrKey, username)`. `lastSentAt` is the time the latest message was
   * delivered; for a message that was only queued it is the queue time.
   */
  readonly nudges: ReadonlyMap<string, NudgeRecord>;
  /** Reviewer keys whose latest message has not been delivered (queued, skipped, failed, …). */
  readonly undelivered: ReadonlySet<string>;
  /** Key is the MR key. */
  readonly rounds: ReadonlyMap<string, Round>;
  /** Key is the MR key. */
  readonly rereviewMrs: ReadonlyMap<string, RereviewMr>;
  /** Key is `reviewerKey(mrKey, username)`. */
  readonly rereviewReviewers: ReadonlyMap<string, RereviewReviewer>;
  /** Key is the MR key. */
  readonly postedReviews: ReadonlyMap<string, PostedReview>;
}

export interface TeamsPlan {
  readonly intents: readonly Intent[];
  readonly nudgeUpdates: readonly { readonly key: string; readonly record: NudgeRecord }[];
  readonly roundUpdates: readonly { readonly mrKey: string; readonly round: Round }[];
  /** Ledger rows not listed here are deleted (the MR or Reviewer is gone). */
  readonly keepNudges: readonly string[];
  readonly keepRounds: readonly string[];
  /** The Re-review ledger as it stands after this poll: rows not listed here are deleted. */
  readonly rereviewMrs: ReadonlyMap<string, RereviewMr>;
  readonly rereviewReviewers: ReadonlyMap<string, RereviewReviewer>;
  readonly baselineDone: boolean;
}

/** An outbox row that moved to `pending` in one dispatch: all the app notification needs. */
export type HeldMessage = Pick<OutboxRow, "id" | "kind" | "mrKey" | "mrTitle" | "recipientName">;

export interface OutboxRow {
  readonly id: number;
  readonly dedupeKey: string;
  readonly kind: OutboxKind;
  readonly variant: TemplateName;
  readonly mrKey: string;
  readonly mrIid: number;
  readonly mrProject: string;
  readonly mrTitle: string;
  readonly mrUrl: string;
  /** GitLab username of the person who receives the chat. */
  readonly recipient: string;
  readonly recipientName: string;
  /** The `review.findings` value; null for every message but `notice.findings` and `notice.refindings`. */
  readonly findings: string | null;
  readonly status: OutboxStatus;
  readonly detail: string;
  /** Rendered text, once the row left `queued`. */
  readonly text: string | null;
  /** True once the Owner approved sending it; null for rows older than schema 4. */
  readonly approved: boolean | null;
  readonly createdAt: number;
  readonly updatedAt: number;
}
