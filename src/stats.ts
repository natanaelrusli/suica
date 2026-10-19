import type { HistoryEvent, HistoryRows, PollLogEntry } from "./store.ts";
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
}

export interface StatsInput {
  readonly history: HistoryRows;
  readonly outbox: readonly OutboxRow[];
  readonly now: number;
  readonly days: number;
  readonly dayKey: (ms: number) => string;
}

const MINUTE = 60_000;
const DAY = 24 * 60 * MINUTE;
const TURNAROUND_WINDOW = 30 * DAY;

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
  };
}
