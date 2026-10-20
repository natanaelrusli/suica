import type { Person } from "./domain.ts";
import type {
  FirstApproval,
  HistoryEvent,
  HistoryKind,
  HistoryRows,
  PollLogEntry,
} from "./store.ts";
import type { OutboxRow } from "./teams/types.ts";

/** The document `suica stats` prints. The app window decodes it; see contracts/stats.v1.json. */
export interface TurnaroundJson {
  readonly count: number;
  readonly medianMinutes: number | null;
  readonly p90Minutes: number | null;
}

export interface DayJson {
  /** Local calendar day, `YYYY-MM-DD`. */
  readonly day: string;
  readonly reviewRequests: number;
  readonly activity: number;
  /** Outbox rows of kind nudge, reminder or rereview that were sent. */
  readonly nudgesSent: number;
  readonly noticesSent: number;
  readonly skipped: number;
  readonly failed: number;
}

export interface PollCountsJson {
  readonly ok: number;
  readonly failed: number;
}

export interface PersonCountJson {
  readonly username: string;
  /** The display name last seen on an open MR, else the username. */
  readonly name: string;
  /** Distinct MRs. */
  readonly mergeRequests: number;
}

export interface SlowApprovalJson {
  readonly mrKey: string;
  readonly title: string;
  readonly url: string;
  /** Epoch milliseconds. */
  readonly openedAt: number;
  /** Epoch milliseconds: the poll that first saw an approval. */
  readonly approvedAt: number;
  readonly minutes: number;
  readonly approver: Person;
}

export interface StatsJson {
  readonly version: 1;
  /** Epoch milliseconds. */
  readonly generatedAt: number;
  readonly lastPoll: {
    readonly at: number;
    readonly status: "ok" | "failed";
    readonly failure: string | null;
    readonly durationMs: number;
  } | null;
  readonly polls24h: PollCountsJson;
  readonly polls7d: PollCountsJson;
  /** Oldest first, every day present. */
  readonly days: readonly DayJson[];
  readonly ownerAfterRequest: TurnaroundJson;
  readonly reviewerAfterNudge: TurnaroundJson;
  /** Authors of the MRs you reviewed in the last 90 days, most MRs first, at most 10. */
  readonly peopleIReview: readonly PersonCountJson[];
  /** Reviewers of your MRs in the last 90 days, most MRs first, at most 10. */
  readonly peopleWhoReviewMe: readonly PersonCountJson[];
  /** Your MRs first approved in the last 90 days, longest from opening first, at most 10. */
  readonly slowestApprovals: readonly SlowApprovalJson[];
}

export interface StatsInput {
  readonly history: HistoryRows;
  readonly approvals: readonly FirstApproval[];
  /** Username to display name; a username without one is shown as itself. */
  readonly names: ReadonlyMap<string, string>;
  readonly outbox: readonly OutboxRow[];
  readonly now: number;
  readonly days: number;
  readonly dayKey: (ms: number) => string;
}

const MINUTE = 60_000;
const DAY = 24 * 60 * MINUTE;
const TURNAROUND_WINDOW = 30 * DAY;
export const RANKING_WINDOW = 90 * DAY;
const RANKING_SIZE = 10;

type MutableDay = { -readonly [K in keyof DayJson]: DayJson[K] };

export function localDayKey(ms: number): string {
  const date = new Date(ms);
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${date.getFullYear()}-${month}-${day}`;
}

function pollCounts(polls: readonly PollLogEntry[], since: number): PollCountsJson {
  const inWindow = polls.filter((poll) => poll.at >= since);
  return {
    ok: inWindow.filter((poll) => poll.status === "ok").length,
    failed: inWindow.filter((poll) => poll.status === "failed").length,
  };
}

function summarize(durations: readonly number[]): TurnaroundJson {
  if (durations.length === 0) return { count: 0, medianMinutes: null, p90Minutes: null };
  const sorted = durations.map((ms) => Math.round(ms / MINUTE)).sort((a, b) => a - b);
  const rank = (p: number): number => sorted[Math.ceil(p * sorted.length) - 1] ?? 0;
  return { count: sorted.length, medianMinutes: rank(0.5), p90Minutes: rank(0.9) };
}

/** Milliseconds from each start to the first later end that `matches`, for pairs that ended recently. */
function turnarounds(
  starts: readonly { readonly mrKey: string; readonly at: number; readonly recipient?: string }[],
  ends: readonly HistoryEvent[],
  now: number,
): number[] {
  const durations: number[] = [];
  for (const start of starts) {
    const end = ends.find(
      (event) =>
        event.mrKey === start.mrKey &&
        event.at >= start.at &&
        (start.recipient === undefined || event.username === start.recipient),
    );
    if (end !== undefined && end.at >= now - TURNAROUND_WINDOW) durations.push(end.at - start.at);
  }
  return durations;
}

/** People by the distinct MRs of `kind` rows naming them since `since`; rows without a username are left out. */
function ranking(
  events: readonly HistoryEvent[],
  kind: HistoryKind,
  since: number,
  names: ReadonlyMap<string, string>,
): PersonCountJson[] {
  const mrs = new Map<string, Set<string>>();
  for (const event of events) {
    if (event.kind !== kind || event.username === "" || event.at < since) continue;
    mrs.set(event.username, (mrs.get(event.username) ?? new Set()).add(event.mrKey));
  }
  return [...mrs]
    .map(([username, keys]) => ({
      username,
      name: names.get(username) ?? username,
      mergeRequests: keys.size,
    }))
    .sort((a, b) => b.mergeRequests - a.mergeRequests || a.name.localeCompare(b.name))
    .slice(0, RANKING_SIZE);
}

function slowestApprovals(
  approvals: readonly FirstApproval[],
  since: number,
  now: number,
): SlowApprovalJson[] {
  return approvals
    .filter((row) => row.approvedAt >= since && row.approvedAt <= now)
    .map((row) => ({ row, waited: Math.max(0, row.approvedAt - row.openedAt) }))
    .sort((a, b) => b.waited - a.waited || a.row.approvedAt - b.row.approvedAt)
    .slice(0, RANKING_SIZE)
    .map(({ row, waited }) => ({
      mrKey: row.mrKey,
      title: row.title,
      url: row.url,
      openedAt: row.openedAt,
      approvedAt: row.approvedAt,
      minutes: Math.round(waited / MINUTE),
      approver: row.approver,
    }));
}

export function buildStats(input: StatsInput): StatsJson {
  const { now } = input;
  const polls = input.history.polls.filter((poll) => poll.at <= now);
  const events = input.history.events.filter((event) => event.at <= now);
  const outbox = input.outbox.filter((row) => row.updatedAt <= now);

  const days = new Map<string, MutableDay>();
  for (let i = input.days - 1; i >= 0; i--) {
    const day = input.dayKey(now - i * DAY);
    if (!days.has(day)) {
      days.set(day, {
        day,
        reviewRequests: 0,
        activity: 0,
        nudgesSent: 0,
        noticesSent: 0,
        skipped: 0,
        failed: 0,
      });
    }
  }
  for (const event of events) {
    const day = days.get(input.dayKey(event.at));
    if (day === undefined) continue;
    if (event.kind === "review-requested") day.reviewRequests += 1;
    if (event.kind === "activity") day.activity += 1;
  }
  for (const row of outbox) {
    const day = days.get(input.dayKey(row.updatedAt));
    if (day === undefined) continue;
    if (row.status === "sent") {
      if (row.kind === "notice") day.noticesSent += 1;
      else day.nudgesSent += 1;
    }
    if (row.status === "skipped") day.skipped += 1;
    if (row.status === "failed") day.failed += 1;
  }

  const last = polls.at(-1);
  const requests = events.filter((event) => event.kind === "review-requested");
  const nudges = outbox
    .filter((row) => row.kind === "nudge" && row.status === "sent")
    .map((row) => ({ mrKey: row.mrKey, at: row.updatedAt, recipient: row.recipient }));

  return {
    version: 1,
    generatedAt: now,
    lastPoll:
      last === undefined
        ? null
        : { at: last.at, status: last.status, failure: last.failure, durationMs: last.durationMs },
    polls24h: pollCounts(polls, now - DAY),
    polls7d: pollCounts(polls, now - 7 * DAY),
    days: [...days.values()],
    ownerAfterRequest: summarize(
      turnarounds(
        requests,
        events.filter((event) => event.kind === "owner-reviewed"),
        now,
      ),
    ),
    reviewerAfterNudge: summarize(
      turnarounds(
        nudges,
        events.filter((event) => event.kind === "reviewer-reviewed"),
        now,
      ),
    ),
    peopleIReview: ranking(events, "owner-reviewed", now - RANKING_WINDOW, input.names),
    peopleWhoReviewMe: ranking(events, "reviewer-reviewed", now - RANKING_WINDOW, input.names),
    slowestApprovals: slowestApprovals(input.approvals, now - RANKING_WINDOW, now),
  };
}
