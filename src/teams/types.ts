import type { Person, ReviewState } from "../domain.ts";

export const TEMPLATE_NAMES = [
  "nudge",
  "reminder",
  "notice.approved",
  "notice.changes",
  "notice.comments",
] as const;
export type TemplateName = (typeof TEMPLATE_NAMES)[number];

export const OUTBOX_KINDS = ["nudge", "reminder", "notice"] as const;
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
}

export interface TeamsPlan {
  readonly intents: readonly Intent[];
  readonly nudgeUpdates: readonly { readonly key: string; readonly record: NudgeRecord }[];
  readonly roundUpdates: readonly { readonly mrKey: string; readonly round: Round }[];
  /** Ledger rows not listed here are deleted (the MR or Reviewer is gone). */
  readonly keepNudges: readonly string[];
  readonly keepRounds: readonly string[];
  readonly baselineDone: boolean;
}

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
  readonly status: OutboxStatus;
  readonly detail: string;
  /** Rendered text, once the row left `queued`. */
  readonly text: string | null;
  readonly createdAt: number;
  readonly updatedAt: number;
}
