import { describe, expect, it } from "vitest";
import type { MergeRequest } from "../src/domain.ts";
import { reviewerKey } from "../src/events.ts";
import { planTeams } from "../src/teams/plan.ts";
import type { PlanConfig } from "../src/teams/plan.ts";
import type { PostedReview, Round, TeamsState } from "../src/teams/types.ts";
import { ME, mr, note, person, previous, reviewer, snapshot } from "./builders.ts";
import { NOW, teamsState } from "./teams-builders.ts";

const HOUR = 3_600_000;
const MINUTE = 60_000;
const config: PlanConfig = {
  maxMessagesPerReviewer: 2,
  reminderAfterMs: 24 * HOUR,
  noticeDebounceMs: 10 * MINUTE,
  rereviewAfterMs: 10 * MINUTE,
};

function plan(input: {
  snapshot: ReturnType<typeof snapshot>;
  previous?: ReturnType<typeof previous>;
  state?: TeamsState;
  now?: number;
}) {
  return planTeams({
    snapshot: input.snapshot,
    previous: input.previous ?? previous(),
    state: input.state ?? teamsState(),
    now: input.now ?? NOW,
    config,
  });
}

const BOB = reviewerKey("g/p!5", "bob");
const own = (overrides: Partial<MergeRequest> = {}): MergeRequest =>
  mr(5, { author: ME, reviewers: [reviewer("bob", "UNREVIEWED", "Bob")], ...overrides });
const known = (state: string) =>
  previous({
    trackedAuthored: new Set(["g/p!5"]),
    reviewerStates: new Map([[BOB, state]]),
  });

describe("reviewer nudges (flow B)", () => {
  it("nudges a Reviewer who was added to a tracked MR, and only that Reviewer", () => {
    const current = snapshot({
      authored: [
        own({ reviewers: [reviewer("carol", "UNREVIEWED"), reviewer("bob", "UNREVIEWED", "Bob")] }),
      ],
    });
    const before = previous({
      trackedAuthored: new Set(["g/p!5"]),
      reviewerStates: new Map([[reviewerKey("g/p!5", "carol"), "UNREVIEWED"]]),
    });
    const result = plan({ snapshot: current, previous: before });
    expect(result.intents).toEqual([
      {
        dedupeKey: "nudge:g/p!5|bob:1",
        kind: "nudge",
        variant: "nudge",
        mr: {
          key: "g/p!5",
          iid: 5,
          projectPath: "g/p",
          title: "MR 5",
          url: "https://gitlab.example/g/p/-/merge_requests/5",
        },
        recipient: { username: "bob", name: "Bob" },
      },
    ]);
    expect(result.nudgeUpdates).toEqual([{ key: BOB, record: { sentCount: 1, lastSentAt: NOW } }]);
  });

  it("nudges every Reviewer of a brand-new MR", () => {
    const current = snapshot({
      authored: [
        own({ reviewers: [reviewer("bob", "UNREVIEWED"), reviewer("carol", "UNREVIEWED")] }),
      ],
    });
    expect(plan({ snapshot: current }).intents.map((i) => i.recipient.username)).toEqual([
      "bob",
      "carol",
    ]);
  });

  it("does not nudge Reviewers that were already there before", () => {
    expect(
      plan({ snapshot: snapshot({ authored: [own()] }), previous: known("UNREVIEWED") }).intents,
    ).toEqual([]);
  });

  it("does not nudge a Reviewer who has already reviewed", () => {
    const current = snapshot({ authored: [own({ reviewers: [reviewer("bob", "APPROVED")] })] });
    expect(plan({ snapshot: current }).intents).toEqual([]);
  });

  it("ignores draft MRs and the Owner as a Reviewer", () => {
    const draft = snapshot({ authored: [own({ draft: true })] });
    expect(plan({ snapshot: draft }).intents).toEqual([]);
    const self = snapshot({ authored: [own({ reviewers: [reviewer("me", "UNREVIEWED")] })] });
    expect(plan({ snapshot: self }).intents).toEqual([]);
  });

  it("nudges again on a re-request, but never beyond the cap", () => {
    const current = snapshot({ authored: [own()] });
    const oneSent = teamsState({
      nudges: new Map([[BOB, { sentCount: 1, lastSentAt: NOW - HOUR }]]),
    });
    const again = plan({ snapshot: current, previous: known("APPROVED"), state: oneSent });
    expect(again.intents.map((i) => [i.dedupeKey, i.kind])).toEqual([
      ["nudge:g/p!5|bob:2", "nudge"],
    ]);
    const twoSent = teamsState({
      nudges: new Map([[BOB, { sentCount: 2, lastSentAt: NOW - HOUR }]]),
    });
    expect(
      plan({ snapshot: current, previous: known("APPROVED"), state: twoSent }).intents,
    ).toEqual([]);
  });

  it("reminds once, 24 hours after the nudge, while the Reviewer is still UNREVIEWED", () => {
    const current = snapshot({ authored: [own()] });
    const sentAt = (age: number, count = 1) =>
      teamsState({ nudges: new Map([[BOB, { sentCount: count, lastSentAt: NOW - age }]]) });
    const due = plan({
      snapshot: current,
      previous: known("UNREVIEWED"),
      state: sentAt(24 * HOUR),
    });
    expect(due.intents.map((i) => [i.dedupeKey, i.kind, i.variant])).toEqual([
      ["nudge:g/p!5|bob:2", "reminder", "reminder"],
    ]);
    expect(due.nudgeUpdates).toEqual([{ key: BOB, record: { sentCount: 2, lastSentAt: NOW } }]);
    expect(
      plan({ snapshot: current, previous: known("UNREVIEWED"), state: sentAt(24 * HOUR - MINUTE) })
        .intents,
    ).toEqual([]);
    expect(
      plan({ snapshot: current, previous: known("UNREVIEWED"), state: sentAt(48 * HOUR, 2) })
        .intents,
    ).toEqual([]);
  });

  it("does not remind while the nudge itself has not been delivered", () => {
    const current = snapshot({ authored: [own()] });
    const state = teamsState({
      nudges: new Map([[BOB, { sentCount: 1, lastSentAt: NOW - 30 * HOUR }]]),
      undelivered: new Set([BOB]),
    });
    expect(plan({ snapshot: current, previous: known("UNREVIEWED"), state }).intents).toEqual([]);
  });

  it("does not remind a Reviewer who reviewed in the meantime", () => {
    const current = snapshot({ authored: [own({ reviewers: [reviewer("bob", "APPROVED")] })] });
    const state = teamsState({
      nudges: new Map([[BOB, { sentCount: 1, lastSentAt: NOW - 30 * HOUR }]]),
    });
    expect(plan({ snapshot: current, previous: known("UNREVIEWED"), state }).intents).toEqual([]);
  });

  it("keeps the ledger rows of Reviewers on open non-draft MRs only, never the Owner", () => {
    const current = snapshot({
      authored: [
        own({ reviewers: [reviewer("bob", "APPROVED"), reviewer("me", "UNREVIEWED")] }),
        mr(6, { author: ME, draft: true, reviewers: [reviewer("dave", "UNREVIEWED")] }),
      ],
    });
    expect(plan({ snapshot: current }).keepNudges).toEqual([BOB]);
  });
});

describe("review notices (flow C)", () => {
  const KEY = "g/p!7";
  const theirs = (state: string, notes: MergeRequest["notes"] = []): MergeRequest =>
    mr(7, { author: person("alice", "Alice"), reviewers: [reviewer("me", state)], notes });
  const round = (overrides: Partial<Round> = {}): Round => ({
    myState: "UNREVIEWED",
    myNotes: 0,
    changedAt: NOW - HOUR,
    noticedState: "UNREVIEWED",
    noticedNotes: 0,
    announcedReview: null,
    ...overrides,
  });
  const withRound = (value: Round, posted?: PostedReview) =>
    teamsState({
      rounds: new Map([[KEY, value]]),
      postedReviews: new Map(posted === undefined ? [] : [[KEY, posted]]),
    });
  const REVIEW_BODY = "## Findings\n### Minor\n1. `a.ts:1` — x\n2. `b.ts` — y\n### Nit\n3. z";
  const posted = (id: number, postedAt = NOW - MINUTE): PostedReview => ({
    id,
    postedAt,
    body: REVIEW_BODY,
    rereview: false,
    approved: false,
  });

  it("records the first sighting without any notice", () => {
    const result = plan({ snapshot: snapshot({ reviewRequested: [theirs("UNREVIEWED")] }) });
    expect(result.intents).toEqual([]);
    expect(result.roundUpdates).toEqual([{ mrKey: KEY, round: round({ changedAt: NOW }) }]);
    expect(result.keepRounds).toEqual([KEY]);
  });

  it("restarts the debounce when the Owner's review changes, and notices comments only after it", () => {
    const current = snapshot({ reviewRequested: [theirs("UNREVIEWED", [note("a", ME)])] });
    const changed = plan({ snapshot: current, state: withRound(round()) });
    expect(changed.intents).toEqual([]);
    expect(changed.roundUpdates).toEqual([
      { mrKey: KEY, round: round({ myNotes: 1, changedAt: NOW }) },
    ]);
    const settled = plan({
      snapshot: current,
      state: withRound(round({ myNotes: 1, changedAt: NOW - 11 * MINUTE })),
    });
    expect(settled.intents.map((i) => i.variant)).toEqual(["notice.comments"]);
  });

  it("notices an approval at the first poll that sees it, without the debounce, once", () => {
    const current = snapshot({ reviewRequested: [theirs("APPROVED")] });
    const settled = plan({ snapshot: current, state: withRound(round()) });
    expect(settled.intents).toEqual([
      {
        dedupeKey: "notice:g/p!7:APPROVED:0",
        kind: "notice",
        variant: "notice.approved",
        mr: {
          key: KEY,
          iid: 7,
          projectPath: "g/p",
          title: "MR 7",
          url: "https://gitlab.example/g/p/-/merge_requests/7",
        },
        recipient: { username: "alice", name: "Alice" },
      },
    ]);
    expect(settled.roundUpdates).toEqual([
      {
        mrKey: KEY,
        round: round({
          myState: "APPROVED",
          changedAt: NOW,
          noticedState: "APPROVED",
        }),
      },
    ]);
  });

  it("uses the 'changes' variant and the 'comments' variant", () => {
    const changes = plan({
      snapshot: snapshot({ reviewRequested: [theirs("REQUESTED_CHANGES")] }),
      state: withRound(round({ myState: "REQUESTED_CHANGES", changedAt: NOW - 11 * MINUTE })),
    });
    expect(changes.intents.map((i) => i.variant)).toEqual(["notice.changes"]);

    const comments = plan({
      snapshot: snapshot({ reviewRequested: [theirs("UNREVIEWED", [note("n1", ME)])] }),
      state: withRound(round({ myNotes: 1, changedAt: NOW - 11 * MINUTE })),
    });
    expect(comments.intents.map((i) => [i.variant, i.dedupeKey])).toEqual([
      ["notice.comments", "notice:g/p!7:UNREVIEWED:1"],
    ]);
  });

  it("counts only the Owner's own human notes", () => {
    const others = [note("a", person("alice")), note("b", ME, true)];
    const result = plan({
      snapshot: snapshot({ reviewRequested: [theirs("UNREVIEWED", others)] }),
      state: withRound(round({ changedAt: NOW - 11 * MINUTE })),
    });
    expect(result.intents).toEqual([]);
  });

  it("does not announce the same activity twice", () => {
    const result = plan({
      snapshot: snapshot({ reviewRequested: [theirs("APPROVED")] }),
      state: withRound(
        round({ myState: "APPROVED", noticedState: "APPROVED", changedAt: NOW - 11 * MINUTE }),
      ),
    });
    expect(result.intents).toEqual([]);
    expect(result.roundUpdates).toEqual([]);
  });

  it("starts a new round on a re-request without announcing the old comments", () => {
    const result = plan({
      snapshot: snapshot({
        reviewRequested: [theirs("UNREVIEWED", [note("a", ME), note("b", ME)])],
      }),
      state: withRound(
        round({ myState: "APPROVED", myNotes: 2, noticedState: "APPROVED", noticedNotes: 2 }),
      ),
    });
    expect(result.intents).toEqual([]);
    expect(result.roundUpdates).toEqual([
      {
        mrKey: KEY,
        round: round({ myState: "UNREVIEWED", myNotes: 2, noticedNotes: 2, changedAt: NOW }),
      },
    ]);
  });

  it("seeds a new round with the Agent Review already posted, so it is never announced", () => {
    const result = plan({
      snapshot: snapshot({ reviewRequested: [theirs("UNREVIEWED", [note("a", ME)])] }),
      state: teamsState({ postedReviews: new Map([[KEY, posted(4)]]) }),
    });
    expect(result.intents).toEqual([]);
    expect(result.roundUpdates).toEqual([
      { mrKey: KEY, round: round({ myNotes: 1, changedAt: NOW, announcedReview: 4 }) },
    ]);
  });

  it("announces a posted Agent Review's findings as soon as its comments show, without debounce", () => {
    const result = plan({
      snapshot: snapshot({
        reviewRequested: [theirs("UNREVIEWED", [note("a", ME), note("b", ME)])],
      }),
      state: withRound(round({ announcedReview: 3 }), posted(4)),
    });
    expect(result.intents).toEqual([
      {
        dedupeKey: "findings:4",
        kind: "notice",
        variant: "notice.findings",
        mr: {
          key: KEY,
          iid: 7,
          projectPath: "g/p",
          title: "MR 7",
          url: "https://gitlab.example/g/p/-/merge_requests/7",
        },
        recipient: { username: "alice", name: "Alice" },
        findings: "ada 3 findings (2 Minor, 1 Nit)",
      },
    ]);
    // The comments are announced with it, so no plain 'comments' notice follows.
    expect(result.roundUpdates).toEqual([
      {
        mrKey: KEY,
        round: round({ myNotes: 2, changedAt: NOW, noticedNotes: 2, announcedReview: 4 }),
      },
    ]);
  });

  it("announces a posted re-review as notice.refindings with its new findings, once", () => {
    const state = withRound(round({ announcedReview: 3 }), { ...posted(4), rereview: true });
    const current = snapshot({
      reviewRequested: [theirs("UNREVIEWED", [note("a", ME), note("b", ME)])],
    });
    const result = plan({ snapshot: current, state });
    expect(result.intents).toEqual([
      {
        dedupeKey: "findings:4",
        kind: "notice",
        variant: "notice.refindings",
        mr: {
          key: KEY,
          iid: 7,
          projectPath: "g/p",
          title: "MR 7",
          url: "https://gitlab.example/g/p/-/merge_requests/7",
        },
        recipient: { username: "alice", name: "Alice" },
        findings: "ada 3 findings baru (2 Minor, 1 Nit)",
      },
    ]);
    const [update] = result.roundUpdates;
    expect(update?.round).toEqual(
      round({ myNotes: 2, changedAt: NOW, noticedNotes: 2, announcedReview: 4 }),
    );
    const next = plan({
      snapshot: current,
      state: { ...state, rounds: new Map([[KEY, update!.round]]) },
    });
    expect(next.intents).toEqual([]);
  });

  it("waits for the comments to show, but not longer than the notice debounce", () => {
    const current = snapshot({ reviewRequested: [theirs("UNREVIEWED")] });
    const early = plan({ snapshot: current, state: withRound(round(), posted(4)) });
    expect(early.intents).toEqual([]);

    const late = plan({
      snapshot: current,
      state: withRound(round(), posted(4, NOW - 11 * MINUTE)),
    });
    expect(late.intents.map((i) => i.dedupeKey)).toEqual(["findings:4"]);
  });

  it("announces an approved re-review as notice.reapproved and counts the approval as noticed", () => {
    const state = withRound(round({ announcedReview: 3 }), {
      ...posted(4),
      body: "## Previous review\n- fixed\n## Findings\nNone.",
      rereview: true,
      approved: true,
    });
    const current = snapshot({
      reviewRequested: [theirs("APPROVED", [note("a", ME), note("b", ME)])],
    });
    const result = plan({ snapshot: current, state });
    expect(result.intents.map((i) => [i.variant, i.findings])).toEqual([
      ["notice.reapproved", "tidak ada findings baru"],
    ]);
    const [update] = result.roundUpdates;
    expect(update?.round).toEqual(
      round({
        myState: "APPROVED",
        myNotes: 2,
        changedAt: NOW,
        noticedState: "APPROVED",
        noticedNotes: 2,
        announcedReview: 4,
      }),
    );
    const later = plan({
      snapshot: current,
      state: { ...state, rounds: new Map([[KEY, update!.round]]) },
      now: NOW + 11 * MINUTE,
    });
    expect(later.intents).toEqual([]);
  });

  it("announces an approved first review with its findings, then the approval", () => {
    const state = withRound(round(), {
      ...posted(4),
      body: "## Findings\n### Minor\n1. `a.ts:1` naming.",
      approved: true,
    });
    const current = snapshot({
      reviewRequested: [theirs("APPROVED", [note("a", ME), note("b", ME)])],
    });
    const result = plan({ snapshot: current, state });
    expect(result.intents.map((i) => i.variant)).toEqual(["notice.findings", "notice.approved"]);
  });

  it("announces each Agent Review once and still notices a later approval", () => {
    const result = plan({
      snapshot: snapshot({ reviewRequested: [theirs("APPROVED", [note("a", ME)])] }),
      state: withRound(
        round({
          myState: "APPROVED",
          myNotes: 1,
          noticedNotes: 1,
          changedAt: NOW - 11 * MINUTE,
          announcedReview: 4,
        }),
        posted(4),
      ),
    });
    expect(result.intents.map((i) => i.variant)).toEqual(["notice.approved"]);
  });

  it("does not announce findings before the Teams baseline", () => {
    const result = plan({
      snapshot: snapshot({ reviewRequested: [theirs("UNREVIEWED", [note("a", ME)])] }),
      state: { ...withRound(round(), posted(4)), baselineDone: false },
    });
    expect(result.intents).toEqual([]);
  });

  it("ignores draft MRs", () => {
    const draft = mr(7, { draft: true, reviewers: [reviewer("me", "APPROVED")] });
    const result = plan({ snapshot: snapshot({ reviewRequested: [draft] }) });
    expect(result.roundUpdates).toEqual([]);
    expect(result.keepRounds).toEqual([]);
  });
});

describe("Teams baseline", () => {
  it("queues nothing and seeds the rounds with what already exists (upgrade from Plan 1)", () => {
    const current = snapshot({
      authored: [own()],
      reviewRequested: [
        mr(7, {
          author: person("alice", "Alice"),
          reviewers: [reviewer("me", "APPROVED")],
          notes: [note("n1", ME)],
        }),
      ],
    });
    // Plan 1 finished its baseline long ago; Teams has just been switched on.
    const first = plan({
      snapshot: current,
      previous: previous({ baselineDone: true }),
      state: teamsState({ baselineDone: false }),
    });
    expect(first.intents).toEqual([]);
    expect(first.baselineDone).toBe(true);
    expect(first.roundUpdates).toEqual([
      {
        mrKey: "g/p!7",
        round: {
          myState: "APPROVED",
          myNotes: 1,
          changedAt: NOW,
          noticedState: "APPROVED",
          noticedNotes: 1,
          announcedReview: null,
        },
      },
    ]);

    // On the next poll the seeded round is in the ledger and still produces nothing.
    const seeded = new Map(
      first.roundUpdates.map((update) => [update.mrKey, update.round] as const),
    );
    const second = plan({
      snapshot: current,
      previous: known("UNREVIEWED"),
      state: teamsState({ rounds: seeded }),
      now: NOW + HOUR,
    });
    expect(second.intents).toEqual([]);
  });

  it("queues nothing while the Plan 1 baseline itself is still pending", () => {
    const current = snapshot({ authored: [own()] });
    const result = plan({ snapshot: current, previous: previous({ baselineDone: false }) });
    expect(result.intents).toEqual([]);
  });
});
