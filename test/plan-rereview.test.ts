import { describe, expect, it } from "vitest";
import type { MergeRequest, Note, Snapshot } from "../src/domain.ts";
import { reviewerKey } from "../src/events.ts";
import { planTeams } from "../src/teams/plan.ts";
import type { PlanConfig } from "../src/teams/plan.ts";
import type { NudgeRecord, TeamsPlan, TeamsState } from "../src/teams/types.ts";
import { ME, mr, note, person, previous, reviewer, snapshot } from "./builders.ts";
import { NOW, teamsState } from "./teams-builders.ts";

const MINUTE = 60_000;
const HOUR = 3_600_000;
const config: PlanConfig = {
  maxMessagesPerReviewer: 2,
  reminderAfterMs: 24 * HOUR,
  noticeDebounceMs: 10 * MINUTE,
  rereviewAfterMs: 10 * MINUTE,
};

const KEY = "g/p!5";
const BOB = reviewerKey(KEY, "bob");

interface Look {
  readonly head: string | null;
  readonly draft?: boolean;
  readonly reviewers: readonly { readonly name: string; readonly state: string }[];
  readonly notes?: readonly Note[];
}

/** The Owner's MR 5 as GitLab shows it at one poll. */
function own(look: Look): MergeRequest {
  return mr(5, {
    author: ME,
    headSha: look.head,
    draft: look.draft ?? false,
    reviewers: look.reviewers.map((each) => reviewer(each.name, each.state, each.name)),
    notes: look.notes ?? [],
  });
}

const bob = (state: string) => ({ name: "bob", state });
const bobsNote = (id: string): Note => note(id, person("bob", "bob"));

/**
 * Runs planTeams poll after poll the way the agent does: the ledger a plan returns is the state of
 * the next poll, and `previous` is what Plan 1 committed after the previous snapshot.
 */
function agent() {
  let state: TeamsState = teamsState({ baselineDone: false });
  let before = previous({ baselineDone: false });
  let now = NOW;
  return {
    get state() {
      return state;
    },
    /** `afterMinutes` pass, then the poll sees `mrs`. */
    poll(afterMinutes: number, ...mrs: MergeRequest[]): TeamsPlan {
      now += afterMinutes * MINUTE;
      const snap: Snapshot = snapshot({ authored: mrs });
      const plan = planTeams({ snapshot: snap, previous: before, state, now, config });
      const nudges = new Map<string, NudgeRecord>(state.nudges);
      for (const update of plan.nudgeUpdates) nudges.set(update.key, update.record);
      state = {
        ...state,
        baselineDone: plan.baselineDone,
        nudges,
        rereviewMrs: plan.rereviewMrs,
        rereviewReviewers: plan.rereviewReviewers,
      };
      const tracked = mrs.filter((each) => !each.draft);
      before = previous({
        baselineDone: true,
        trackedAuthored: new Set(tracked.map((each) => each.key)),
        reviewerStates: new Map(
          tracked.flatMap((each) =>
            each.reviewers.map((r) => [reviewerKey(each.key, r.username), r.state] as const),
          ),
        ),
      });
      return plan;
    },
  };
}

const kinds = (plan: TeamsPlan) =>
  plan.intents.map((intent) => `${intent.kind}:${intent.dedupeKey}`);

/** An agent that has seen the MR waiting on bob, and then bob approving it at head h1. */
function afterApproval() {
  const a = agent();
  a.poll(0, own({ head: "h1", reviewers: [bob("UNREVIEWED")] }));
  a.poll(2, own({ head: "h1", reviewers: [bob("APPROVED")] }));
  return a;
}

describe("Re-review Nudge: baseline", () => {
  it("records the head and the Reviewers and announces nothing when Suica first sees the MR", () => {
    const a = agent();
    const plan = a.poll(0, own({ head: "h1", reviewers: [bob("APPROVED")] }));
    expect(plan.intents).toEqual([]);
    expect(plan.rereviewMrs).toEqual(new Map([[KEY, { head: "h1", changedAt: NOW }]]));
    expect(plan.rereviewReviewers).toEqual(
      new Map([[BOB, { reviewedHead: "h1", state: "APPROVED", notes: 0, nudged: false }]]),
    );
  });

  it("never announces commits that were there before the first sighting", () => {
    const a = agent();
    a.poll(0, own({ head: "h2", reviewers: [bob("APPROVED")] }));
    for (const minutes of [2, 5, 30, 600]) {
      const plan = a.poll(minutes, own({ head: "h2", reviewers: [bob("APPROVED")] }));
      expect(plan.intents).toEqual([]);
    }
  });

  it("does not announce while the Teams baseline is not done, even when the ledger holds history", () => {
    const state = teamsState({
      baselineDone: false,
      rereviewMrs: new Map([[KEY, { head: "h1", changedAt: NOW - HOUR }]]),
      rereviewReviewers: new Map([
        [BOB, { reviewedHead: "h1", state: "APPROVED", notes: 0, nudged: false }],
      ]),
    });
    const plan = planTeams({
      snapshot: snapshot({ authored: [own({ head: "h2", reviewers: [bob("APPROVED")] })] }),
      previous: previous(),
      state,
      now: NOW,
      config,
    });
    expect(plan.intents).toEqual([]);
    expect(plan.rereviewReviewers.get(BOB)?.reviewedHead).toBe("h2");
  });

  it("records an MR that appears after the baseline without announcing it", () => {
    const a = agent();
    a.poll(0);
    a.poll(2, own({ head: "h1", reviewers: [bob("APPROVED")] }));
    expect(a.poll(30, own({ head: "h1", reviewers: [bob("APPROVED")] })).intents).toEqual([]);
  });

  it("records a Reviewer who appears on a known MR as already seen", () => {
    const a = agent();
    a.poll(0, own({ head: "h1", reviewers: [bob("UNREVIEWED")] }));
    const carol = { name: "carol", state: "APPROVED" };
    a.poll(2, own({ head: "h2", reviewers: [bob("UNREVIEWED"), carol] }));
    const plan = a.poll(30, own({ head: "h2", reviewers: [bob("UNREVIEWED"), carol] }));
    expect(plan.intents).toEqual([]);
    expect(plan.rereviewReviewers.get(reviewerKey(KEY, "carol"))?.reviewedHead).toBe("h2");
  });
});

describe("Re-review Nudge: when", () => {
  it("nudges an approver once the new head has stood for the debounce", () => {
    const a = afterApproval();
    expect(a.poll(2, own({ head: "h2", reviewers: [bob("APPROVED")] })).intents).toEqual([]);
    expect(a.poll(9, own({ head: "h2", reviewers: [bob("APPROVED")] })).intents).toEqual([]);
    const due = a.poll(1, own({ head: "h2", reviewers: [bob("APPROVED")] }));
    expect(due.intents).toEqual([
      {
        dedupeKey: `rereview:${BOB}:h2`,
        kind: "rereview",
        variant: "rereview",
        mr: {
          key: KEY,
          iid: 5,
          projectPath: "g/p",
          title: "MR 5",
          url: "https://gitlab.example/g/p/-/merge_requests/5",
        },
        recipient: { username: "bob", name: "bob" },
      },
    ]);
    expect(due.rereviewReviewers.get(BOB)).toMatchObject({ reviewedHead: "h1", nudged: true });
  });

  it("makes one nudge for several pushes in a row, counted from the last push", () => {
    const a = afterApproval();
    const seen: string[] = [];
    for (const [minutes, head] of [
      [2, "h2"],
      [6, "h3"],
      [6, "h4"],
      [6, "h4"],
      [3, "h4"],
      [30, "h4"],
    ] as const) {
      seen.push(...kinds(a.poll(minutes, own({ head, reviewers: [bob("APPROVED")] }))));
    }
    expect(seen).toEqual([`rereview:rereview:${BOB}:h4`]);
  });

  it("nudges a Reviewer who requested changes or only commented", () => {
    const requested = agent();
    requested.poll(0, own({ head: "h1", reviewers: [bob("UNREVIEWED")] }));
    requested.poll(2, own({ head: "h1", reviewers: [bob("REQUESTED_CHANGES")] }));
    requested.poll(2, own({ head: "h2", reviewers: [bob("REQUESTED_CHANGES")] }));
    expect(
      kinds(requested.poll(10, own({ head: "h2", reviewers: [bob("REQUESTED_CHANGES")] }))),
    ).toEqual([`rereview:rereview:${BOB}:h2`]);

    const commented = agent();
    const withNote = (head: string) =>
      own({ head, reviewers: [bob("UNREVIEWED")], notes: [bobsNote("n1")] });
    commented.poll(0, own({ head: "h1", reviewers: [bob("UNREVIEWED")] }));
    commented.poll(2, withNote("h1"));
    commented.poll(2, withNote("h2"));
    expect(kinds(commented.poll(10, withNote("h2")))).toEqual([`rereview:rereview:${BOB}:h2`]);
  });

  it("counts a Reviewer who had already commented when Suica first saw the MR", () => {
    const a = agent();
    const withNote = (head: string) =>
      own({ head, reviewers: [bob("UNREVIEWED")], notes: [bobsNote("n1")] });
    a.poll(0, withNote("h1"));
    a.poll(2, withNote("h2"));
    expect(kinds(a.poll(10, withNote("h2")))).toEqual([`rereview:rereview:${BOB}:h2`]);
  });

  it("does not nudge a Reviewer who never reviewed, nor count system notes or other people's notes", () => {
    const a = agent();
    const quiet = (head: string) =>
      own({
        head,
        reviewers: [bob("UNREVIEWED")],
        notes: [note("s1", person("bob", "bob"), true), note("c1", person("carol", "carol"))],
      });
    a.poll(0, quiet("h1"));
    a.poll(2, quiet("h2"));
    expect(a.poll(30, quiet("h2")).intents).toEqual([]);
  });

  it("never nudges the Owner", () => {
    const a = agent();
    const selfReviewed = (head: string) =>
      own({ head, reviewers: [{ name: "me", state: "APPROVED" }] });
    a.poll(0, selfReviewed("h1"));
    a.poll(2, selfReviewed("h2"));
    const plan = a.poll(30, selfReviewed("h2"));
    expect(plan.intents).toEqual([]);
    expect(plan.rereviewReviewers.size).toBe(0);
  });

  it("does not nudge a Reviewer who reviewed again after the push", () => {
    const a = afterApproval();
    a.poll(2, own({ head: "h2", reviewers: [bob("APPROVED")] }));
    a.poll(3, own({ head: "h2", reviewers: [bob("REQUESTED_CHANGES")] }));
    expect(a.poll(30, own({ head: "h2", reviewers: [bob("REQUESTED_CHANGES")] })).intents).toEqual(
      [],
    );
  });

  it("does not count against the messages allowed per Reviewer", () => {
    const state = teamsState({
      nudges: new Map([[BOB, { sentCount: 2, lastSentAt: NOW - 48 * HOUR }]]),
      rereviewMrs: new Map([[KEY, { head: "h2", changedAt: NOW - HOUR }]]),
      rereviewReviewers: new Map([
        [BOB, { reviewedHead: "h1", state: "APPROVED", notes: 0, nudged: false }],
      ]),
    });
    const plan = planTeams({
      snapshot: snapshot({ authored: [own({ head: "h2", reviewers: [bob("APPROVED")] })] }),
      previous: previous({ trackedAuthored: new Set([KEY]) }),
      state,
      now: NOW,
      config,
    });
    expect(plan.intents.map((intent) => intent.kind)).toEqual(["rereview"]);
    expect(plan.nudgeUpdates).toEqual([]);
  });
});

describe("Re-review Nudge: one per round", () => {
  it("sends no second nudge until the Reviewer reviews again, then one for the next push", () => {
    const a = afterApproval();
    a.poll(2, own({ head: "h2", reviewers: [bob("APPROVED")] }));
    expect(kinds(a.poll(10, own({ head: "h2", reviewers: [bob("APPROVED")] })))).toEqual([
      `rereview:rereview:${BOB}:h2`,
    ]);
    // More polls and another push, but bob has not looked again.
    expect(a.poll(10, own({ head: "h2", reviewers: [bob("APPROVED")] })).intents).toEqual([]);
    a.poll(2, own({ head: "h3", reviewers: [bob("APPROVED")] }));
    expect(a.poll(30, own({ head: "h3", reviewers: [bob("APPROVED")] })).intents).toEqual([]);
    // Bob reviews again; the next push is a new round.
    a.poll(2, own({ head: "h3", reviewers: [bob("REQUESTED_CHANGES")] }));
    a.poll(2, own({ head: "h4", reviewers: [bob("REQUESTED_CHANGES")] }));
    expect(kinds(a.poll(10, own({ head: "h4", reviewers: [bob("REQUESTED_CHANGES")] })))).toEqual([
      `rereview:rereview:${BOB}:h4`,
    ]);
  });

  it("treats a new note as reviewing again", () => {
    const a = afterApproval();
    a.poll(2, own({ head: "h2", reviewers: [bob("APPROVED")] }));
    a.poll(10, own({ head: "h2", reviewers: [bob("APPROVED")] }));
    const noted = (head: string) =>
      own({ head, reviewers: [bob("APPROVED")], notes: [bobsNote("n1")] });
    a.poll(2, noted("h2"));
    a.poll(2, noted("h3"));
    expect(kinds(a.poll(10, noted("h3")))).toEqual([`rereview:rereview:${BOB}:h3`]);
  });

  it("does not treat a reset to UNAPPROVED or UNREVIEWED as reviewing again", () => {
    const a = afterApproval();
    a.poll(2, own({ head: "h2", reviewers: [bob("APPROVED")] }));
    a.poll(10, own({ head: "h2", reviewers: [bob("APPROVED")] }));
    a.poll(2, own({ head: "h2", reviewers: [bob("UNAPPROVED")] }));
    a.poll(2, own({ head: "h3", reviewers: [bob("UNAPPROVED")] }));
    expect(a.poll(30, own({ head: "h3", reviewers: [bob("UNAPPROVED")] })).intents).toEqual([]);
  });
});

describe("Re-review Nudge: a reset by GitLab's push and a re-request", () => {
  it("nudges again, and not with the plain Reviewer Nudge, when the push resets the approval", () => {
    const a = afterApproval();
    const reset = a.poll(2, own({ head: "h2", reviewers: [bob("UNREVIEWED")] }));
    expect(reset.intents).toEqual([]);
    expect(reset.nudgeUpdates).toEqual([]);
    expect(kinds(a.poll(10, own({ head: "h2", reviewers: [bob("UNREVIEWED")] })))).toEqual([
      `rereview:rereview:${BOB}:h2`,
    ]);
  });

  it("still sends the plain nudge to a Reviewer who is added, even in the poll the head changed", () => {
    const a = agent();
    a.poll(0, own({ head: "h1", reviewers: [] }));
    const plan = a.poll(2, own({ head: "h2", reviewers: [bob("UNREVIEWED")] }));
    expect(kinds(plan)).toEqual([`nudge:nudge:${BOB}:1`]);
  });

  it("sends the plain nudge, and closes the round, when GitLab's re-request leaves the head alone", () => {
    const a = afterApproval();
    a.poll(2, own({ head: "h2", reviewers: [bob("APPROVED")] }));
    const reRequested = a.poll(2, own({ head: "h2", reviewers: [bob("UNREVIEWED")] }));
    expect(kinds(reRequested)).toEqual([`nudge:nudge:${BOB}:1`]);
    expect(reRequested.rereviewReviewers.get(BOB)).toMatchObject({
      reviewedHead: "h2",
      nudged: false,
    });
    expect(a.poll(30, own({ head: "h2", reviewers: [bob("UNREVIEWED")] })).intents).toEqual([]);
  });

  it("marks a waiting Re-review Nudge closed when the Owner re-requests the Reviewer", () => {
    const a = afterApproval();
    a.poll(2, own({ head: "h2", reviewers: [bob("APPROVED")] }));
    const queued = a.poll(10, own({ head: "h2", reviewers: [bob("APPROVED")] }));
    expect(queued.rereviewReviewers.get(BOB)?.nudged).toBe(true);
    const reRequested = a.poll(2, own({ head: "h2", reviewers: [bob("UNREVIEWED")] }));
    expect(reRequested.rereviewReviewers.get(BOB)?.nudged).toBe(false);
    expect(kinds(reRequested)).toEqual([`nudge:nudge:${BOB}:1`]);
  });
});

describe("Re-review Nudge: drafts", () => {
  const draft = (head: string, state = "APPROVED") =>
    own({ head, draft: true, reviewers: [bob(state)] });
  const ready = (head: string, state = "APPROVED") => own({ head, reviewers: [bob(state)] });

  it("keeps its rows and queues nothing while the MR is a draft", () => {
    const a = afterApproval();
    a.poll(2, draft("h2"));
    const plan = a.poll(120, draft("h2"));
    expect(plan.intents).toEqual([]);
    expect(plan.rereviewMrs.get(KEY)?.head).toBe("h2");
    expect(plan.rereviewReviewers.get(BOB)).toMatchObject({ reviewedHead: "h1", nudged: false });
  });

  it("nudges after the debounce once the MR is marked ready, as if the pushes had just happened", () => {
    const a = afterApproval();
    a.poll(2, draft("h2"));
    a.poll(120, draft("h2"));
    expect(a.poll(1, ready("h2")).intents).toEqual([]);
    expect(a.poll(9, ready("h2")).intents).toEqual([]);
    expect(kinds(a.poll(1, ready("h2")))).toEqual([`rereview:rereview:${BOB}:h2`]);
  });

  it("does not send the plain nudge too when a reset happened while the MR was a draft", () => {
    const a = afterApproval();
    a.poll(2, draft("h2", "UNREVIEWED"));
    const marked = a.poll(2, ready("h2", "UNREVIEWED"));
    expect(marked.intents).toEqual([]);
    expect(marked.nudgeUpdates).toEqual([]);
    expect(kinds(a.poll(10, ready("h2", "UNREVIEWED")))).toEqual([`rereview:rereview:${BOB}:h2`]);
  });
});

describe("Re-review Nudge: ledger upkeep", () => {
  it("drops the rows of an MR that left the open list and of a Reviewer who was removed", () => {
    const a = afterApproval();
    const both = own({
      head: "h1",
      reviewers: [bob("APPROVED"), { name: "carol", state: "APPROVED" }],
    });
    a.poll(2, both);
    expect([...a.state.rereviewReviewers.keys()].sort()).toEqual([BOB, reviewerKey(KEY, "carol")]);
    const removed = a.poll(2, own({ head: "h1", reviewers: [bob("APPROVED")] }));
    expect([...removed.rereviewReviewers.keys()]).toEqual([BOB]);
    expect([...removed.rereviewMrs.keys()]).toEqual([KEY]);
    const gone = a.poll(2);
    expect(gone.rereviewMrs.size).toBe(0);
    expect(gone.rereviewReviewers.size).toBe(0);
  });

  it("keeps what it knows, and decides nothing, while GitLab has no head for the MR", () => {
    const a = afterApproval();
    a.poll(2, own({ head: "h2", reviewers: [bob("APPROVED")] }));
    const before = a.state;
    const plan = a.poll(30, own({ head: null, reviewers: [bob("APPROVED")] }));
    expect(plan.intents).toEqual([]);
    expect(plan.rereviewMrs).toEqual(before.rereviewMrs);
    expect(plan.rereviewReviewers).toEqual(before.rereviewReviewers);
    expect(kinds(a.poll(0, own({ head: "h2", reviewers: [bob("APPROVED")] })))).toEqual([
      `rereview:rereview:${BOB}:h2`,
    ]);
  });
});
