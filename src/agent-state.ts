import type { ReviewActivityJson } from "./reviews.ts";
import { ATTENTION_STATUSES, OUTBOX_STATUSES } from "./teams/types.ts";
import type { OutboxRow, OutboxStatus } from "./teams/types.ts";

/** The document `suica state` prints. The menu bar app decodes it; see contracts/agent-state.v1.json. */
export interface AgentItemJson {
  readonly id: number;
  readonly kind: string;
  readonly status: OutboxStatus;
  readonly detail: string;
  readonly recipientName: string;
  readonly mrKey: string;
  readonly mrTitle: string;
  readonly mrUrl: string;
  readonly text: string | null;
  /** True when the Owner approved sending it, false when it went without approval, null when unknown. */
  readonly approved: boolean | null;
  /** True for a Review Notice saying you approved the MR in GitLab. */
  readonly mrApproved: boolean;
  /** Epoch milliseconds. */
  readonly createdAt: number;
  readonly updatedAt: number;
}

export interface AgentStateJson {
  readonly version: 1;
  readonly paused: boolean;
  readonly baselineDone: boolean;
  readonly trackedAuthored: number;
  readonly reviewRequested: number;
  /** What the agent is reviewing now; null from a caller that did not read it. */
  readonly agentReview: ReviewActivityJson | null;
  /** Null when Teams is disabled. */
  readonly teams: {
    readonly counts: Readonly<Record<OutboxStatus, number>>;
    readonly attentionHidden: number;
    readonly attention: readonly AgentItemJson[];
    readonly recent: readonly AgentItemJson[];
  } | null;
}

export interface AgentStateInput {
  readonly paused: boolean;
  readonly baselineDone: boolean;
  readonly trackedAuthored: number;
  readonly reviewRequested: number;
  readonly agentReview?: ReviewActivityJson;
  /** Undefined when Teams is disabled. */
  readonly rows: readonly OutboxRow[] | undefined;
}

const MAX_ATTENTION = 100;
const MAX_RECENT = 20;

function toItem(row: OutboxRow): AgentItemJson {
  return {
    id: row.id,
    kind: row.kind,
    status: row.status,
    detail: row.detail,
    recipientName: row.recipientName,
    mrKey: row.mrKey,
    mrTitle: row.mrTitle,
    mrUrl: row.mrUrl,
    text: row.text,
    approved: row.approved,
    mrApproved: row.variant === "notice.approved",
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  };
}

function needsOwner(row: OutboxRow): boolean {
  return row.status === "queued" || ATTENTION_STATUSES.includes(row.status);
}

export function buildAgentState(input: AgentStateInput): AgentStateJson {
  const { rows } = input;
  const teams =
    rows === undefined
      ? null
      : (() => {
          const byId = [...rows].sort((a, b) => a.id - b.id);
          const attention = byId.filter(needsOwner);
          const finished = byId.filter((row) => !needsOwner(row));
          const counts = Object.fromEntries(
            OUTBOX_STATUSES.map((status) => [
              status,
              rows.filter((row) => row.status === status).length,
            ]),
          ) as Record<OutboxStatus, number>;
          return {
            counts,
            attentionHidden: Math.max(0, attention.length - MAX_ATTENTION),
            attention: attention.slice(0, MAX_ATTENTION).map(toItem),
            recent: finished.slice(-MAX_RECENT).reverse().map(toItem),
          };
        })();
  return {
    version: 1,
    paused: input.paused,
    baselineDone: input.baselineDone,
    trackedAuthored: input.trackedAuthored,
    reviewRequested: input.reviewRequested,
    agentReview: input.agentReview ?? null,
    teams,
  };
}

/** One line of JSON for `suica send|skip|retry <id> --json`. */
export function actionJson(status: string): string {
  return JSON.stringify({ status });
}
