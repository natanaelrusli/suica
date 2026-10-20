import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { actionJson, buildAgentState } from "../src/agent-state.ts";
import type { OutboxRow, OutboxStatus } from "../src/teams/types.ts";

function row(id: number, status: OutboxStatus, overrides: Partial<OutboxRow> = {}): OutboxRow {
  return {
    id,
    dedupeKey: `k:${id}`,
    kind: "nudge",
    variant: "nudge",
    mrKey: "g/p!5",
    mrIid: 5,
    mrProject: "g/p",
    mrTitle: "Add thing",
    mrUrl: "https://gitlab.example/g/p/-/merge_requests/5",
    recipient: "bob",
    recipientName: "Bob",
    findings: null,
    status,
    detail: "",
    approved: false,
    text: "Halo Bob",
    createdAt: id * 100,
    updatedAt: id * 100,
    ...overrides,
  };
}

const base = { paused: false, baselineDone: true, trackedAuthored: 4, reviewRequested: 5 };

describe("buildAgentState", () => {
  it("matches the golden contract file", () => {
    const rows = [
      row(2, "pending", { createdAt: 1000, updatedAt: 2000 }),
      row(1, "sent", { approved: true, createdAt: 500, updatedAt: 600 }),
    ];
    const golden: unknown = JSON.parse(readFileSync("contracts/agent-state.v1.json", "utf8"));
    const running = {
      id: 4,
      mrKey: "g/p!7",
      mrTitle: "Add thing",
      cli: "claude",
      model: "opus",
      startedAt: 1792148400000,
      latestActivity: "Reading src/a.ts",
    };
    const agentReview = {
      running,
      runningReviews: [running],
      queued: [{ id: 5, mrKey: "g/p!8", mrTitle: null }],
    };
    expect(buildAgentState({ ...base, rows, agentReview })).toEqual(golden);
  });

  it("lists a Re-review Nudge under its own kind, and never marks it as an approval notice", () => {
    const rows = [row(1, "pending", { kind: "rereview", variant: "rereview" })];
    const attention = buildAgentState({ ...base, rows }).teams?.attention;
    expect(attention?.map((item) => [item.kind, item.mrApproved])).toEqual([["rereview", false]]);
  });

  it("reports teams as null when Teams is disabled", () => {
    expect(buildAgentState({ ...base, rows: undefined }).teams).toBeNull();
    expect(buildAgentState({ ...base, rows: undefined }).agentReview).toBeNull();
  });

  it("puts pending, unresolved, failed, sending and queued rows in attention, oldest first", () => {
    const rows = [
      row(5, "queued"),
      row(4, "sending"),
      row(3, "failed"),
      row(2, "unresolved"),
      row(1, "pending"),
      row(6, "sent"),
      row(7, "skipped"),
      row(8, "dry-run"),
    ];
    const teams = buildAgentState({ ...base, rows }).teams;
    expect(teams?.attention.map((item) => item.id)).toEqual([1, 2, 3, 4, 5]);
    expect(teams?.recent.map((item) => item.id)).toEqual([8, 7, 6]);
  });

  it("keeps the 20 newest finished rows in recent, newest first, and counts every status", () => {
    const rows = Array.from({ length: 25 }, (_, index) => row(index + 1, "sent"));
    const teams = buildAgentState({ ...base, rows }).teams;
    expect(teams?.recent).toHaveLength(20);
    expect(teams?.recent[0]?.id).toBe(25);
    expect(teams?.recent[19]?.id).toBe(6);
    expect(teams?.counts).toEqual({
      queued: 0,
      pending: 0,
      sending: 0,
      sent: 25,
      skipped: 0,
      failed: 0,
      unresolved: 0,
      "dry-run": 0,
    });
  });

  it("cuts attention at 100 and reports how many were hidden", () => {
    const rows = Array.from({ length: 150 }, (_, index) => row(index + 1, "pending"));
    const teams = buildAgentState({ ...base, rows }).teams;
    expect(teams?.attention).toHaveLength(100);
    expect(teams?.attentionHidden).toBe(50);
    expect(teams?.attention[0]?.id).toBe(1);
  });

  it("passes awkward text through unchanged", () => {
    const title = `line one\nline "two" 🙂 ${"x".repeat(5000)}`;
    const teams = buildAgentState({ ...base, rows: [row(1, "pending", { mrTitle: title })] }).teams;
    expect(teams?.attention[0]?.mrTitle).toBe(title);
  });

  it("marks only notices about an MR the Owner approved", () => {
    const rows = [
      row(1, "sent", { kind: "notice", variant: "notice.approved" }),
      row(2, "sent", { kind: "notice", variant: "notice.changes" }),
      row(3, "sent"),
    ];
    const recent = buildAgentState({ ...base, rows }).teams?.recent ?? [];
    expect(recent.map((item) => [item.id, item.mrApproved])).toEqual([
      [3, false],
      [2, false],
      [1, true],
    ]);
  });

  it("does not expose the template variant or internal keys", () => {
    const item = buildAgentState({ ...base, rows: [row(1, "pending")] }).teams?.attention[0];
    expect(Object.keys(item ?? {}).sort()).toEqual([
      "approved",
      "createdAt",
      "detail",
      "id",
      "kind",
      "mrApproved",
      "mrKey",
      "mrTitle",
      "mrUrl",
      "recipientName",
      "status",
      "text",
      "updatedAt",
    ]);
  });
});

describe("actionJson", () => {
  it("produces one line of JSON", () => {
    expect(actionJson("sent")).toBe('{"status":"sent"}');
  });
});
