import { describe, expect, it } from "vitest";
import type { ActivityEvent } from "../src/events.ts";
import { reviewerKey } from "../src/events.ts";
import { firstApprovals, historyEvents } from "../src/history.ts";
import { mr, note, person, previous, reviewer, snapshot } from "./builders.ts";

const AT = 5000;
const bob = person("bob");

describe("historyEvents", () => {
  it("records nothing before the baseline", () => {
    const request = mr(1, { reviewers: [reviewer("me", "UNREVIEWED")] });
    const events: ActivityEvent[] = [{ kind: "review-requested", mr: request }];
    const current = snapshot({ reviewRequested: [request] });
    expect(historyEvents(current, previous({ baselineDone: false }), events, AT)).toEqual([]);
  });

  it("maps a review request and activity events", () => {
    const request = mr(1, { reviewers: [reviewer("me", "UNREVIEWED")] });
    const mine = mr(2);
    const events: ActivityEvent[] = [
      { kind: "review-requested", mr: request },
      { kind: "comment", mr: mine, noteId: "n1", author: bob },
    ];
    const result = historyEvents(snapshot({ reviewRequested: [request] }), previous(), events, AT);
    expect(result).toEqual([
      { kind: "review-requested", mrKey: "g/p!1", username: "", at: AT },
      { kind: "activity", mrKey: "g/p!2", username: "", at: AT },
    ]);
  });

  it("adds reviewer-reviewed when a Reviewer leaves UNREVIEWED", () => {
    const mine = mr(2, { reviewers: [reviewer("bob", "APPROVED")] });
    const events: ActivityEvent[] = [
      { kind: "reviewer-state", mr: mine, reviewer: bob, to: "APPROVED" },
    ];
    const known = previous({
      reviewerStates: new Map([[reviewerKey(mine.key, "bob"), "UNREVIEWED"]]),
    });
    expect(historyEvents(snapshot({ authored: [mine] }), known, events, AT)).toEqual([
      { kind: "activity", mrKey: "g/p!2", username: "", at: AT },
      { kind: "reviewer-reviewed", mrKey: "g/p!2", username: "bob", at: AT },
    ]);
  });

  it("adds reviewer-reviewed for a Reviewer with no stored state", () => {
    const mine = mr(2, { reviewers: [reviewer("bob", "APPROVED")] });
    const events: ActivityEvent[] = [
      { kind: "reviewer-state", mr: mine, reviewer: bob, to: "APPROVED" },
    ];
    const kinds = historyEvents(snapshot({ authored: [mine] }), previous(), events, AT).map(
      (event) => event.kind,
    );
    expect(kinds).toEqual(["activity", "reviewer-reviewed"]);
  });

  it("does not add reviewer-reviewed for APPROVED → UNAPPROVED", () => {
    const mine = mr(2, { reviewers: [reviewer("bob", "UNAPPROVED")] });
    const events: ActivityEvent[] = [
      { kind: "reviewer-state", mr: mine, reviewer: bob, to: "UNAPPROVED" },
    ];
    const known = previous({
      reviewerStates: new Map([[reviewerKey(mine.key, "bob"), "APPROVED"]]),
    });
    expect(historyEvents(snapshot({ authored: [mine] }), known, events, AT)).toEqual([
      { kind: "activity", mrKey: "g/p!2", username: "", at: AT },
    ]);
  });

  it("adds owner-reviewed when the Owner's own state leaves UNREVIEWED", () => {
    const reviewed = mr(1, { reviewers: [reviewer("me", "APPROVED")] });
    const known = previous({ myReviewStates: new Map([[reviewed.key, "UNREVIEWED"]]) });
    expect(historyEvents(snapshot({ reviewRequested: [reviewed] }), known, [], AT)).toEqual([
      { kind: "owner-reviewed", mrKey: "g/p!1", username: "author", at: AT },
    ]);
  });

  it("does not repeat owner-reviewed once the Owner's state is stored as reviewed", () => {
    const reviewed = mr(1, { reviewers: [reviewer("me", "APPROVED")] });
    const known = previous({ myReviewStates: new Map([[reviewed.key, "APPROVED"]]) });
    expect(historyEvents(snapshot({ reviewRequested: [reviewed] }), known, [], AT)).toEqual([]);
  });

  it("ignores the Owner's review on a draft MR", () => {
    const draft = mr(1, { draft: true, reviewers: [reviewer("me", "APPROVED")] });
    const known = previous({ myReviewStates: new Map([[draft.key, "UNREVIEWED"]]) });
    expect(historyEvents(snapshot({ reviewRequested: [draft] }), known, [], AT)).toEqual([]);
  });

  it("ignores comments that are not events", () => {
    const mine = mr(2, { notes: [note("n1", bob)] });
    expect(historyEvents(snapshot({ authored: [mine] }), previous(), [], AT)).toEqual([]);
  });
});

describe("firstApprovals", () => {
  const opened = "2026-10-16T08:00:00.000Z";

  it("records an approval of an Owner's MR with when it was opened", () => {
    const mine = mr(2, { createdAt: opened, reviewers: [reviewer("bob", "APPROVED")] });
    const events: ActivityEvent[] = [
      { kind: "reviewer-state", mr: mine, reviewer: bob, to: "APPROVED" },
      { kind: "comment", mr: mine, noteId: "n1", author: bob },
    ];
    expect(firstApprovals(events, AT)).toEqual([
      {
        mrKey: "g/p!2",
        title: mine.title,
        url: mine.url,
        openedAt: Date.parse(opened),
        approvedAt: AT,
        approver: bob,
      },
    ]);
  });

  it("ignores other review states and an MR without a usable opening time", () => {
    const unknown = mr(3, { reviewers: [reviewer("bob", "APPROVED")] });
    const mine = mr(2, { createdAt: opened, reviewers: [reviewer("bob", "UNAPPROVED")] });
    const events: ActivityEvent[] = [
      { kind: "reviewer-state", mr: unknown, reviewer: bob, to: "APPROVED" },
      { kind: "reviewer-state", mr: mine, reviewer: bob, to: "UNAPPROVED" },
      { kind: "reviewer-state", mr: mr(4, { createdAt: "soon" }), reviewer: bob, to: "APPROVED" },
    ];
    expect(firstApprovals(events, AT)).toEqual([]);
  });
});
