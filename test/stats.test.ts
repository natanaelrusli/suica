import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { buildStats, localDayKey } from "../src/stats.ts";
import type { FirstApproval, HistoryEvent, HistoryRows, PollLogEntry } from "../src/store.ts";
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
function approval(
  mrKey: string,
  openedAt: number,
  approvedAt: number,
  approver = "bob",
): FirstApproval {
  return {
    mrKey,
    title: `Title of ${mrKey}`,
    url: `https://gitlab.example/${mrKey}`,
    openedAt,
    approvedAt,
    approver: { username: approver, name: approver.toUpperCase() },
  };
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
    findings: null,
    status,
    detail: "",
    approved: false,
    text: null,
    createdAt: updatedAt,
    updatedAt,
    ...overrides,
  };
}
const empty: HistoryRows = { polls: [], events: [] };
const build = (
  history: HistoryRows,
  rows: readonly OutboxRow[] = [],
  days = 14,
  approvals: readonly FirstApproval[] = [],
  names: ReadonlyMap<string, string> = new Map(),
) => buildStats({ history, approvals, names, outbox: rows, now: NOW, days, dayKey: utcDay });

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
        event("owner-reviewed", "g/p!1", NOW - 26 * H + 90 * M, "alice"),
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
    const approvals = [
      {
        mrKey: "g/p!2",
        title: "Add thing",
        url: "https://gitlab.example/g/p/-/merge_requests/2",
        openedAt: NOW - 26 * H,
        approvedAt: NOW - 20 * M,
        approver: { username: "bob", name: "Bob" },
      },
    ];
    expect(
      buildStats({
        history,
        approvals,
        names: new Map([
          ["alice", "Alice"],
          ["bob", "Bob"],
        ]),
        outbox: rows,
        now: NOW,
        days: 2,
        dayKey: utcDay,
      }),
    ).toEqual(golden);
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
    expect(stats.peopleIReview).toEqual([]);
    expect(stats.peopleWhoReviewMe).toEqual([]);
    expect(stats.slowestApprovals).toEqual([]);
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
      approvals: [],
      names: new Map(),
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

describe("Re-review Nudges in the statistics", () => {
  it("counts delivered Re-review Nudges with the nudges and reminders sent, not the notices", () => {
    const stats = build(empty, [
      outbox(1, "nudge", "sent", NOW - M),
      outbox(2, "rereview", "sent", NOW - M),
      outbox(3, "rereview", "skipped", NOW - M),
      outbox(4, "rereview", "dry-run", NOW - M),
      outbox(5, "notice", "sent", NOW - M),
    ]);
    const today = stats.days.at(-1);
    expect(today?.nudgesSent).toBe(2);
    expect(today?.noticesSent).toBe(1);
    expect(today?.skipped).toBe(1);
  });

  it("does not measure the turnaround after a plain nudge from a Re-review Nudge", () => {
    const history: HistoryRows = {
      polls: [],
      events: [event("reviewer-reviewed", "g/p!2", NOW - 30 * M, "bob")],
    };
    const stats = build(history, [outbox(1, "rereview", "sent", NOW - 60 * M)]);
    expect(stats.reviewerAfterNudge.count).toBe(0);
  });
});

describe("localDayKey", () => {
  it("formats a local YYYY-MM-DD", () => {
    const ms = new Date(2026, 0, 5, 23, 59).getTime();
    expect(localDayKey(ms)).toBe("2026-01-05");
  });
});

describe("people and approvals in the statistics", () => {
  it("ranks people by distinct MRs, most first, by name", () => {
    const history: HistoryRows = {
      polls: [],
      events: [
        event("owner-reviewed", "g/p!1", NOW - 5 * H, "alice"),
        event("owner-reviewed", "g/p!2", NOW - 4 * H, "carol"),
        event("owner-reviewed", "g/p!3", NOW - 3 * H, "alice"),
        // The same MR twice (reviewed again after a new request) counts once.
        event("owner-reviewed", "g/p!3", NOW - 2 * H, "alice"),
        event("reviewer-reviewed", "g/p!9", NOW - H, "bob"),
      ],
    };
    const names = new Map([
      ["alice", "Alice"],
      ["bob", "Bob"],
      ["carol", "Carol"],
    ]);
    const stats = build(history, [], 14, [], names);
    expect(stats.peopleIReview).toEqual([
      { username: "alice", name: "Alice", mergeRequests: 2 },
      { username: "carol", name: "Carol", mergeRequests: 1 },
    ]);
    expect(stats.peopleWhoReviewMe).toEqual([{ username: "bob", name: "Bob", mergeRequests: 1 }]);
  });

  it("leaves out rows without a person and rows older than 90 days, and falls back to the username", () => {
    const history: HistoryRows = {
      polls: [],
      events: [
        event("reviewer-reviewed", "g/p!1", NOW - 91 * D, "old"),
        event("owner-reviewed", "g/p!2", NOW - 2 * H),
        event("reviewer-reviewed", "g/p!3", NOW - H, "dave"),
      ],
    };
    const stats = build(history);
    expect(stats.peopleIReview).toEqual([]);
    expect(stats.peopleWhoReviewMe).toEqual([{ username: "dave", name: "dave", mergeRequests: 1 }]);
  });

  it("keeps the ten people with the most MRs, ties by name", () => {
    const events = Array.from({ length: 12 }, (_, i) =>
      event("reviewer-reviewed", `g/p!${i}`, NOW - H, `user${String(i).padStart(2, "0")}`),
    );
    events.push(event("reviewer-reviewed", "g/p!99", NOW - H, "user11"));
    const ranked = build({ polls: [], events }).peopleWhoReviewMe;
    expect(ranked).toHaveLength(10);
    expect(ranked[0]).toEqual({ username: "user11", name: "user11", mergeRequests: 2 });
    expect(ranked.slice(1).map((person) => person.username)).toEqual(
      ["00", "01", "02", "03", "04", "05", "06", "07", "08"].map((n) => `user${n}`),
    );
  });

  it("lists the slowest first approvals in the last 90 days, longest first, at most ten", () => {
    const approvals = [
      approval("g/p!1", NOW - 3 * H, NOW - H),
      approval("g/p!2", NOW - 30 * H, NOW - 2 * H, "carol"),
      approval("g/p!3", NOW - 100 * D, NOW - 91 * D),
      approval("g/p!4", NOW - 2 * H, NOW + H),
      ...Array.from({ length: 10 }, (_, i) => approval(`g/q!${i}`, NOW - 10 * M, NOW - 5 * M)),
    ];
    const slowest = build(empty, [], 14, approvals).slowestApprovals;
    expect(slowest).toHaveLength(10);
    expect(slowest[0]).toEqual({
      mrKey: "g/p!2",
      title: "Title of g/p!2",
      url: "https://gitlab.example/g/p!2",
      openedAt: NOW - 30 * H,
      approvedAt: NOW - 2 * H,
      minutes: 28 * 60,
      approver: { username: "carol", name: "CAROL" },
    });
    expect(slowest[1]?.mrKey).toBe("g/p!1");
    expect(slowest.map((row) => row.mrKey)).not.toContain("g/p!3");
    expect(slowest.map((row) => row.mrKey)).not.toContain("g/p!4");
  });

  it("never reports a negative wait for an MR approved before GitLab says it was opened", () => {
    const slowest = build(empty, [], 14, [
      approval("g/p!1", NOW - H, NOW - 2 * H),
    ]).slowestApprovals;
    expect(slowest[0]?.minutes).toBe(0);
  });
});
