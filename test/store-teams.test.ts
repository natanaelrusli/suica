import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, describe, expect, it } from "vitest";
import { openStore } from "../src/store.ts";
import type { Round } from "../src/teams/types.ts";
import { mr, reviewer, snapshot } from "./builders.ts";
import { NOW, intent, teamsPlan } from "./teams-builders.ts";

const folders: string[] = [];
afterEach(() => {
  for (const folder of folders.splice(0)) rmSync(folder, { recursive: true, force: true });
});
function tempDb(): string {
  const folder = mkdtempSync(join(tmpdir(), "mra-store2-"));
  folders.push(folder);
  return join(folder, "state.db");
}

const round: Round = {
  myState: "APPROVED",
  myNotes: 1,
  changedAt: NOW,
  noticedState: "UNREVIEWED",
  noticedNotes: 0,
};
const DAY = 24 * 3_600_000;

describe("schema v2", () => {
  it("migrates a version 1 database in place and keeps its data", () => {
    const path = tempDb();
    const old = new DatabaseSync(path);
    old.exec(`
      CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE tracked_authored (mr_key TEXT PRIMARY KEY);
      CREATE TABLE my_review_state (mr_key TEXT PRIMARY KEY, state TEXT NOT NULL);
      CREATE TABLE reviewer_state (mr_key TEXT NOT NULL, username TEXT NOT NULL, state TEXT NOT NULL, PRIMARY KEY (mr_key, username));
      CREATE TABLE seen_note (note_id TEXT PRIMARY KEY);
      INSERT INTO meta (key, value) VALUES ('baseline_done', '1');
      PRAGMA user_version = 1;
    `);
    old.close();

    const store = openStore(path);
    expect(store.load().baselineDone).toBe(true);
    expect(store.loadTeams()).toEqual({
      baselineDone: false,
      nudges: new Map(),
      rounds: new Map(),
    });
    store.close();

    const raw = new DatabaseSync(path);
    expect(raw.prepare("PRAGMA user_version").get()?.["user_version"]).toBe(2);
    raw.close();
  });
});

describe("applyTeamsPlan", () => {
  it("queues intents once, whatever the number of times the same plan is applied", () => {
    const store = openStore(":memory:");
    const plan = teamsPlan({ intents: [intent(1)] });
    expect(store.applyTeamsPlan(plan, NOW)).toBe(1);
    expect(store.applyTeamsPlan(plan, NOW + 1000)).toBe(0);
    const rows = store.listOutbox(["queued"]);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      dedupeKey: "nudge:g/p!5|bob:1",
      kind: "nudge",
      variant: "nudge",
      mrKey: "g/p!5",
      mrIid: 5,
      mrProject: "g/p",
      mrTitle: "Add thing",
      recipient: "bob",
      recipientName: "Bob",
      status: "queued",
      detail: "",
      text: null,
      createdAt: NOW,
      updatedAt: NOW,
    });
  });

  it("records the ledger and the Teams baseline", () => {
    const store = openStore(":memory:");
    store.applyTeamsPlan(
      teamsPlan({
        nudgeUpdates: [{ key: "g/p!5|bob", record: { sentCount: 1, lastSentAt: NOW } }],
        roundUpdates: [{ mrKey: "g/p!7", round }],
        keepNudges: ["g/p!5|bob"],
        keepRounds: ["g/p!7"],
      }),
      NOW,
    );
    expect(store.loadTeams()).toEqual({
      baselineDone: true,
      nudges: new Map([["g/p!5|bob", { sentCount: 1, lastSentAt: NOW }]]),
      rounds: new Map([["g/p!7", round]]),
    });
  });

  it("deletes ledger rows that are no longer kept, and old finished outbox rows", () => {
    const store = openStore(":memory:");
    store.applyTeamsPlan(
      teamsPlan({
        intents: [intent(1), intent(2)],
        nudgeUpdates: [
          { key: "a|x", record: { sentCount: 1, lastSentAt: NOW } },
          { key: "b|y", record: { sentCount: 1, lastSentAt: NOW } },
        ],
        roundUpdates: [
          { mrKey: "a", round },
          { mrKey: "b", round },
        ],
        keepNudges: ["a|x", "b|y"],
        keepRounds: ["a", "b"],
      }),
      NOW - 100 * DAY,
    );
    const [first, second] = store.listOutbox(["queued"]);
    store.transitionOutbox(first?.id ?? 0, "queued", "sent", {}, NOW - 100 * DAY);
    expect(second?.status).toBe("queued");

    store.applyTeamsPlan(teamsPlan({ keepNudges: ["a|x"], keepRounds: ["a"] }), NOW);
    const state = store.loadTeams();
    expect([...state.nudges.keys()]).toEqual(["a|x"]);
    expect([...state.rounds.keys()]).toEqual(["a"]);
    // The 100-day-old sent row is pruned; the unfinished queued row stays however old it is.
    expect(store.listOutbox(["sent"])).toHaveLength(0);
    expect(store.listOutbox(["queued"])).toHaveLength(1);
  });

  it("is untouched by the Plan 1 commit", () => {
    const store = openStore(":memory:");
    store.applyTeamsPlan(
      teamsPlan({
        intents: [intent(1)],
        keepRounds: ["g/p!7"],
        roundUpdates: [{ mrKey: "g/p!7", round }],
      }),
      NOW,
    );
    store.commit(
      snapshot({ reviewRequested: [mr(1, { reviewers: [reviewer("me", "UNREVIEWED")] })] }),
    );
    expect(store.listOutbox(["queued"])).toHaveLength(1);
    expect(store.loadTeams().rounds.size).toBe(1);
  });
});

describe("outbox transitions", () => {
  it("is a compare-and-set: only one caller can move a row out of a status", () => {
    const store = openStore(":memory:");
    store.applyTeamsPlan(teamsPlan({ intents: [intent(1)] }), NOW);
    const id = store.listOutbox(["queued"])[0]?.id ?? 0;
    expect(store.transitionOutbox(id, "queued", "pending", { text: "halo" }, NOW + 1)).toBe(true);
    expect(store.transitionOutbox(id, "queued", "sending", {}, NOW + 2)).toBe(false);
    expect(store.getOutbox(id)).toMatchObject({
      status: "pending",
      text: "halo",
      updatedAt: NOW + 1,
    });
  });

  it("keeps the text when a later transition does not provide one, and can overwrite the detail", () => {
    const store = openStore(":memory:");
    store.applyTeamsPlan(teamsPlan({ intents: [intent(1)] }), NOW);
    const id = store.listOutbox(["queued"])[0]?.id ?? 0;
    store.transitionOutbox(id, "queued", "pending", { text: "halo" }, NOW);
    store.transitionOutbox(id, "pending", "failed", { detail: "error" }, NOW);
    expect(store.getOutbox(id)).toMatchObject({ status: "failed", text: "halo", detail: "error" });
  });

  it("lists by status, oldest first, and returns undefined for an unknown id", () => {
    const store = openStore(":memory:");
    store.applyTeamsPlan(teamsPlan({ intents: [intent(1), intent(2)] }), NOW);
    const ids = store.listOutbox(["queued"]).map((row) => row.id);
    expect(ids).toHaveLength(2);
    expect(ids[0]).toBeLessThan(ids[1] ?? 0);
    expect(store.listOutbox(["sent", "failed"])).toEqual([]);
    expect(store.getOutbox(9999)).toBeUndefined();
  });
});

describe("identity cache", () => {
  it("saves and loads an email per GitLab username", () => {
    const store = openStore(":memory:");
    expect(store.loadIdentity("20435")).toBeUndefined();
    store.saveIdentity("20435", "rayhan@madhani.id", NOW);
    store.saveIdentity("20435", "rayhan.new@madhani.id", NOW + 1);
    expect(store.loadIdentity("20435")).toBe("rayhan.new@madhani.id");
  });
});
