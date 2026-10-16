import { describe, expect, it } from "vitest";
import { formatOutbox } from "../src/teams/format-outbox.ts";
import type { OutboxRow } from "../src/teams/types.ts";

const row = (overrides: Partial<OutboxRow> = {}): OutboxRow => ({
  id: 12,
  dedupeKey: "k",
  kind: "nudge",
  variant: "nudge",
  mrKey: "g/p!5",
  mrIid: 5,
  mrProject: "g/p",
  mrTitle: "Add thing",
  mrUrl: "https://gitlab.example/g/p/-/merge_requests/5",
  recipient: "bob",
  recipientName: "Bob",
  status: "pending",
  detail: "",
  text: "Halo Bob,\nboleh minta tolong review?",
  createdAt: 1,
  updatedAt: 1,
  ...overrides,
});

describe("formatOutbox", () => {
  it("says so when there is nothing to show", () => {
    expect(formatOutbox([])).toBe("no messages\n");
  });

  it("shows a pending message with its full text, indented", () => {
    expect(formatOutbox([row()])).toBe(
      [
        "#12 [pending] nudge → Bob · g/p!5",
        "    Halo Bob,",
        "    boleh minta tolong review?",
        "",
      ].join("\n"),
    );
  });

  it("explains unresolved, failed and sending rows", () => {
    const text = formatOutbox([
      row({ id: 1, status: "unresolved", detail: "no-match", text: null }),
      row({ id: 2, status: "failed", detail: "error", text: null }),
      row({ id: 3, status: "sending", text: null }),
    ]);
    expect(text).toContain(
      "#1 [unresolved] nudge → Bob · g/p!5 (no-match: add the person to teams.people, then `mra retry 1`)",
    );
    expect(text).toContain("#2 [failed] nudge → Bob · g/p!5 (error: not retried automatically)");
    expect(text).toContain("#3 [sending] nudge → Bob · g/p!5 (may have been sent: check Teams)");
  });

  it("shows only the first line of text for rows that are not waiting for a decision", () => {
    const text = formatOutbox([row({ status: "sent" })]);
    expect(text).toBe("#12 [sent] nudge → Bob · g/p!5\n");
  });
});
