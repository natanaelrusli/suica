import { chmodSync, existsSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { approvalVerdictSchema } from "./approval-judge.ts";
import type { ApprovalVerdict } from "./approval-judge.ts";
import type { Person, Snapshot } from "./domain.ts";
import { createIdeaStore } from "./idea-store.ts";
import type { IdeaStore } from "./idea-store.ts";
import { createFixStore } from "./fix-store.ts";
import type { FixStore } from "./fix-store.ts";
import { createLessonStore } from "./lesson-store.ts";
import type { LessonStore } from "./lesson-store.ts";
import { integer, nullableText, parseActivity, text } from "./sql-row.ts";
import type { ActivityLine, Row } from "./sql-row.ts";
import { myReviewState, reviewerKey } from "./events.ts";
import type { PreviousState } from "./events.ts";
import { isOutboxKind, isOutboxStatus, isTemplateName } from "./teams/types.ts";
import type {
  Intent,
  NudgeRecord,
  OutboxKind,
  OutboxRow,
  OutboxStatus,
  PostedReview,
  RereviewMr,
  RereviewReviewer,
  Round,
  TeamsPlan,
  TeamsState,
} from "./teams/types.ts";

export type HistoryKind = "review-requested" | "owner-reviewed" | "reviewer-reviewed" | "activity";

export interface HistoryEvent {
  readonly kind: HistoryKind;
  readonly mrKey: string;
  /**
   * The Reviewer for "reviewer-reviewed", the MR's author for "owner-reviewed", else empty.
   * "owner-reviewed" rows from before schema 13 are empty too.
   */
  readonly username: string;
  readonly at: number;
}

/** The first time a Reviewer approved one of the Owner's MRs, as a poll saw it. */
export interface FirstApproval {
  readonly mrKey: string;
  readonly title: string;
  readonly url: string;
  /** When the MR was opened, per GitLab. */
  readonly openedAt: number;
  /** The poll that first saw an approval, so up to one poll interval late. */
  readonly approvedAt: number;
  readonly approver: Person;
}

export interface PollLogEntry {
  readonly at: number;
  readonly status: "ok" | "failed";
  readonly failure: string | null;
  readonly durationMs: number;
}

/** Both lists are ordered by `at`. */
export interface HistoryRows {
  readonly polls: readonly PollLogEntry[];
  readonly events: readonly HistoryEvent[];
}

const HISTORY_KINDS: readonly string[] = [
  "review-requested",
  "owner-reviewed",
  "reviewer-reviewed",
  "activity",
];

/** What a language model run was for. Stored as text, so a later purpose needs no migration. */
export type TokenPurpose = "review" | "approve" | "fix" | "reply" | "lessons" | "other";

/** One language model run, as the model reported it. */
export interface TokenUsageEntry {
  readonly at: number;
  readonly purpose: TokenPurpose;
  readonly inputTokens: number;
  readonly outputTokens: number;
  readonly cacheReadTokens: number;
  readonly cacheCreationTokens: number;
}

/** Read back from the database: a purpose written by a newer build stays as written. */
export type StoredTokenUsage = Omit<TokenUsageEntry, "purpose"> & { readonly purpose: string };

export const AGENT_REVIEW_STATUSES = [
  "queued",
  "running",
  "ready",
  "posting",
  "posted",
  "discarded",
  "failed",
  "skipped",
  "cancelled",
] as const;
export type AgentReviewStatus = (typeof AGENT_REVIEW_STATUSES)[number];
export type AgentReviewTrigger = "auto" | "manual";

/** One Agent Review of one MR, from queued to posted or dropped. */
export interface AgentReviewRow {
  readonly id: number;
  readonly mrKey: string;
  readonly trigger: AgentReviewTrigger;
  readonly status: AgentReviewStatus;
  /** Null until known (a review queued by key alone gets it when the run reads the MR). */
  readonly mrTitle: string | null;
  /** The model that wrote it, as the CLI reported it; null until it ran or when not reported. */
  readonly model: string | null;
  /**
   * The skill it follows: the Owner's choice while queued, the one used once it started; null for
   * the default (`review.skill` when it runs) and on rows from before schema 18.
   */
  readonly skill: string | null;
  /** The model the Owner chose for this review; null for `review.model`. */
  readonly modelChoice: string | null;
  /** When the run started; null while queued. */
  readonly startedAt: number | null;
  /** The CLI that ran it; null until it starts. */
  readonly cli: string | null;
  /** The reviewed commit; null until the checkout. */
  readonly headSha: string | null;
  /** The commit of the posted review this one re-reviews; null for a first review. */
  readonly previousSha: string | null;
  /** SHA-256 of the MR description the review read; null until the run, and on older rows. */
  readonly descriptionSha: string | null;
  /** True when the agent approved the MR after posting this review. */
  readonly approved: boolean;
  /** The approval judge's verdict (`review.approveBy: agent`); null when the parser decides. */
  readonly approval: ApprovalVerdict | null;
  /** The review as the model wrote it, before it is sanitised for GitLab. */
  readonly body: string | null;
  /** Why it failed or was skipped, or a note about posting. */
  readonly detail: string;
  /** What the run did, newest last: the last `ACTIVITY_LINES` lines, written while it runs. */
  readonly activity: readonly ActivityLine[];
  readonly createdAt: number;
  readonly updatedAt: number;
}

export interface AgentReviewFields {
  readonly mrTitle?: string;
  readonly skill?: string;
  readonly model?: string;
  readonly startedAt?: number;
  readonly cli?: string;
  readonly headSha?: string;
  readonly previousSha?: string;
  readonly descriptionSha?: string;
  readonly approved?: boolean;
  readonly approval?: ApprovalVerdict;
  readonly body?: string;
  readonly detail?: string;
}

/** A skill or model the Owner picked for one review; left out means the config's. */
export interface ReviewChoice {
  readonly skill?: string;
  readonly model?: string;
}

/** What the poll loop knows about the head of one MR waiting for the Owner's review. */
export interface ReviewHead {
  /** The head commit at the latest poll. */
  readonly head: string;
  /** When the head last changed. */
  readonly changedAt: number;
  /** The head a re-review was last queued for; empty when none was. */
  readonly queuedHead: string;
}

function isAgentReviewStatus(value: string): value is AgentReviewStatus {
  return (AGENT_REVIEW_STATUSES as readonly string[]).includes(value);
}

function isHistoryKind(value: string): value is HistoryKind {
  return HISTORY_KINDS.includes(value);
}

export type { ActivityLine } from "./sql-row.ts";

export interface Store {
  /** Captured ideas, their notes, and durable local references. */
  readonly ideas: IdeaStore;
  /** Agent Fix runs and the threads they handled. */
  readonly fixes: FixStore;
  /** Review lessons distilled from findings and threads. */
  readonly lessons: LessonStore;
  load(): PreviousState;
  /**
   * Replaces stored poll state transactionally and marks the baseline as done.
   * The history and approval rows are committed with the snapshot.
   */
  commit(
    snapshot: Snapshot,
    history?: readonly HistoryEvent[],
    approvals?: readonly FirstApproval[],
  ): void;
  /** Inserts a poll and prunes the poll log, history and approval rows older than 90 days. */
  recordPoll(entry: PollLogEntry): void;
  /** The poll log and the history events at or after `since`, oldest first. */
  loadHistory(since: number): HistoryRows;
  /** The first approvals seen at or after `since`, oldest first. */
  loadApprovals(since: number): FirstApproval[];
  /** Username to display name, for everyone seen on an open MR or looked up, as last seen. */
  loadNames(): Map<string, string>;
  /** Usernames in the history without a display name, the most recently active first. */
  unnamedUsernames(limit: number): string[];
  saveNames(people: readonly Person[]): void;
  /** The latest poll (the last recorded of a tie), undefined when the log is empty. */
  lastPoll(): PollLogEntry | undefined;
  /** Also drops rows older than the retention. */
  recordTokenUsage(entry: TokenUsageEntry): void;
  /** Ordered by `at`. */
  loadTokenUsage(since: number): StoredTokenUsage[];
  isPaused(): boolean;
  setPaused(paused: boolean): void;
  loadTeams(): TeamsState;
  /**
   * Forgets the review rounds and the Teams baseline. Used while Teams is switched off: the ledger
   * is not maintained then, so the next start must re-seed it instead of announcing the gap.
   */
  resetTeamsBaseline(): void;
  /** Queues the plan's intents (idempotent per `dedupeKey`) and updates the ledger in one transaction. */
  applyTeamsPlan(plan: TeamsPlan, now: number): number;
  /** Stores a message the Owner sends by hand, approved and `pending` until it is delivered; its id. */
  insertManualOutbox(intent: Intent, text: string, now: number): number;
  /** Every row in `statuses`; with `hideCleared`, not the ones the Owner cleared. */
  listOutbox(statuses: readonly OutboxStatus[], options?: { hideCleared?: boolean }): OutboxRow[];
  /** Hides one finished or stuck `sending` row from the lists; false when it is still open or already cleared. */
  clearOutbox(id: number, now: number): boolean;
  /** Hides every sent, skipped or dry-run row of these kinds; how many it cleared. */
  clearRecentOutbox(kinds: readonly OutboxKind[], now: number): number;
  getOutbox(id: number): OutboxRow | undefined;
  /** Compare-and-set: true only for the one caller that found the row in `from`. */
  transitionOutbox(
    id: number,
    from: OutboxStatus,
    to: OutboxStatus,
    fields: { detail?: string; text?: string; approved?: true },
    now: number,
  ): boolean;
  /** Undefined when a review of this MR is already queued or running. */
  /**
   * Undefined when the MR already has an open review; with a `choice`, a queued one takes it and
   * keeps its place (the id is returned), while a running one is left alone.
   */
  queueAgentReview(
    mrKey: string,
    trigger: AgentReviewTrigger,
    now: number,
    mrTitle?: string,
    choice?: ReviewChoice,
  ): number | undefined;
  /** Every MR that has a review row of any status. */
  agentReviewedKeys(): Set<string>;
  /** The review running now, if any, and the queue in the order it runs. */
  /** Every running review, oldest first, and the queue in run order. */
  agentReviewActivity(): { running: AgentReviewRow[]; queued: AgentReviewRow[] };
  countAgentReviews(trigger: AgentReviewTrigger, since: number): number;
  /** Puts a running review back in the queue, as if it never started. */
  requeueAgentReview(id: number, now: number): boolean;
  /** Adds a line to a running review's activity; does nothing once it stopped running. */
  appendAgentReviewActivity(id: number, at: number, text: string): void;
  nextQueuedAgentReview(): AgentReviewRow | undefined;
  getAgentReview(id: number): AgentReviewRow | undefined;
  /** Every review after `id`, of any status, oldest first. */
  agentReviewsAfter(id: number): AgentReviewRow[];
  /** The newest review of each MR. */
  latestAgentReviews(): Map<string, AgentReviewRow>;
  /** The newest posted or discarded review of each MR: what a re-review follows. */
  rereviewBases(): Map<string, AgentReviewRow>;
  /** The same for one MR, among the rows before `beforeId`. */
  rereviewBase(mrKey: string, beforeId: number): AgentReviewRow | undefined;
  loadReviewHeads(): Map<string, ReviewHead>;
  /** Replaces every row in one transaction; only the poll loop writes them. */
  saveReviewHeads(heads: ReadonlyMap<string, ReviewHead>): void;
  /**
   * True when this commit already has a review that is ready, being posted or posted, of the same
   * description (a row without a description hash, from an older version, counts as the same) and
   * the same skill (a row without one counts as following `defaultSkill`).
   */
  hasAgentReviewAt(
    mrKey: string,
    headSha: string,
    descriptionSha: string,
    skill: string,
    defaultSkill: string,
  ): boolean;
  /** Only from one of `from`; false when the row was elsewhere, so two callers never both win. */
  transitionAgentReview(
    id: number,
    from: readonly AgentReviewStatus[],
    to: AgentReviewStatus,
    fields: AgentReviewFields,
    now: number,
  ): boolean;
  /** Runs cut off by a stop or crash; returns how many were marked failed. */
  failInterruptedAgentReviews(now: number): number;
  /**
   * Posts still `posting` 15 minutes after they started were cut off (a killed `suica review post`,
   * a crash, a reboot): back to ready with a note to check GitLab first. Returns how many.
   */
  recoverStalePostings(now: number): number;
  loadIdentity(username: string): string | undefined;
  saveIdentity(username: string, email: string, now: number): void;
  close(): void;
}

const SCHEMA_VERSION = 21;
/** Captured ideas and their independent notes and local/session references. */
const SCHEMA_V21 = `
CREATE TABLE IF NOT EXISTS idea (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  text TEXT NOT NULL,
  project_path TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  archived_at INTEGER,
  revision INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idea_archive_updated ON idea (archived_at, updated_at DESC, id DESC);
CREATE TABLE IF NOT EXISTS idea_note (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  idea_id INTEGER NOT NULL REFERENCES idea(id) ON DELETE CASCADE,
  text TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idea_note_idea ON idea_note (idea_id, created_at, id);
CREATE TABLE IF NOT EXISTS idea_plan (
  idea_id INTEGER NOT NULL REFERENCES idea(id) ON DELETE CASCADE,
  path TEXT NOT NULL,
  PRIMARY KEY (idea_id, path)
);
CREATE TABLE IF NOT EXISTS idea_session (
  idea_id INTEGER NOT NULL REFERENCES idea(id) ON DELETE CASCADE,
  agent TEXT NOT NULL,
  session_id TEXT NOT NULL,
  linked_at INTEGER NOT NULL,
  PRIMARY KEY (idea_id, agent, session_id)
);
`;
/** Lessons distilled from review findings and threads, the occurrences behind them, and links. */
const SCHEMA_V20 = `
CREATE TABLE IF NOT EXISTS lesson (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  scope TEXT NOT NULL,
  title TEXT NOT NULL,
  rule TEXT NOT NULL,
  topics TEXT NOT NULL DEFAULT '[]',
  globs TEXT NOT NULL DEFAULT '[]',
  archived INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS lesson_occurrence (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  source_key TEXT NOT NULL UNIQUE,
  source TEXT NOT NULL,
  mr_key TEXT NOT NULL,
  mr_title TEXT NOT NULL,
  mr_url TEXT NOT NULL,
  repo_path TEXT,
  path TEXT,
  line INTEGER,
  severity TEXT NOT NULL,
  title TEXT NOT NULL,
  text TEXT NOT NULL,
  outcome TEXT NOT NULL,
  lesson_id INTEGER,
  failures INTEGER NOT NULL DEFAULT 0,
  retry_at INTEGER,
  at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS lesson_occurrence_lesson ON lesson_occurrence (lesson_id);
CREATE INDEX IF NOT EXISTS lesson_occurrence_pending ON lesson_occurrence ((lesson_id IS NULL), retry_at);
CREATE TABLE IF NOT EXISTS lesson_link (
  a INTEGER NOT NULL,
  b INTEGER NOT NULL,
  PRIMARY KEY (a, b),
  CHECK (a < b)
);
`;
/** When the Owner cleared a finished message from the lists; the row stays for stats and dedupe. */
const SCHEMA_V19 = `ALTER TABLE outbox ADD COLUMN cleared_at INTEGER;`;
/** The skill and model the Owner picked for one review. */
const SCHEMA_V18_COLUMNS: readonly (readonly [string, string])[] = [
  ["skill", "TEXT"],
  ["model_choice", "TEXT"],
];
/** The Owner's watch choice per MR; no row follows `fix.watch`. */
const SCHEMA_V17 = `
CREATE TABLE IF NOT EXISTS mr_watch (mr_key TEXT PRIMARY KEY, watched INTEGER NOT NULL);
`;
/** The failed pipeline a Pipeline Fix works on, as JSON; and the head pipeline each of the Owner's MRs had at the last poll. */
const SCHEMA_V16 = `
CREATE TABLE IF NOT EXISTS pipeline_watch (
  mr_key TEXT PRIMARY KEY, pipeline_iid TEXT NOT NULL, status TEXT NOT NULL
);
`;
/** The approval judge's verdict on a review, as JSON. */
const SCHEMA_V15 = "ALTER TABLE agent_review ADD COLUMN approval TEXT";
/**
 * Agent Fix runs; the newest note of each thread a fix handled, so a thread stays quiet until
 * someone writes on it; and when the watcher last read each of the Owner's MRs.
 */
const SCHEMA_V14 = `
CREATE TABLE IF NOT EXISTS fix_run (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  mr_key TEXT NOT NULL, trigger TEXT NOT NULL, status TEXT NOT NULL, mr_title TEXT,
  threads TEXT NOT NULL, note TEXT NOT NULL DEFAULT '', base_sha TEXT,
  commit_message TEXT NOT NULL DEFAULT '', diff TEXT, pushed_sha TEXT, cli TEXT, model TEXT,
  detail TEXT NOT NULL DEFAULT '', activity TEXT NOT NULL DEFAULT '[]',
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, started_at INTEGER
);
CREATE INDEX IF NOT EXISTS fix_run_mr ON fix_run (mr_key, id);
CREATE TABLE IF NOT EXISTS fix_thread (
  mr_key TEXT NOT NULL, discussion_id TEXT NOT NULL, note_id TEXT NOT NULL,
  PRIMARY KEY (mr_key, discussion_id)
);
CREATE TABLE IF NOT EXISTS fix_watch (mr_key TEXT PRIMARY KEY, checked_at INTEGER NOT NULL);
`;
/**
 * When each of the Owner's MRs was first approved, and the display names of the people on open
 * MRs, so the history's usernames can be shown by name.
 */
const SCHEMA_V13 = `
CREATE TABLE IF NOT EXISTS first_approval (
  mr_key TEXT PRIMARY KEY, title TEXT NOT NULL, url TEXT NOT NULL, opened_at INTEGER NOT NULL,
  approved_at INTEGER NOT NULL, approver TEXT NOT NULL, approver_name TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS first_approval_at ON first_approval (approved_at);
CREATE TABLE IF NOT EXISTS person_name (username TEXT PRIMARY KEY, name TEXT NOT NULL);
`;
/** What a running review is doing, as a JSON array of `ActivityLine`. */
const SCHEMA_V12 = "ALTER TABLE agent_review ADD COLUMN activity TEXT NOT NULL DEFAULT '[]'";
const ACTIVITY_LINES = 50;
/** The description a review read, so a description-only change counts as an update, and whether the agent approved after it. */
const SCHEMA_V11_COLUMNS: readonly (readonly [string, string])[] = [
  ["description_sha", "TEXT"],
  ["approved", "INTEGER NOT NULL DEFAULT 0"],
];
/** The head of each MR waiting for the Owner's review, so a push is re-reviewed once it settles. */
const SCHEMA_V10 = `
CREATE TABLE IF NOT EXISTS review_head (
  mr_key TEXT PRIMARY KEY, head TEXT NOT NULL, changed_at INTEGER NOT NULL,
  queued_head TEXT NOT NULL
);
`;
/**
 * Columns for the Review Notice that reports an Agent Review's findings. Rounds that exist when
 * the database upgrades count the reviews already posted as announced, so none goes out late.
 */
const SCHEMA_V9_COLUMNS: readonly (readonly [string, string, string])[] = [
  ["review_round", "announced_review", "INTEGER"],
  ["outbox", "findings", "TEXT"],
];
const SCHEMA_V9_SEED = `
UPDATE review_round SET announced_review = (
  SELECT MAX(id) FROM agent_review
  WHERE agent_review.mr_key = review_round.mr_key AND status = 'posted'
);
`;
const SCHEMA_V8 = `
CREATE TABLE IF NOT EXISTS rereview_mr (
  mr_key TEXT PRIMARY KEY, head TEXT NOT NULL, changed_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS rereview_reviewer (
  key TEXT PRIMARY KEY, reviewed_head TEXT, state TEXT NOT NULL,
  notes INTEGER NOT NULL, nudged INTEGER NOT NULL
);
`;
/** Columns schema 6 lacked when it first shipped; schema 6 now creates the table with them. */
const SCHEMA_V7_COLUMNS: readonly (readonly [string, string])[] = [
  ["mr_title", "TEXT"],
  ["model", "TEXT"],
  ["started_at", "INTEGER"],
];
const SCHEMA_V6 = `
CREATE TABLE IF NOT EXISTS agent_review (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  mr_key TEXT NOT NULL, trigger TEXT NOT NULL, status TEXT NOT NULL, mr_title TEXT,
  cli TEXT, model TEXT, head_sha TEXT, body TEXT, detail TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, started_at INTEGER
);
CREATE INDEX IF NOT EXISTS agent_review_mr ON agent_review (mr_key, id);
`;
const SCHEMA_V5 = `
CREATE TABLE IF NOT EXISTS token_usage (
  at INTEGER NOT NULL, purpose TEXT NOT NULL,
  input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
  cache_read_tokens INTEGER NOT NULL, cache_creation_tokens INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS token_usage_at ON token_usage (at);
`;
/** Rows from before schema 4 keep NULL: nobody knows any more whether the Owner approved them. */
const SCHEMA_V4 = `ALTER TABLE outbox ADD COLUMN approved INTEGER;`;
const SCHEMA_V3 = `
CREATE TABLE IF NOT EXISTS poll_log (
  at INTEGER NOT NULL, status TEXT NOT NULL, failure TEXT, duration_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS poll_log_at ON poll_log (at);
CREATE TABLE IF NOT EXISTS history_event (
  kind TEXT NOT NULL, mr_key TEXT NOT NULL, username TEXT NOT NULL, at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS history_event_at ON history_event (at);
`;
const SCHEMA_V2 = `
CREATE TABLE IF NOT EXISTS outbox (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  dedupe_key TEXT NOT NULL UNIQUE,
  kind TEXT NOT NULL,
  variant TEXT NOT NULL,
  mr_key TEXT NOT NULL,
  mr_iid INTEGER NOT NULL,
  mr_project TEXT NOT NULL,
  mr_title TEXT NOT NULL,
  mr_url TEXT NOT NULL,
  recipient TEXT NOT NULL,
  recipient_name TEXT NOT NULL,
  status TEXT NOT NULL,
  detail TEXT NOT NULL DEFAULT '',
  text TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS outbox_status ON outbox (status);
CREATE TABLE IF NOT EXISTS nudge_state (
  key TEXT PRIMARY KEY,
  sent_count INTEGER NOT NULL,
  last_sent_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS review_round (
  mr_key TEXT PRIMARY KEY,
  my_state TEXT NOT NULL,
  my_notes INTEGER NOT NULL,
  changed_at INTEGER NOT NULL,
  noticed_state TEXT NOT NULL,
  noticed_notes INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS identity (
  username TEXT PRIMARY KEY,
  email TEXT NOT NULL,
  resolved_at INTEGER NOT NULL
);
`;
const META_TEAMS_BASELINE = "teams_baseline_done";
const FINISHED_STATUSES = ["sent", "skipped", "failed", "dry-run"] as const;
/**
 * Rows the Owner can clear: finished ones, and one stuck in `sending` (a send that crashed half way
 * never leaves it), once they checked Teams.
 */
const CLEARABLE_STATUSES = [...FINISHED_STATUSES, "sending"] as const;
/** Finished rows the app lists under Recent; a failed one stays under Needs attention. */
const RECENT_STATUSES = ["sent", "skipped", "dry-run"] as const;
const OUTBOX_RETENTION_MS = 90 * 24 * 3_600_000;
const HISTORY_RETENTION_MS = 90 * 24 * 3_600_000;
const TOKEN_USAGE_RETENTION_MS = 90 * 24 * 3_600_000;
const AGENT_REVIEW_RETENTION_MS = 90 * 24 * 3_600_000;
/** Longer than any live post: the app stops `suica review post` after 10 minutes. */
const POSTING_STALE_MS = 15 * 60_000;
const OPEN_REVIEW_STATUSES: readonly AgentReviewStatus[] = ["queued", "running"];
const DONE_REVIEW_STATUSES: readonly AgentReviewStatus[] = [
  "posted",
  "discarded",
  "failed",
  "skipped",
  "cancelled",
];
const SCHEMA = `
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS tracked_authored (mr_key TEXT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS my_review_state (mr_key TEXT PRIMARY KEY, state TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS reviewer_state (
  mr_key TEXT NOT NULL,
  username TEXT NOT NULL,
  state TEXT NOT NULL,
  PRIMARY KEY (mr_key, username)
);
CREATE TABLE IF NOT EXISTS seen_note (note_id TEXT PRIMARY KEY);
`;
const META_BASELINE = "baseline_done";
const META_PAUSED = "paused";
const DIRECTORY_MODE = 0o700;
const FILE_MODE = 0o600;
const BUSY_TIMEOUT_MS = 5000;

function toOutboxRow(row: Row): OutboxRow {
  const kind = text(row, "kind");
  const variant = text(row, "variant");
  const status = text(row, "status");
  if (!isOutboxKind(kind) || !isTemplateName(variant) || !isOutboxStatus(status)) {
    throw new Error("outbox row has an unknown kind, variant or status");
  }
  const stored = row["text"];
  const approved = row["approved"];
  return {
    id: integer(row, "id"),
    dedupeKey: text(row, "dedupe_key"),
    kind,
    variant,
    mrKey: text(row, "mr_key"),
    mrIid: integer(row, "mr_iid"),
    mrProject: text(row, "mr_project"),
    mrTitle: text(row, "mr_title"),
    mrUrl: text(row, "mr_url"),
    recipient: text(row, "recipient"),
    recipientName: text(row, "recipient_name"),
    findings: nullableText(row, "findings"),
    status,
    detail: text(row, "detail"),
    text: typeof stored === "string" ? stored : null,
    approved: typeof approved === "number" ? approved === 1 : null,
    createdAt: integer(row, "created_at"),
    updatedAt: integer(row, "updated_at"),
  };
}

function toHistoryEvent(row: Row): HistoryEvent {
  const kind = text(row, "kind");
  if (!isHistoryKind(kind)) throw new Error("history row has an unknown kind");
  return {
    kind,
    mrKey: text(row, "mr_key"),
    username: text(row, "username"),
    at: integer(row, "at"),
  };
}

function toFirstApproval(row: Row): FirstApproval {
  return {
    mrKey: text(row, "mr_key"),
    title: text(row, "title"),
    url: text(row, "url"),
    openedAt: integer(row, "opened_at"),
    approvedAt: integer(row, "approved_at"),
    approver: { username: text(row, "approver"), name: text(row, "approver_name") },
  };
}

function toPollLogEntry(row: Row): PollLogEntry {
  const status = text(row, "status");
  if (status !== "ok" && status !== "failed") throw new Error("poll log row has an unknown status");
  const failure = row["failure"];
  return {
    at: integer(row, "at"),
    status,
    failure: typeof failure === "string" ? failure : null,
    durationMs: integer(row, "duration_ms"),
  };
}

/** A verdict that does not parse reads as none, so the parser decides. */
function parseApproval(value: unknown): ApprovalVerdict | null {
  if (typeof value !== "string") return null;
  try {
    const parsed = approvalVerdictSchema.safeParse(JSON.parse(value));
    return parsed.success ? parsed.data : null;
  } catch {
    return null;
  }
}

function toAgentReview(row: Row): AgentReviewRow {
  const status = text(row, "status");
  const trigger = text(row, "trigger");
  if (!isAgentReviewStatus(status) || (trigger !== "auto" && trigger !== "manual")) {
    throw new Error("agent review row has an unknown status or trigger");
  }
  return {
    id: integer(row, "id"),
    mrKey: text(row, "mr_key"),
    trigger,
    status,
    mrTitle: nullableText(row, "mr_title"),
    model: nullableText(row, "model"),
    skill: nullableText(row, "skill"),
    modelChoice: nullableText(row, "model_choice"),
    startedAt: typeof row["started_at"] === "number" ? row["started_at"] : null,
    cli: nullableText(row, "cli"),
    headSha: nullableText(row, "head_sha"),
    previousSha: nullableText(row, "previous_sha"),
    descriptionSha: nullableText(row, "description_sha"),
    approved: row["approved"] === 1,
    approval: parseApproval(row["approval"]),
    body: nullableText(row, "body"),
    detail: text(row, "detail"),
    activity: parseActivity(row["activity"]),
    createdAt: integer(row, "created_at"),
    updatedAt: integer(row, "updated_at"),
  };
}

function toTokenUsage(row: Row): StoredTokenUsage {
  return {
    at: integer(row, "at"),
    purpose: text(row, "purpose"),
    inputTokens: integer(row, "input_tokens"),
    outputTokens: integer(row, "output_tokens"),
    cacheReadTokens: integer(row, "cache_read_tokens"),
    cacheCreationTokens: integer(row, "cache_creation_tokens"),
  };
}

function hasColumn(db: DatabaseSync, table: string, column: string): boolean {
  return db
    .prepare("SELECT 1 FROM pragma_table_info(?) WHERE name = ?")
    .all(table, column)
    .some(() => true);
}

function initSchema(db: DatabaseSync): void {
  const found = db.prepare("PRAGMA user_version").get()?.["user_version"];
  const version = typeof found === "number" ? found : 0;
  if (version > SCHEMA_VERSION) {
    throw new Error(`state database schema ${version} is newer than supported ${SCHEMA_VERSION}`);
  }
  if (version === 0) db.exec(SCHEMA);
  if (version < 2) db.exec(SCHEMA_V2);
  if (version < 3) db.exec(SCHEMA_V3);
  // A database set back by hand (see the README) may already have the column.
  if (version < 4 && !hasColumn(db, "outbox", "approved")) db.exec(SCHEMA_V4);
  if (version < 5) db.exec(SCHEMA_V5);
  if (version < 6) db.exec(SCHEMA_V6);
  if (version < 7) {
    for (const [column, type] of SCHEMA_V7_COLUMNS) {
      if (!hasColumn(db, "agent_review", column)) {
        db.exec(`ALTER TABLE agent_review ADD COLUMN ${column} ${type}`);
      }
    }
  }
  if (version < 8) db.exec(SCHEMA_V8);
  if (version < 9) {
    for (const [table, column, type] of SCHEMA_V9_COLUMNS) {
      if (!hasColumn(db, table, column))
        db.exec(`ALTER TABLE ${table} ADD COLUMN ${column} ${type}`);
    }
    db.exec(SCHEMA_V9_SEED);
  }
  if (version < 10) {
    if (!hasColumn(db, "agent_review", "previous_sha")) {
      db.exec("ALTER TABLE agent_review ADD COLUMN previous_sha TEXT");
    }
    db.exec(SCHEMA_V10);
  }
  if (version < 11) {
    for (const [column, type] of SCHEMA_V11_COLUMNS) {
      if (!hasColumn(db, "agent_review", column)) {
        db.exec(`ALTER TABLE agent_review ADD COLUMN ${column} ${type}`);
      }
    }
  }
  if (version < 12 && !hasColumn(db, "agent_review", "activity")) db.exec(SCHEMA_V12);
  if (version < 13) db.exec(SCHEMA_V13);
  if (version < 14) db.exec(SCHEMA_V14);
  if (version < 15 && !hasColumn(db, "agent_review", "approval")) db.exec(SCHEMA_V15);
  if (version < 16) {
    if (!hasColumn(db, "fix_run", "pipeline"))
      db.exec("ALTER TABLE fix_run ADD COLUMN pipeline TEXT");
    db.exec(SCHEMA_V16);
  }
  if (version < 17) db.exec(SCHEMA_V17);
  if (version < 18) {
    for (const [column, type] of SCHEMA_V18_COLUMNS) {
      if (!hasColumn(db, "agent_review", column)) {
        db.exec(`ALTER TABLE agent_review ADD COLUMN ${column} ${type}`);
      }
    }
  }
  if (version < 19 && !hasColumn(db, "outbox", "cleared_at")) db.exec(SCHEMA_V19);
  if (version < 20) db.exec(SCHEMA_V20);
  if (version < 21) db.exec(SCHEMA_V21);
  if (version !== SCHEMA_VERSION) db.exec(`PRAGMA user_version = ${SCHEMA_VERSION}`);
}

/** The database holds employee IDs: keep the folder and every SQLite file private to the owner. */
function restrictPermissions(path: string): void {
  if (path === ":memory:") return;
  chmodSync(dirname(path), DIRECTORY_MODE);
  for (const file of [path, `${path}-wal`, `${path}-shm`]) {
    if (existsSync(file)) chmodSync(file, FILE_MODE);
  }
}

export function openStore(path: string): Store {
  if (path !== ":memory:") mkdirSync(dirname(path), { recursive: true, mode: DIRECTORY_MODE });
  // The timeout is set before the first statement: switching a new file to WAL needs a lock that
  // another process creating the database at the same moment may hold.
  const db = new DatabaseSync(path, { timeout: BUSY_TIMEOUT_MS });
  try {
    db.exec("PRAGMA journal_mode = WAL;");
    initSchema(db);
    restrictPermissions(path);
  } catch (error) {
    db.close();
    throw error;
  }

  const rows = (sql: string): Row[] => db.prepare(sql).all();
  const metaValue = (key: string): string | undefined => {
    const row = db.prepare("SELECT value FROM meta WHERE key = ?").get(key);
    return row === undefined ? undefined : text(row, "value");
  };
  const setMeta = (key: string, value: string): void => {
    db.prepare(
      "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
    ).run(key, value);
  };

  return {
    fixes: createFixStore(db),
    ideas: createIdeaStore(db),
    lessons: createLessonStore(db),
    load() {
      return {
        baselineDone: metaValue(META_BASELINE) === "1",
        trackedAuthored: new Set(
          rows("SELECT mr_key FROM tracked_authored").map((row) => text(row, "mr_key")),
        ),
        myReviewStates: new Map(
          rows("SELECT mr_key, state FROM my_review_state").map(
            (row) => [text(row, "mr_key"), text(row, "state")] as const,
          ),
        ),
        reviewerStates: new Map(
          rows("SELECT mr_key, username, state FROM reviewer_state").map(
            (row) =>
              [
                reviewerKey(text(row, "mr_key"), text(row, "username")),
                text(row, "state"),
              ] as const,
          ),
        ),
        seenNotes: new Set(
          rows("SELECT note_id FROM seen_note").map((row) => text(row, "note_id")),
        ),
      };
    },

    commit(snapshot, history = [], approvals = []) {
      const insertTracked = db.prepare(
        "INSERT OR REPLACE INTO tracked_authored (mr_key) VALUES (?)",
      );
      const insertMine = db.prepare(
        "INSERT OR REPLACE INTO my_review_state (mr_key, state) VALUES (?, ?)",
      );
      const insertReviewer = db.prepare(
        "INSERT OR REPLACE INTO reviewer_state (mr_key, username, state) VALUES (?, ?, ?)",
      );
      const insertNote = db.prepare("INSERT OR REPLACE INTO seen_note (note_id) VALUES (?)");
      const insertEvent = db.prepare(
        "INSERT INTO history_event (kind, mr_key, username, at) VALUES (?, ?, ?, ?)",
      );
      // Only the first approval counts: a later one, or one after an unapproval, is ignored.
      const insertApproval = db.prepare(
        `INSERT OR IGNORE INTO first_approval
           (mr_key, title, url, opened_at, approved_at, approver, approver_name)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
      );
      // Kept across polls, so a name stays known after the MR closes; the table holds one row per colleague.
      const insertName = db.prepare(
        "INSERT OR REPLACE INTO person_name (username, name) VALUES (?, ?)",
      );
      db.exec("BEGIN IMMEDIATE");
      try {
        for (const mr of [...snapshot.reviewRequested, ...snapshot.authored]) {
          for (const person of [mr.author, ...mr.reviewers])
            insertName.run(person.username, person.name);
        }
        db.exec(
          "DELETE FROM tracked_authored; DELETE FROM my_review_state; DELETE FROM reviewer_state; DELETE FROM seen_note;",
        );
        for (const mr of snapshot.reviewRequested) {
          if (!mr.draft) insertMine.run(mr.key, myReviewState(snapshot, mr));
        }
        for (const mr of snapshot.authored) {
          if (mr.draft) continue;
          insertTracked.run(mr.key);
          for (const reviewer of mr.reviewers) {
            insertReviewer.run(mr.key, reviewer.username, reviewer.state);
          }
          for (const note of mr.notes) insertNote.run(note.id);
        }
        for (const item of history) {
          insertEvent.run(item.kind, item.mrKey, item.username, item.at);
        }
        for (const item of approvals) {
          insertApproval.run(
            item.mrKey,
            item.title,
            item.url,
            item.openedAt,
            item.approvedAt,
            item.approver.username,
            item.approver.name,
          );
        }
        setMeta(META_BASELINE, "1");
        db.exec("COMMIT");
      } catch (error) {
        db.exec("ROLLBACK");
        throw error;
      }
      // The -wal and -shm files only exist once something has been written.
      restrictPermissions(path);
    },

    recordPoll(entry) {
      const cutoff = entry.at - HISTORY_RETENTION_MS;
      db.exec("BEGIN IMMEDIATE");
      try {
        db.prepare(
          "INSERT INTO poll_log (at, status, failure, duration_ms) VALUES (?, ?, ?, ?)",
        ).run(entry.at, entry.status, entry.failure, entry.durationMs);
        db.prepare("DELETE FROM poll_log WHERE at < ?").run(cutoff);
        db.prepare("DELETE FROM history_event WHERE at < ?").run(cutoff);
        db.prepare("DELETE FROM first_approval WHERE approved_at < ?").run(cutoff);
        db.exec("COMMIT");
      } catch (error) {
        db.exec("ROLLBACK");
        throw error;
      }
      restrictPermissions(path);
    },

    loadHistory(since) {
      return {
        polls: db
          .prepare("SELECT * FROM poll_log WHERE at >= ? ORDER BY at, rowid")
          .all(since)
          .map(toPollLogEntry),
        events: db
          .prepare("SELECT * FROM history_event WHERE at >= ? ORDER BY at, rowid")
          .all(since)
          .map(toHistoryEvent),
      };
    },

    loadNames() {
      return new Map(
        db
          .prepare("SELECT username, name FROM person_name")
          .all()
          .map((row) => [text(row, "username"), text(row, "name")] as const),
      );
    },

    unnamedUsernames(limit) {
      return db
        .prepare(
          `SELECT username FROM history_event
           WHERE username != '' AND username NOT IN (SELECT username FROM person_name)
           GROUP BY username ORDER BY MAX(at) DESC LIMIT ?`,
        )
        .all(limit)
        .map((row) => text(row, "username"));
    },

    saveNames(people) {
      const insert = db.prepare(
        "INSERT OR REPLACE INTO person_name (username, name) VALUES (?, ?)",
      );
      for (const person of people) insert.run(person.username, person.name);
    },

    loadApprovals(since) {
      return db
        .prepare("SELECT * FROM first_approval WHERE approved_at >= ? ORDER BY approved_at, rowid")
        .all(since)
        .map(toFirstApproval);
    },

    lastPoll() {
      const row = db.prepare("SELECT * FROM poll_log ORDER BY at DESC, rowid DESC LIMIT 1").get();
      return row === undefined ? undefined : toPollLogEntry(row);
    },

    recordTokenUsage(entry) {
      db.exec("BEGIN IMMEDIATE");
      try {
        db.prepare(
          `INSERT INTO token_usage
             (at, purpose, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens)
           VALUES (?, ?, ?, ?, ?, ?)`,
        ).run(
          entry.at,
          entry.purpose,
          entry.inputTokens,
          entry.outputTokens,
          entry.cacheReadTokens,
          entry.cacheCreationTokens,
        );
        db.prepare("DELETE FROM token_usage WHERE at < ?").run(entry.at - TOKEN_USAGE_RETENTION_MS);
        db.exec("COMMIT");
      } catch (error) {
        db.exec("ROLLBACK");
        throw error;
      }
      restrictPermissions(path);
    },

    queueAgentReview(mrKey, trigger, now, mrTitle, choice) {
      const marks = (statuses: readonly string[]): string => statuses.map(() => "?").join(", ");
      db.exec("BEGIN IMMEDIATE");
      try {
        const open = db
          .prepare(
            `SELECT id, status FROM agent_review WHERE mr_key = ? AND status IN (${marks(OPEN_REVIEW_STATUSES)})`,
          )
          .get(mrKey, ...OPEN_REVIEW_STATUSES);
        let id: number | undefined;
        if (open === undefined) {
          const result = db
            .prepare(
              `INSERT INTO agent_review (mr_key, trigger, status, mr_title, skill, model_choice, created_at, updated_at)
               VALUES (?, ?, 'queued', ?, ?, ?, ?, ?)`,
            )
            .run(
              mrKey,
              trigger,
              mrTitle ?? null,
              choice?.skill ?? null,
              choice?.model ?? null,
              now,
              now,
            );
          id = Number(result.lastInsertRowid);
        } else if (choice !== undefined && open["status"] === "queued") {
          id = integer(open, "id");
          db.prepare(
            "UPDATE agent_review SET skill = ?, model_choice = ?, updated_at = ? WHERE id = ?",
          ).run(choice.skill ?? null, choice.model ?? null, now, id);
        }
        db.prepare(
          `DELETE FROM agent_review WHERE updated_at < ? AND status IN (${marks(DONE_REVIEW_STATUSES)})`,
        ).run(now - AGENT_REVIEW_RETENTION_MS, ...DONE_REVIEW_STATUSES);
        db.exec("COMMIT");
        restrictPermissions(path);
        return id;
      } catch (error) {
        db.exec("ROLLBACK");
        throw error;
      }
    },

    agentReviewedKeys() {
      return new Set(
        rows("SELECT DISTINCT mr_key FROM agent_review").map((row) => text(row, "mr_key")),
      );
    },

    agentReviewActivity() {
      return {
        running: rows("SELECT * FROM agent_review WHERE status = 'running' ORDER BY id").map(
          toAgentReview,
        ),
        queued: rows("SELECT * FROM agent_review WHERE status = 'queued' ORDER BY id").map(
          toAgentReview,
        ),
      };
    },

    requeueAgentReview(id, now) {
      return (
        db
          .prepare(
            "UPDATE agent_review SET status = 'queued', started_at = NULL, activity = '[]', updated_at = ? WHERE id = ? AND status = 'running'",
          )
          .run(now, id).changes > 0
      );
    },

    appendAgentReviewActivity(id, at, text) {
      const row = db
        .prepare("SELECT activity FROM agent_review WHERE id = ? AND status = 'running'")
        .get(id);
      if (row === undefined) return;
      const activity = [...parseActivity(row["activity"]), { at, text }].slice(-ACTIVITY_LINES);
      db.prepare("UPDATE agent_review SET activity = ? WHERE id = ? AND status = 'running'").run(
        JSON.stringify(activity),
        id,
      );
    },

    countAgentReviews(trigger, since) {
      const row = db
        .prepare(
          "SELECT COUNT(*) AS n FROM agent_review WHERE trigger = ? AND created_at >= ? AND status NOT IN ('skipped', 'cancelled')",
        )
        .get(trigger, since);
      return row === undefined ? 0 : integer(row, "n");
    },

    nextQueuedAgentReview() {
      const row = db
        .prepare("SELECT * FROM agent_review WHERE status = 'queued' ORDER BY id LIMIT 1")
        .get();
      return row === undefined ? undefined : toAgentReview(row);
    },

    getAgentReview(id) {
      const row = db.prepare("SELECT * FROM agent_review WHERE id = ?").get(id);
      return row === undefined ? undefined : toAgentReview(row);
    },

    agentReviewsAfter(id) {
      return db
        .prepare("SELECT * FROM agent_review WHERE id > ? ORDER BY id")
        .all(id)
        .map(toAgentReview);
    },

    latestAgentReviews() {
      const latest = new Map<string, AgentReviewRow>();
      for (const row of rows(
        "SELECT * FROM agent_review WHERE id IN (SELECT MAX(id) FROM agent_review GROUP BY mr_key)",
      )) {
        const review = toAgentReview(row);
        latest.set(review.mrKey, review);
      }
      return latest;
    },

    rereviewBases() {
      const bases = new Map<string, AgentReviewRow>();
      for (const row of rows(
        `SELECT * FROM agent_review WHERE id IN
           (SELECT MAX(id) FROM agent_review WHERE status IN ('posted', 'discarded') GROUP BY mr_key)`,
      )) {
        const review = toAgentReview(row);
        bases.set(review.mrKey, review);
      }
      return bases;
    },

    rereviewBase(mrKey, beforeId) {
      const row = db
        .prepare(
          "SELECT * FROM agent_review WHERE mr_key = ? AND id < ? AND status IN ('posted', 'discarded') ORDER BY id DESC LIMIT 1",
        )
        .get(mrKey, beforeId);
      return row === undefined ? undefined : toAgentReview(row);
    },

    loadReviewHeads() {
      const heads = new Map<string, ReviewHead>();
      for (const row of rows("SELECT * FROM review_head")) {
        heads.set(text(row, "mr_key"), {
          head: text(row, "head"),
          changedAt: integer(row, "changed_at"),
          queuedHead: text(row, "queued_head"),
        });
      }
      return heads;
    },

    saveReviewHeads(heads) {
      const insert = db.prepare(
        "INSERT INTO review_head (mr_key, head, changed_at, queued_head) VALUES (?, ?, ?, ?)",
      );
      db.exec("BEGIN IMMEDIATE");
      try {
        db.exec("DELETE FROM review_head");
        for (const [mrKey, value] of heads) {
          insert.run(mrKey, value.head, value.changedAt, value.queuedHead);
        }
        db.exec("COMMIT");
      } catch (error) {
        db.exec("ROLLBACK");
        throw error;
      }
      restrictPermissions(path);
    },

    hasAgentReviewAt(mrKey, headSha, descriptionSha, skill, defaultSkill) {
      return (
        db
          .prepare(
            `SELECT 1 FROM agent_review WHERE mr_key = ? AND head_sha = ?
               AND (description_sha IS NULL OR description_sha = ?) AND COALESCE(skill, ?) = ?
               AND status IN ('ready', 'posting', 'posted')`,
          )
          .get(mrKey, headSha, descriptionSha, defaultSkill, skill) !== undefined
      );
    },

    transitionAgentReview(id, from, to, fields, now) {
      const result = db
        .prepare(
          `UPDATE agent_review SET status = ?, skill = COALESCE(?, skill), cli = COALESCE(?, cli), head_sha = COALESCE(?, head_sha),
             previous_sha = COALESCE(?, previous_sha), description_sha = COALESCE(?, description_sha),
             approved = COALESCE(?, approved), approval = COALESCE(?, approval), body = COALESCE(?, body), detail = COALESCE(?, detail), mr_title = COALESCE(?, mr_title),
             model = COALESCE(?, model), started_at = COALESCE(?, started_at), updated_at = ?
           WHERE id = ? AND status IN (${from.map(() => "?").join(", ")})`,
        )
        .run(
          to,
          fields.skill ?? null,
          fields.cli ?? null,
          fields.headSha ?? null,
          fields.previousSha ?? null,
          fields.descriptionSha ?? null,
          fields.approved === undefined ? null : fields.approved ? 1 : 0,
          fields.approval === undefined ? null : JSON.stringify(fields.approval),
          fields.body ?? null,
          fields.detail ?? null,
          fields.mrTitle ?? null,
          fields.model ?? null,
          fields.startedAt ?? null,
          now,
          id,
          ...from,
        );
      restrictPermissions(path);
      return result.changes === 1;
    },

    failInterruptedAgentReviews(now) {
      const result = db
        .prepare(
          "UPDATE agent_review SET status = 'failed', detail = 'interrupted: the agent stopped during the run', updated_at = ? WHERE status = 'running'",
        )
        .run(now);
      return Number(result.changes);
    },

    recoverStalePostings(now) {
      // One guarded UPDATE: a post that finishes later finds the row no longer posting.
      const result = db
        .prepare(
          "UPDATE agent_review SET status = 'ready', detail = ?, updated_at = ? WHERE status = 'posting' AND updated_at < ?",
        )
        .run(
          "Posting was interrupted. Check the MR in GitLab before posting again: some comments may have arrived.",
          now,
          now - POSTING_STALE_MS,
        );
      return Number(result.changes);
    },

    loadTokenUsage(since) {
      return db
        .prepare("SELECT * FROM token_usage WHERE at >= ? ORDER BY at, rowid")
        .all(since)
        .map(toTokenUsage);
    },

    loadTeams() {
      const nudges = new Map<string, NudgeRecord>();
      const undelivered = new Set<string>();
      // The time of the latest message is when it was delivered, not when it was queued: a
      // reminder is due a day after the Reviewer could first have read the nudge.
      for (const row of rows(
        `SELECT n.key, n.sent_count, n.last_sent_at, o.status AS status, o.updated_at AS delivered_at
         FROM nudge_state n
         LEFT JOIN outbox o ON o.dedupe_key = 'nudge:' || n.key || ':' || n.sent_count`,
      )) {
        const key = text(row, "key");
        const status = row["status"];
        const delivered = status === "sent" || status === "dry-run";
        if (!delivered) undelivered.add(key);
        nudges.set(key, {
          sentCount: integer(row, "sent_count"),
          lastSentAt: delivered ? integer(row, "delivered_at") : integer(row, "last_sent_at"),
        });
      }
      const rounds = new Map<string, Round>();
      for (const row of rows("SELECT * FROM review_round")) {
        rounds.set(text(row, "mr_key"), {
          myState: text(row, "my_state"),
          myNotes: integer(row, "my_notes"),
          changedAt: integer(row, "changed_at"),
          noticedState: text(row, "noticed_state"),
          noticedNotes: integer(row, "noticed_notes"),
          announcedReview:
            typeof row["announced_review"] === "number" ? row["announced_review"] : null,
        });
      }
      const rereviewMrs = new Map<string, RereviewMr>();
      for (const row of rows("SELECT * FROM rereview_mr")) {
        rereviewMrs.set(text(row, "mr_key"), {
          head: text(row, "head"),
          changedAt: integer(row, "changed_at"),
        });
      }
      const rereviewReviewers = new Map<string, RereviewReviewer>();
      for (const row of rows("SELECT * FROM rereview_reviewer")) {
        rereviewReviewers.set(text(row, "key"), {
          reviewedHead: nullableText(row, "reviewed_head"),
          state: text(row, "state"),
          notes: integer(row, "notes"),
          nudged: integer(row, "nudged") === 1,
        });
      }
      const postedReviews = new Map<string, PostedReview>();
      for (const row of rows(
        `SELECT id, mr_key, updated_at, body, previous_sha, approved FROM agent_review WHERE id IN
           (SELECT MAX(id) FROM agent_review WHERE status = 'posted' AND body IS NOT NULL GROUP BY mr_key)`,
      )) {
        postedReviews.set(text(row, "mr_key"), {
          id: integer(row, "id"),
          postedAt: integer(row, "updated_at"),
          body: text(row, "body"),
          rereview: row["previous_sha"] !== null,
          approved: row["approved"] === 1,
        });
      }
      return {
        baselineDone: metaValue(META_TEAMS_BASELINE) === "1",
        nudges,
        rounds,
        undelivered,
        rereviewMrs,
        rereviewReviewers,
        postedReviews,
      };
    },

    resetTeamsBaseline() {
      db.exec("BEGIN IMMEDIATE");
      try {
        db.exec(
          "DELETE FROM review_round; DELETE FROM rereview_mr; DELETE FROM rereview_reviewer;",
        );
        db.prepare("DELETE FROM meta WHERE key = ?").run(META_TEAMS_BASELINE);
        db.exec("COMMIT");
      } catch (error) {
        db.exec("ROLLBACK");
        throw error;
      }
    },

    applyTeamsPlan(plan, now) {
      const insertOutbox = db.prepare(
        `INSERT OR IGNORE INTO outbox
           (dedupe_key, kind, variant, mr_key, mr_iid, mr_project, mr_title, mr_url,
            recipient, recipient_name, findings, status, detail, text, approved, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'queued', '', NULL, 0, ?, ?)`,
      );
      const upsertNudge = db.prepare(
        `INSERT INTO nudge_state (key, sent_count, last_sent_at) VALUES (?, ?, ?)
         ON CONFLICT(key) DO UPDATE SET
           sent_count = excluded.sent_count, last_sent_at = excluded.last_sent_at`,
      );
      const upsertRound = db.prepare(
        `INSERT INTO review_round
           (mr_key, my_state, my_notes, changed_at, noticed_state, noticed_notes, announced_review)
         VALUES (?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(mr_key) DO UPDATE SET
           my_state = excluded.my_state, my_notes = excluded.my_notes,
           changed_at = excluded.changed_at, noticed_state = excluded.noticed_state,
           noticed_notes = excluded.noticed_notes, announced_review = excluded.announced_review`,
      );
      db.exec("BEGIN IMMEDIATE");
      try {
        let created = 0;
        for (const item of plan.intents) {
          const result = insertOutbox.run(
            item.dedupeKey,
            item.kind,
            item.variant,
            item.mr.key,
            item.mr.iid,
            item.mr.projectPath,
            item.mr.title,
            item.mr.url,
            item.recipient.username,
            item.recipient.name,
            item.findings ?? null,
            now,
            now,
          );
          created += Number(result.changes);
        }
        for (const { key, record } of plan.nudgeUpdates) {
          upsertNudge.run(key, record.sentCount, record.lastSentAt);
        }
        for (const { mrKey, round } of plan.roundUpdates) {
          upsertRound.run(
            mrKey,
            round.myState,
            round.myNotes,
            round.changedAt,
            round.noticedState,
            round.noticedNotes,
            round.announcedReview,
          );
        }
        const keepNudges = new Set(plan.keepNudges);
        for (const row of rows("SELECT key FROM nudge_state")) {
          const key = text(row, "key");
          if (!keepNudges.has(key)) db.prepare("DELETE FROM nudge_state WHERE key = ?").run(key);
        }
        const keepRounds = new Set(plan.keepRounds);
        for (const row of rows("SELECT mr_key FROM review_round")) {
          const key = text(row, "mr_key");
          if (!keepRounds.has(key)) {
            db.prepare("DELETE FROM review_round WHERE mr_key = ?").run(key);
          }
        }
        db.prepare(
          `DELETE FROM outbox WHERE updated_at < ?
             AND (status IN (${FINISHED_STATUSES.map(() => "?").join(", ")}) OR cleared_at IS NOT NULL)`,
        ).run(now - OUTBOX_RETENTION_MS, ...FINISHED_STATUSES);
        // The ledger is small and each poll rebuilds it whole, so it is replaced, not patched.
        db.exec("DELETE FROM rereview_mr; DELETE FROM rereview_reviewer;");
        const insertRereviewMr = db.prepare(
          "INSERT INTO rereview_mr (mr_key, head, changed_at) VALUES (?, ?, ?)",
        );
        for (const [mrKey, record] of plan.rereviewMrs) {
          insertRereviewMr.run(mrKey, record.head, record.changedAt);
        }
        const insertRereviewReviewer = db.prepare(
          `INSERT INTO rereview_reviewer (key, reviewed_head, state, notes, nudged)
           VALUES (?, ?, ?, ?, ?)`,
        );
        for (const [key, record] of plan.rereviewReviewers) {
          insertRereviewReviewer.run(
            key,
            record.reviewedHead,
            record.state,
            record.notes,
            record.nudged ? 1 : 0,
          );
        }
        if (plan.baselineDone) setMeta(META_TEAMS_BASELINE, "1");
        db.exec("COMMIT");
        return created;
      } catch (error) {
        db.exec("ROLLBACK");
        throw error;
      }
    },

    insertManualOutbox(intent, text, now) {
      const result = db
        .prepare(
          `INSERT INTO outbox
             (dedupe_key, kind, variant, mr_key, mr_iid, mr_project, mr_title, mr_url,
              recipient, recipient_name, findings, status, detail, text, approved, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, 'pending', '', ?, 1, ?, ?)`,
        )
        .run(
          intent.dedupeKey,
          intent.kind,
          intent.variant,
          intent.mr.key,
          intent.mr.iid,
          intent.mr.projectPath,
          intent.mr.title,
          intent.mr.url,
          intent.recipient.username,
          intent.recipient.name,
          text,
          now,
          now,
        );
      return Number(result.lastInsertRowid);
    },

    listOutbox(statuses, options) {
      if (statuses.length === 0) return [];
      const marks = statuses.map(() => "?").join(", ");
      const hidden = options?.hideCleared === true ? " AND cleared_at IS NULL" : "";
      return db
        .prepare(`SELECT * FROM outbox WHERE status IN (${marks})${hidden} ORDER BY id`)
        .all(...statuses)
        .map(toOutboxRow);
    },

    clearOutbox(id, now) {
      const result = db
        .prepare(
          `UPDATE outbox SET cleared_at = ? WHERE id = ? AND cleared_at IS NULL
             AND status IN (${CLEARABLE_STATUSES.map(() => "?").join(", ")})`,
        )
        .run(now, id, ...CLEARABLE_STATUSES);
      return Number(result.changes) === 1;
    },

    clearRecentOutbox(kinds, now) {
      if (kinds.length === 0) return 0;
      const result = db
        .prepare(
          `UPDATE outbox SET cleared_at = ? WHERE cleared_at IS NULL
             AND status IN (${RECENT_STATUSES.map(() => "?").join(", ")})
             AND kind IN (${kinds.map(() => "?").join(", ")})`,
        )
        .run(now, ...RECENT_STATUSES, ...kinds);
      return Number(result.changes);
    },

    getOutbox(id) {
      const row = db.prepare("SELECT * FROM outbox WHERE id = ?").get(id);
      return row === undefined ? undefined : toOutboxRow(row);
    },

    transitionOutbox(id, from, to, fields, now) {
      const result = db
        .prepare(
          `UPDATE outbox SET status = ?, detail = COALESCE(?, detail), text = COALESCE(?, text),
             approved = COALESCE(?, approved), updated_at = ? WHERE id = ? AND status = ?`,
        )
        .run(
          to,
          fields.detail ?? null,
          fields.text ?? null,
          fields.approved === true ? 1 : null,
          now,
          id,
          from,
        );
      return Number(result.changes) === 1;
    },

    loadIdentity(username) {
      const row = db.prepare("SELECT email FROM identity WHERE username = ?").get(username);
      return row === undefined ? undefined : text(row, "email");
    },

    saveIdentity(username, email, now) {
      db.prepare(
        `INSERT INTO identity (username, email, resolved_at) VALUES (?, ?, ?)
         ON CONFLICT(username) DO UPDATE SET email = excluded.email, resolved_at = excluded.resolved_at`,
      ).run(username, email, now);
    },

    isPaused: () => metaValue(META_PAUSED) === "1",
    setPaused: (paused) => {
      setMeta(META_PAUSED, paused ? "1" : "0");
    },
    close: () => {
      db.close();
    },
  };
}
