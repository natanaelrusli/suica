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
    status,
    detail: "",
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
      row(1, "sent", { createdAt: 500, updatedAt: 600 }),
    ];
    const golden: unknown = JSON.parse(readFileSync("contracts/agent-state.v1.json", "utf8"));
    expect(buildAgentState({ ...base, rows })).toEqual(golden);
  });

  it("reports teams as null when Teams is disabled", () => {
    expect(buildAgentState({ ...base, rows: undefined }).teams).toBeNull();
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

  it("does not expose the template variant or internal keys", () => {
    const item = buildAgentState({ ...base, rows: [row(1, "pending")] }).teams?.attention[0];
    expect(Object.keys(item ?? {}).sort()).toEqual([
      "createdAt",
      "detail",
      "id",
      "kind",
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
