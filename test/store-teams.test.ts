import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, describe, expect, it } from "vitest";
import { openStore } from "../src/store.ts";
import type { RereviewMr, RereviewReviewer, Round } from "../src/teams/types.ts";
import { mr, reviewer, snapshot } from "./builders.ts";
import { NOW, intent, teamsPlan } from "./teams-builders.ts";

const folders: string[] = [];
afterEach(() => {
  for (const folder of folders.splice(0)) rmSync(folder, { recursive: true, force: true });
});
function tempDb(): string {
  const folder = mkdtempSync(join(tmpdir(), "suica-store2-"));
  folders.push(folder);
  return join(folder, "state.db");
}

const round: Round = {
  myState: "APPROVED",
  myNotes: 1,
  changedAt: NOW,
  noticedState: "UNREVIEWED",
  noticedNotes: 0,
  announcedReview: null,
};
const DAY = 24 * 3_600_000;
const rereviewMr: RereviewMr = { head: "h2", changedAt: NOW };
const rereviewBob: RereviewReviewer = {
  reviewedHead: "h1",
  state: "APPROVED",
  notes: 2,
  nudged: true,
};
const rereviewCarol: RereviewReviewer = {
  reviewedHead: null,
  state: "UNREVIEWED",
  notes: 0,
  nudged: false,
};

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
      undelivered: new Set(),
      rereviewMrs: new Map(),
      rereviewReviewers: new Map(),
      postedReviews: new Map(),
    });
    store.close();

    const raw = new DatabaseSync(path);
    expect(raw.prepare("PRAGMA user_version").get()?.["user_version"]).toBe(20);
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
      approved: false,
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
      undelivered: new Set(["g/p!5|bob"]),
      rereviewMrs: new Map(),
      rereviewReviewers: new Map(),
      postedReviews: new Map(),
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

describe("Re-review ledger (schema 8)", () => {
  const ledger = teamsPlan({
    rereviewMrs: new Map([["g/p!5", rereviewMr]]),
    rereviewReviewers: new Map([
      ["g/p!5|bob", rereviewBob],
      ["g/p!5|carol", rereviewCarol],
    ]),
  });

  it("stores the head, a null reviewed head and the flags, and reads them back", () => {
    const store = openStore(":memory:");
    store.applyTeamsPlan(ledger, NOW);
    const state = store.loadTeams();
    expect(state.rereviewMrs).toEqual(new Map([["g/p!5", rereviewMr]]));
    expect(state.rereviewReviewers).toEqual(
      new Map([
        ["g/p!5|bob", rereviewBob],
        ["g/p!5|carol", rereviewCarol],
      ]),
    );
  });

  it("replaces the ledger with each plan, so MRs and Reviewers that are gone disappear", () => {
    const store = openStore(":memory:");
    store.applyTeamsPlan(ledger, NOW);
    store.applyTeamsPlan(
      teamsPlan({
        rereviewMrs: new Map([["g/p!5", { head: "h3", changedAt: NOW + 1 }]]),
        rereviewReviewers: new Map([["g/p!5|bob", { ...rereviewBob, nudged: false }]]),
      }),
      NOW + 1,
    );
    const state = store.loadTeams();
    expect(state.rereviewMrs.get("g/p!5")).toEqual({ head: "h3", changedAt: NOW + 1 });
    expect([...state.rereviewReviewers.keys()]).toEqual(["g/p!5|bob"]);
    expect(state.rereviewReviewers.get("g/p!5|bob")?.nudged).toBe(false);
  });

  it("is forgotten with the Teams baseline, so switching Teams on later announces nothing", () => {
    const store = openStore(":memory:");
    store.applyTeamsPlan(ledger, NOW);
    store.resetTeamsBaseline();
    const state = store.loadTeams();
    expect(state.rereviewMrs.size).toBe(0);
    expect(state.rereviewReviewers.size).toBe(0);
  });

  it("is added to a schema 7 database in place, keeping the outbox", () => {
    const path = tempDb();
    const first = openStore(path);
    first.applyTeamsPlan(teamsPlan({ intents: [intent(1)] }), NOW);
    first.close();
    const raw = new DatabaseSync(path);
    raw.exec("DROP TABLE rereview_mr; DROP TABLE rereview_reviewer; PRAGMA user_version = 7;");
    raw.close();

    const store = openStore(path);
    expect(store.listOutbox(["queued"])).toHaveLength(1);
    store.applyTeamsPlan(ledger, NOW);
    expect(store.loadTeams().rereviewMrs.size).toBe(1);
    store.close();
    const check = new DatabaseSync(path);
    expect(check.prepare("PRAGMA user_version").get()?.["user_version"]).toBe(20);
    check.close();
  });

  it("stores a Re-review Nudge in the outbox like any other message", () => {
    const store = openStore(":memory:");
    store.applyTeamsPlan(
      teamsPlan({
        intents: [
          intent(1, { dedupeKey: "rereview:g/p!5|bob:h2", kind: "rereview", variant: "rereview" }),
        ],
      }),
      NOW,
    );
    expect(store.listOutbox(["queued"])[0]).toMatchObject({
      kind: "rereview",
      variant: "rereview",
    });
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

describe("clearing outbox rows", () => {
  /** One row per status in `statuses`, in order; their ids. */
  function rows(
    store: ReturnType<typeof openStore>,
    path: readonly (readonly [
      "queued" | "pending" | "sending" | "sent" | "skipped" | "failed",
      string?,
    ])[],
  ): number[] {
    store.applyTeamsPlan(
      teamsPlan({
        intents: path.map(([, kind], slot) =>
          kind === "notice"
            ? intent(slot, {
                dedupeKey: `notice:${slot}`,
                kind: "notice",
                variant: "notice.approved",
              })
            : intent(slot),
        ),
      }),
      NOW,
    );
    const ids = store.listOutbox(["queued"]).map((row) => row.id);
    path.forEach(([status], index) => {
      const id = ids[index] ?? 0;
      if (status === "queued") return;
      store.transitionOutbox(id, "queued", "pending", { text: "halo" }, NOW);
      if (status !== "pending") store.transitionOutbox(id, "pending", status, {}, NOW);
    });
    return ids;
  }
  const all = ["queued", "pending", "sent", "skipped", "failed"] as const;

  it("clears one finished row from the hidden-cleared list and keeps it for everything else", () => {
    const store = openStore(":memory:");
    const [, pending, sent, , failed] = rows(store, [
      ["queued"],
      ["pending"],
      ["sent"],
      ["skipped"],
      ["failed"],
    ]);
    expect(store.clearOutbox(sent ?? 0, NOW + 1)).toBe(true);
    expect(store.clearOutbox(sent ?? 0, NOW + 2)).toBe(false);
    expect(store.clearOutbox(failed ?? 0, NOW + 1)).toBe(true);
    // A message still on its way cannot be cleared.
    expect(store.clearOutbox(pending ?? 0, NOW + 1)).toBe(false);
    expect(store.listOutbox(all, { hideCleared: true }).map((row) => row.status)).toEqual([
      "queued",
      "pending",
      "skipped",
    ]);
    expect(store.listOutbox(all)).toHaveLength(5);
  });

  it("clears a row stuck in sending, and prunes it 90 days after it got stuck", () => {
    const store = openStore(":memory:");
    const [stuck] = rows(store, [["sending"], ["sending"]]);
    expect(store.clearOutbox(stuck ?? 0, NOW + 1)).toBe(true);
    expect(store.listOutbox(["sending"], { hideCleared: true })).toHaveLength(1);
    store.applyTeamsPlan(teamsPlan(), NOW + 91 * DAY);
    // The cleared one is gone; the other is still nobody's call but the Owner's.
    expect(store.listOutbox(["sending"]).map((row) => row.id)).not.toContain(stuck);
    expect(store.listOutbox(["sending"])).toHaveLength(1);
  });

  it("clears the Recent rows of the given kinds, never a failed or open one", () => {
    const store = openStore(":memory:");
    rows(store, [["sent"], ["skipped"], ["failed"], ["pending"], ["sent", "notice"]]);
    expect(store.clearRecentOutbox(["nudge"], NOW + 1)).toBe(2);
    expect(store.clearRecentOutbox(["nudge"], NOW + 2)).toBe(0);
    expect(store.clearRecentOutbox([], NOW + 2)).toBe(0);
    expect(
      store.listOutbox(all, { hideCleared: true }).map((row) => [row.kind, row.status]),
    ).toEqual([
      ["nudge", "failed"],
      ["nudge", "pending"],
      ["notice", "sent"],
    ]);
  });

  it("adds the cleared column to a schema 18 database", () => {
    const path = tempDb();
    openStore(path).close();
    const raw = new DatabaseSync(path);
    raw.exec("ALTER TABLE outbox DROP COLUMN cleared_at; PRAGMA user_version = 18;");
    raw.close();
    const store = openStore(path);
    const [sent] = rows(store, [["sent"]]);
    expect(store.clearOutbox(sent ?? 0, NOW)).toBe(true);
    store.close();
  });
});

describe("nudge delivery in the ledger", () => {
  const nudgeUpdates = [{ key: "g/p!5|bob", record: { sentCount: 1, lastSentAt: NOW } }];

  it("reports a nudge as undelivered until its outbox row is sent", () => {
    const store = openStore(":memory:");
    store.applyTeamsPlan(
      teamsPlan({ intents: [intent(1)], nudgeUpdates, keepNudges: ["g/p!5|bob"] }),
      NOW,
    );
    const id = store.listOutbox(["queued"])[0]?.id ?? 0;
    for (const status of [
      "queued",
      "pending",
      "sending",
      "skipped",
      "failed",
      "unresolved",
    ] as const) {
      store.transitionOutbox(id, store.getOutbox(id)?.status ?? "queued", status, {}, NOW);
      expect([...store.loadTeams().undelivered]).toEqual(["g/p!5|bob"]);
    }
  });

  it("uses the delivery time, not the queue time, as the time the nudge was sent", () => {
    const store = openStore(":memory:");
    store.applyTeamsPlan(
      teamsPlan({ intents: [intent(1)], nudgeUpdates, keepNudges: ["g/p!5|bob"] }),
      NOW,
    );
    const id = store.listOutbox(["queued"])[0]?.id ?? 0;
    store.transitionOutbox(id, "queued", "sent", {}, NOW + 3 * DAY);
    const state = store.loadTeams();
    expect(state.undelivered.size).toBe(0);
    expect(state.nudges.get("g/p!5|bob")).toEqual({ sentCount: 1, lastSentAt: NOW + 3 * DAY });
  });
});

describe("resetTeamsBaseline", () => {
  it("forgets the review rounds and the baseline but keeps nudges and the outbox", () => {
    const store = openStore(":memory:");
    store.applyTeamsPlan(
      teamsPlan({
        intents: [intent(1)],
        nudgeUpdates: [{ key: "g/p!5|bob", record: { sentCount: 1, lastSentAt: NOW } }],
        roundUpdates: [{ mrKey: "g/p!7", round }],
        keepNudges: ["g/p!5|bob"],
        keepRounds: ["g/p!7"],
      }),
      NOW,
    );
    store.resetTeamsBaseline();
    const state = store.loadTeams();
    expect(state.baselineDone).toBe(false);
    expect(state.rounds.size).toBe(0);
    expect(state.nudges.size).toBe(1);
    expect(store.listOutbox(["queued"])).toHaveLength(1);
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

describe("findings notices (schema 9)", () => {
  const BODY = "## Findings\n1. `a.ts:1` — x";

  function postReview(store: ReturnType<typeof openStore>, mrKey: string, at: number): number {
    const id = store.queueAgentReview(mrKey, "auto", at) ?? 0;
    store.transitionAgentReview(id, ["queued"], "running", {}, at);
    store.transitionAgentReview(id, ["running"], "ready", { body: BODY }, at);
    store.transitionAgentReview(id, ["ready"], "posted", {}, at + 1);
    return id;
  }

  it("loads the latest posted review of each MR, with when it was posted", () => {
    const store = openStore(":memory:");
    postReview(store, "g/p!7", NOW);
    const latest = postReview(store, "g/p!7", NOW + 10);
    // A newer review still waiting for the Owner is not posted yet.
    store.queueAgentReview("g/p!7", "manual", NOW + 20);
    expect(store.loadTeams().postedReviews).toEqual(
      new Map([
        ["g/p!7", { id: latest, postedAt: NOW + 11, body: BODY, rereview: false, approved: false }],
      ]),
    );
  });

  it("loadTeams marks a posted review with a previousSha as a re-review", () => {
    const store = openStore(":memory:");
    const first = postReview(store, "g/p!7", NOW);
    expect(store.loadTeams().postedReviews.get("g/p!7")).toMatchObject({
      id: first,
      rereview: false,
    });
    const id = store.queueAgentReview("g/p!7", "auto", NOW + 10) ?? 0;
    store.transitionAgentReview(id, ["queued"], "running", { previousSha: "aaa1111" }, NOW + 10);
    store.transitionAgentReview(id, ["running"], "ready", { body: BODY }, NOW + 10);
    store.transitionAgentReview(id, ["ready"], "posted", {}, NOW + 11);
    expect(store.loadTeams().postedReviews.get("g/p!7")).toMatchObject({ id, rereview: true });
  });

  it("loadTeams says whether the agent approved after the posted review", () => {
    const store = openStore(":memory:");
    const id = postReview(store, "g/p!7", NOW);
    expect(store.loadTeams().postedReviews.get("g/p!7")?.approved).toBe(false);
    store.transitionAgentReview(id, ["posted"], "posted", { approved: true }, NOW + 1);
    expect(store.loadTeams().postedReviews.get("g/p!7")?.approved).toBe(true);
  });

  it("keeps the announced review in the round and the findings text in the outbox", () => {
    const store = openStore(":memory:");
    store.applyTeamsPlan(
      teamsPlan({
        intents: [
          intent(1, {
            dedupeKey: "findings:4",
            kind: "notice",
            variant: "notice.findings",
            findings: "ada 1 finding",
          }),
          intent(2),
        ],
        roundUpdates: [{ mrKey: "g/p!7", round: { ...round, announcedReview: 4 } }],
        keepRounds: ["g/p!7"],
      }),
      NOW,
    );
    expect(store.loadTeams().rounds.get("g/p!7")?.announcedReview).toBe(4);
    expect(store.listOutbox(["queued"]).map((row) => row.findings)).toEqual([
      "ada 1 finding",
      null,
    ]);
  });

  it("upgrades a schema 8 database and counts reviews posted before it as announced", () => {
    const path = tempDb();
    const first = openStore(path);
    const posted = postReview(first, "g/p!7", NOW);
    first.applyTeamsPlan(
      teamsPlan({
        intents: [intent(1)],
        roundUpdates: [
          { mrKey: "g/p!7", round },
          { mrKey: "g/p!8", round },
        ],
        keepRounds: ["g/p!7", "g/p!8"],
      }),
      NOW,
    );
    first.close();
    const raw = new DatabaseSync(path);
    raw.exec(
      "ALTER TABLE review_round DROP COLUMN announced_review; ALTER TABLE outbox DROP COLUMN findings; PRAGMA user_version = 8;",
    );
    raw.close();

    const store = openStore(path);
    const rounds = store.loadTeams().rounds;
    expect(rounds.get("g/p!7")?.announcedReview).toBe(posted);
    expect(rounds.get("g/p!8")?.announcedReview).toBeNull();
    expect(store.listOutbox(["queued"])[0]?.findings).toBeNull();
    store.close();
  });
});
