import { describe, expect, it } from "vitest";
import { groupForMerge, ticketKey } from "../src/teams/merge.ts";
import type { OutboxRow } from "../src/teams/types.ts";

function row(id: number, overrides: Partial<OutboxRow> = {}): OutboxRow {
  return {
    id,
    dedupeKey: `nudge:g/p!${id}|bob:1`,
    kind: "nudge",
    variant: "nudge",
    mrKey: `g/p!${id}`,
    mrIid: id,
    mrProject: "g/p",
    mrTitle: "ABC-1 thing",
    mrUrl: `https://gitlab.example/g/p/-/merge_requests/${id}`,
    recipient: "bob",
    recipientName: "Bob",
    findings: null,
    status: "queued",
    detail: "",
    text: null,
    approved: false,
    createdAt: 0,
    updatedAt: 0,
    ...overrides,
  };
}

const ids = (groups: OutboxRow[][]) => groups.map((group) => group.map((each) => each.id));

describe("ticketKey", () => {
  it("finds the first ticket key in a title", () => {
    expect(ticketKey("[ABC-123] Add login")).toBe("ABC-123");
    expect(ticketKey("feat(PAY-7): x")).toBe("PAY-7");
    expect(ticketKey("ABC-1 and DEF-2")).toBe("ABC-1");
  });

  it("is null without a key", () => {
    expect(ticketKey("Fix login")).toBeNull();
    expect(ticketKey("abc-1 lower")).toBeNull();
  });
});

describe("groupForMerge", () => {
  it("merges rows of one recipient, variant and ticket", () => {
    expect(ids(groupForMerge([row(1), row(2)]))).toEqual([[1, 2]]);
  });

  it("keeps a different ticket, recipient or variant apart", () => {
    const rows = [
      row(1),
      row(2, { mrTitle: "ABC-2 thing" }),
      row(3, { recipient: "carol" }),
      row(4, { kind: "reminder", variant: "reminder" }),
    ];
    expect(ids(groupForMerge(rows))).toEqual([[1], [2], [3], [4]]);
  });

  it("never merges a row without a ticket key", () => {
    const rows = [row(1, { mrTitle: "Fix login" }), row(2, { mrTitle: "Fix login" })];
    expect(ids(groupForMerge(rows))).toEqual([[1], [2]]);
  });

  it("never merges a notice", () => {
    const notice = { kind: "notice", variant: "notice.approved" } as const;
    expect(ids(groupForMerge([row(1, notice), row(2, notice)]))).toEqual([[1], [2]]);
  });

  it("splits a group of twelve into 10 and 2", () => {
    const rows = Array.from({ length: 12 }, (_, index) => row(index + 1));
    const groups = ids(groupForMerge(rows));
    expect(groups.map((group) => group.length)).toEqual([10, 2]);
    expect(groups.flat()).toEqual(rows.map((each) => each.id));
  });

  it("orders groups by their first row", () => {
    const rows = [row(1), row(2, { mrTitle: "ABC-2 thing" }), row(3)];
    expect(ids(groupForMerge(rows))).toEqual([[1, 3], [2]]);
  });
});
