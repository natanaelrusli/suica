import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, describe, expect, it } from "vitest";
import { openStore } from "../src/store.ts";
import type { FirstApproval, HistoryEvent, PollLogEntry } from "../src/store.ts";
import { mr, reviewer, snapshot } from "./builders.ts";
import { NOW, intent, teamsPlan } from "./teams-builders.ts";

const DAY = 24 * 3_600_000;
const folders: string[] = [];
afterEach(() => {
  for (const folder of folders.splice(0)) rmSync(folder, { recursive: true, force: true });
});
function tempDb(): string {
  const folder = mkdtempSync(join(tmpdir(), "suica-history-"));
  folders.push(folder);
  return join(folder, "state.db");
}

function event(kind: HistoryEvent["kind"], at: number, username = ""): HistoryEvent {
  return { kind, mrKey: "g/p!5", username, at };
}
function poll(at: number, overrides: Partial<PollLogEntry> = {}): PollLogEntry {
  return { at, status: "ok", failure: null, durationMs: 120, ...overrides };
}

describe("schema v3", () => {
  it("upgrades a v2 database to the current schema and keeps its rows", () => {
    const path = tempDb();
    const first = openStore(path);
    first.applyTeamsPlan(teamsPlan({ intents: [intent(1)] }), NOW);
    first.close();
    const old = new DatabaseSync(path);
    old.exec("DROP TABLE poll_log; DROP TABLE history_event; PRAGMA user_version = 2;");
    old.close();

    const store = openStore(path);
    expect(store.listOutbox(["queued"])).toHaveLength(1);
    expect(store.loadHistory(0)).toEqual({ polls: [], events: [] });
    store.close();

    const raw = new DatabaseSync(path);
    expect(raw.prepare("PRAGMA user_version").get()?.["user_version"]).toBe(20);
    raw.close();
  });
});

describe("history", () => {
  it("stores history events in the commit transaction", () => {
    const store = openStore(":memory:");
    const stored = [event("review-requested", NOW), event("reviewer-reviewed", NOW + 1, "bob")];
    store.commit(snapshot({ reviewRequested: [mr(5)] }), stored);
    expect(store.loadHistory(0).events).toEqual(stored);
    expect(store.load().baselineDone).toBe(true);
  });

  it("commits without history by default", () => {
    const store = openStore(":memory:");
    store.commit(snapshot());
    expect(store.loadHistory(0)).toEqual({ polls: [], events: [] });
  });

  it("does not store history when the commit fails", () => {
    const path = tempDb();
    const store = openStore(path);
    const broken = { ...event("activity", NOW), at: Number.NaN };
    expect(() => {
      store.commit(snapshot({ reviewRequested: [mr(5)] }), [event("activity", NOW), broken]);
    }).toThrow();
    store.close();

    const reopened = openStore(path);
    expect(reopened.loadHistory(0)).toEqual({ polls: [], events: [] });
    expect(reopened.load().baselineDone).toBe(false);
    reopened.close();
  });

  it("records polls oldest first and prunes rows older than 90 days", () => {
    const store = openStore(":memory:");
    store.commit(snapshot(), [event("activity", NOW)]);
    store.recordPoll(poll(NOW + 2000, { status: "failed", failure: "network" }));
    store.recordPoll(poll(NOW));
    expect(store.loadHistory(0).polls).toEqual([
      poll(NOW),
      poll(NOW + 2000, { status: "failed", failure: "network" }),
    ]);
    expect(store.loadHistory(0).events).toHaveLength(1);

    store.recordPoll(poll(NOW + 91 * DAY));
    expect(store.loadHistory(0).polls).toEqual([poll(NOW + 91 * DAY)]);
    expect(store.loadHistory(0).events).toEqual([]);
  });

  it("keeps rows exactly 90 days old", () => {
    const store = openStore(":memory:");
    store.commit(snapshot(), [event("activity", NOW)]);
    store.recordPoll(poll(NOW));
    store.recordPoll(poll(NOW + 90 * DAY));
    expect(store.loadHistory(0).polls).toHaveLength(2);
    expect(store.loadHistory(0).events).toHaveLength(1);
  });

  it("loadHistory(since) returns only rows at or after since", () => {
    const store = openStore(":memory:");
    store.commit(snapshot(), [
      event("review-requested", NOW),
      event("owner-reviewed", NOW + 10),
      event("activity", NOW + 20),
    ]);
    store.recordPoll(poll(NOW));
    store.recordPoll(poll(NOW + 10));
    const history = store.loadHistory(NOW + 10);
    expect(history.events.map((e) => e.kind)).toEqual(["owner-reviewed", "activity"]);
    expect(history.polls.map((p) => p.at)).toEqual([NOW + 10]);
  });

  it("lastPoll is the latest poll by time, the later one of a tie, and undefined when none", () => {
    const store = openStore(":memory:");
    expect(store.lastPoll()).toBeUndefined();
    store.recordPoll(poll(NOW + 2000, { status: "failed", failure: "network" }));
    store.recordPoll(poll(NOW));
    expect(store.lastPoll()).toEqual(poll(NOW + 2000, { status: "failed", failure: "network" }));
    store.recordPoll(poll(NOW + 2000, { durationMs: 7 }));
    expect(store.lastPoll()).toEqual(poll(NOW + 2000, { durationMs: 7 }));
  });

  it("lastPoll rejects a stored row with an unknown status", () => {
    const path = tempDb();
    openStore(path).close();
    const db = new DatabaseSync(path);
    db.exec("INSERT INTO poll_log VALUES (1, 'bogus', NULL, 5)");
    db.close();
    const store = openStore(path);
    expect(() => store.lastPoll()).toThrow(/unknown status/);
    store.close();
  });

  it("rejects a stored row with an unknown kind or status", () => {
    const path = tempDb();
    openStore(path).close();
    const raw = new DatabaseSync(path);
    raw.exec(
      "INSERT INTO history_event (kind, mr_key, username, at) VALUES ('bogus', 'g/p!5', '', 1)",
    );
    raw.close();
    const store = openStore(path);
    expect(() => store.loadHistory(0)).toThrow(/unknown kind/);
    store.close();

    const other = tempDb();
    openStore(other).close();
    const db = new DatabaseSync(other);
    db.exec("INSERT INTO poll_log VALUES (1, 'bogus', NULL, 5)");
    db.close();
    const second = openStore(other);
    expect(() => second.loadHistory(0)).toThrow(/unknown status/);
    second.close();
  });
});

function approval(mrKey: string, approvedAt: number, approver = "bob"): FirstApproval {
  return {
    mrKey,
    title: "Add thing",
    url: "https://gitlab.example/g/p/-/merge_requests/5",
    openedAt: NOW - DAY,
    approvedAt,
    approver: { username: approver, name: "Bob" },
  };
}

describe("schema v13", () => {
  it("upgrades a v12 database and keeps its history", () => {
    const path = tempDb();
    const first = openStore(path);
    first.commit(snapshot(), [event("reviewer-reviewed", NOW, "bob")]);
    first.close();
    const old = new DatabaseSync(path);
    old.exec("DROP TABLE first_approval; DROP TABLE person_name; PRAGMA user_version = 12;");
    old.close();

    const store = openStore(path);
    expect(store.loadHistory(0).events).toEqual([event("reviewer-reviewed", NOW, "bob")]);
    expect(store.loadApprovals(0)).toEqual([]);
    expect(store.loadNames()).toEqual(new Map());
    store.close();
  });
});

describe("names", () => {
  it("remembers the latest name of every author and Reviewer on an open MR, also after it closes", () => {
    const store = openStore(":memory:");
    const open = mr(5, {
      author: { username: "alice", name: "Alice Old" },
      reviewers: [reviewer("bob", "UNREVIEWED")],
    });
    store.commit(snapshot({ reviewRequested: [open] }));
    store.commit(snapshot({ authored: [mr(6, { author: { username: "alice", name: "Alice" } })] }));
    store.commit(snapshot());
    expect(store.loadNames()).toEqual(
      new Map([
        ["alice", "Alice"],
        ["bob", "bob"],
      ]),
    );
  });
});

describe("first approvals", () => {
  it("keeps only the first approval of an MR, in the commit transaction", () => {
    const store = openStore(":memory:");
    store.commit(snapshot(), [], [approval("g/p!5", NOW), approval("g/p!5", NOW + 5, "carol")]);
    store.commit(snapshot(), [], [approval("g/p!5", NOW + 10, "dave"), approval("g/p!6", NOW + 1)]);
    expect(store.loadApprovals(0)).toEqual([approval("g/p!5", NOW), approval("g/p!6", NOW + 1)]);
    expect(store.loadApprovals(NOW + 1)).toEqual([approval("g/p!6", NOW + 1)]);
  });

  it("forgets approvals older than 90 days with the history", () => {
    const store = openStore(":memory:");
    store.commit(snapshot(), [], [approval("g/p!5", NOW), approval("g/p!6", NOW + DAY)]);
    store.recordPoll(poll(NOW + 90 * DAY + 1));
    expect(store.loadApprovals(0)).toEqual([approval("g/p!6", NOW + DAY)]);
  });
});

describe("unnamed usernames", () => {
  it("lists history usernames without a name, most recently active first, up to the limit", () => {
    const store = openStore(":memory:");
    store.commit(
      snapshot({
        reviewRequested: [mr(5, { author: { username: "named", name: "Named Person" } })],
      }),
      [
        event("reviewer-reviewed", NOW, "old"),
        event("owner-reviewed", NOW + 1, "named"),
        event("activity", NOW + 2),
        event("reviewer-reviewed", NOW + 3, "recent"),
        event("reviewer-reviewed", NOW + 4, "middle"),
        event("reviewer-reviewed", NOW + 5, "recent"),
      ],
    );
    expect(store.unnamedUsernames(10)).toEqual(["recent", "middle", "old"]);
    expect(store.unnamedUsernames(1)).toEqual(["recent"]);

    store.saveNames([{ username: "recent", name: "Recent Person" }]);
    expect(store.unnamedUsernames(10)).toEqual(["middle", "old"]);
    expect(store.loadNames().get("recent")).toBe("Recent Person");
  });
});
