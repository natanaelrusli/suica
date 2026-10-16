import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { buildStats, localDayKey } from "../src/stats.ts";
import type { HistoryEvent, HistoryRows, PollLogEntry } from "../src/store.ts";
import type { OutboxRow } from "../src/teams/types.ts";

const NOW = Date.UTC(2026, 9, 16, 12);
const H = 3_600_000;
const M = 60_000;
const D = 24 * H;
const utcDay = (ms: number): string => new Date(ms).toISOString().slice(0, 10);

function poll(at: number, status: "ok" | "failed", failure: string | null, durationMs: number) {
  return { at, status, failure, durationMs } satisfies PollLogEntry;
}
function event(kind: HistoryEvent["kind"], mrKey: string, at: number, username = "") {
  return { kind, mrKey, username, at } satisfies HistoryEvent;
}
function outbox(
  id: number,
  kind: OutboxRow["kind"],
  status: OutboxRow["status"],
  updatedAt: number,
  overrides: Partial<OutboxRow> = {},
): OutboxRow {
  return {
    id,
    dedupeKey: `k:${id}`,
    kind,
    variant: kind === "notice" ? "notice.approved" : kind,
    mrKey: "g/p!2",
    mrIid: 2,
    mrProject: "g/p",
    mrTitle: "Add thing",
    mrUrl: "https://gitlab.example/g/p/-/merge_requests/2",
    recipient: "bob",
    recipientName: "Bob",
    status,
    detail: "",
    text: null,
    createdAt: updatedAt,
    updatedAt,
    ...overrides,
  };
}
const empty: HistoryRows = { polls: [], events: [] };
const build = (history: HistoryRows, rows: readonly OutboxRow[] = [], days = 14) =>
  buildStats({ history, outbox: rows, now: NOW, days, dayKey: utcDay });

describe("buildStats", () => {
  it("matches the golden contract file", () => {
    const history: HistoryRows = {
      polls: [
        poll(NOW - 72 * H, "ok", null, 1200),
        poll(NOW - 2 * H, "failed", "gitlab-unreachable", 800),
        poll(NOW - H, "ok", null, 1500),
      ],
      events: [
        event("review-requested", "g/p!1", NOW - 26 * H),
        event("owner-reviewed", "g/p!1", NOW - 26 * H + 90 * M),
        event("activity", "g/p!2", NOW - 30 * M),
        event("reviewer-reviewed", "g/p!2", NOW - 20 * M, "bob"),
      ],
    };
    const rows = [
      outbox(1, "nudge", "sent", NOW - 140 * M),
      outbox(2, "notice", "sent", NOW - 25 * H),
      outbox(3, "nudge", "skipped", NOW - 10 * M),
    ];
    const golden: unknown = JSON.parse(readFileSync("contracts/stats.v1.json", "utf8"));
    expect(buildStats({ history, outbox: rows, now: NOW, days: 2, dayKey: utcDay })).toEqual(
      golden,
    );
  });

  it("returns zeros, a null lastPoll and null turnarounds with no history", () => {
    const stats = build(empty, [], 3);
    expect(stats.version).toBe(1);
    expect(stats.generatedAt).toBe(NOW);
    expect(stats.lastPoll).toBeNull();
    expect(stats.polls24h).toEqual({ ok: 0, failed: 0 });
    expect(stats.polls7d).toEqual({ ok: 0, failed: 0 });
    expect(stats.days.every((day) => day.reviewRequests + day.activity + day.failed === 0)).toBe(
      true,
    );
    expect(stats.ownerAfterRequest).toEqual({ count: 0, medianMinutes: null, p90Minutes: null });
    expect(stats.reviewerAfterNudge).toEqual({ count: 0, medianMinutes: null, p90Minutes: null });
  });

  it("lists every day including empty ones, oldest first", () => {
    const stats = build(empty, [], 14);
    expect(stats.days).toHaveLength(14);
    expect(stats.days.at(-1)?.day).toBe(utcDay(NOW));
    expect(stats.days[0]?.day).toBe(utcDay(NOW - 13 * D));
    const keys = stats.days.map((day) => day.day);
    expect(keys).toEqual([...keys].sort());
    expect(new Set(keys).size).toBe(14);
  });

  it("merges a duplicate day key into one entry", () => {
    const stats = buildStats({
      history: empty,
      outbox: [],
      now: NOW,
      days: 3,
      dayKey: () => "same",
    });
    expect(stats.days).toHaveLength(1);
  });

  it("ignores events after now", () => {
    const history: HistoryRows = {
      polls: [poll(NOW + H, "failed", "x", 5)],
      events: [
        event("review-requested", "g/p!1", NOW - H),
        event("review-requested", "g/p!3", NOW + H),
        event("owner-reviewed", "g/p!1", NOW + 2 * H),
        event("activity", "g/p!1", NOW + H),
      ],
    };
    const stats = build(history, [outbox(1, "nudge", "sent", NOW + H)]);
    expect(stats.lastPoll).toBeNull();
    expect(stats.polls24h).toEqual({ ok: 0, failed: 0 });
    const today = stats.days.at(-1);
    expect(today?.reviewRequests).toBe(1);
    expect(today?.activity).toBe(0);
    expect(today?.nudgesSent).toBe(0);
    expect(stats.ownerAfterRequest.count).toBe(0);
  });

  it("never reports a negative turnaround", () => {
    const history: HistoryRows = {
      polls: [],
      events: [
        event("owner-reviewed", "g/p!1", NOW - 3 * H),
        event("review-requested", "g/p!1", NOW - 2 * H),
      ],
    };
    expect(build(history).ownerAfterRequest).toEqual({
      count: 0,
      medianMinutes: null,
      p90Minutes: null,
    });
  });

  it("uses nearest-rank median and p90", () => {
    const events: HistoryEvent[] = [];
    for (let i = 1; i <= 10; i++) {
      const start = NOW - 5 * H - i * H;
      events.push(event("review-requested", `g/p!${i}`, start));
      events.push(event("owner-reviewed", `g/p!${i}`, start + i * M));
    }
    events.sort((a, b) => a.at - b.at);
    expect(build({ polls: [], events }).ownerAfterRequest).toEqual({
      count: 10,
      medianMinutes: 5,
      p90Minutes: 9,
    });
  });

  it("drops pairs that ended more than 30 days ago", () => {
    const history: HistoryRows = {
      polls: [],
      events: [
        event("review-requested", "g/p!1", NOW - 31 * D),
        event("owner-reviewed", "g/p!1", NOW - 31 * D + M),
        event("review-requested", "g/p!2", NOW - 29 * D),
        event("owner-reviewed", "g/p!2", NOW - 29 * D + 4 * M),
      ],
    };
    expect(build(history).ownerAfterRequest).toEqual({
      count: 1,
      medianMinutes: 4,
      p90Minutes: 4,
    });
  });

  it("keeps a pair that started more than 30 days ago but ended inside the window", () => {
    const history: HistoryRows = {
      polls: [],
      events: [
        event("review-requested", "g/p!1", NOW - 45 * D),
        event("owner-reviewed", "g/p!1", NOW - 29 * D),
      ],
    };
    expect(build(history).ownerAfterRequest).toEqual({
      count: 1,
      medianMinutes: 16 * 24 * 60,
      p90Minutes: 16 * 24 * 60,
    });
  });

  it("pairs a nudge only with the same reviewer on the same MR", () => {
    const history: HistoryRows = {
      polls: [],
      events: [
        event("reviewer-reviewed", "g/p!2", NOW - 50 * M, "carol"),
        event("reviewer-reviewed", "g/p!9", NOW - 40 * M, "bob"),
        event("reviewer-reviewed", "g/p!2", NOW - 30 * M, "bob"),
      ],
    };
    const stats = build(history, [outbox(1, "nudge", "sent", NOW - 60 * M)]);
    expect(stats.reviewerAfterNudge).toEqual({ count: 1, medianMinutes: 30, p90Minutes: 30 });
  });

  it("counts reminders as nudges sent", () => {
    const stats = build(empty, [
      outbox(1, "reminder", "sent", NOW - M),
      outbox(2, "nudge", "sent", NOW - M),
      outbox(3, "nudge", "failed", NOW - M),
      outbox(4, "notice", "sent", NOW - M),
    ]);
    const today = stats.days.at(-1);
    expect(today?.nudgesSent).toBe(2);
    expect(today?.noticesSent).toBe(1);
    expect(today?.failed).toBe(1);
  });
});

describe("localDayKey", () => {
  it("formats a local YYYY-MM-DD", () => {
    const ms = new Date(2026, 0, 5, 23, 59).getTime();
    expect(localDayKey(ms)).toBe("2026-01-05");
  });
});
