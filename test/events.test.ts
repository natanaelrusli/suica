import { describe, expect, it } from "vitest";
import type { MergeRequest } from "../src/domain.ts";
import { countPendingReviews, detectEvents, reviewerKey } from "../src/events.ts";
import type { DetectOptions, PreviousState } from "../src/events.ts";
import { ME, mr, note, person, previous, reviewer, snapshot } from "./builders.ts";

const options: DetectOptions = { ignoreAuthors: new Set(["ci-bot"]) };
const mine = (state: string) => [reviewer("me", state)];

describe("review requests (flow A)", () => {
  it("emits nothing before the baseline is recorded", () => {
    const current = snapshot({ reviewRequested: [mr(1, { reviewers: mine("UNREVIEWED") })] });
    expect(detectEvents(current, previous({ baselineDone: false }), options)).toEqual([]);
  });

  it("emits for a newly seen MR where the Owner is UNREVIEWED", () => {
    const request = mr(1, { reviewers: mine("UNREVIEWED") });
    expect(detectEvents(snapshot({ reviewRequested: [request] }), previous(), options)).toEqual([
      { kind: "review-requested", mr: request },
    ]);
  });

  it("does not repeat for an MR that is already known as UNREVIEWED", () => {
    const request = mr(1, { reviewers: mine("UNREVIEWED") });
    const known = previous({ myReviewStates: new Map([[request.key, "UNREVIEWED"]]) });
    expect(detectEvents(snapshot({ reviewRequested: [request] }), known, options)).toEqual([]);
  });

  it("emits again when the Owner is asked to review again", () => {
    const request = mr(1, { reviewers: mine("UNREVIEWED") });
    const known = previous({ myReviewStates: new Map([[request.key, "APPROVED"]]) });
    expect(detectEvents(snapshot({ reviewRequested: [request] }), known, options)).toHaveLength(1);
  });

  it("stays quiet when the Owner has already reviewed a newly seen MR", () => {
    const request = mr(1, { reviewers: mine("APPROVED") });
    expect(detectEvents(snapshot({ reviewRequested: [request] }), previous(), options)).toEqual([]);
  });

  it("ignores drafts, and a draft that becomes ready is a new request", () => {
    const draft = mr(1, { draft: true, reviewers: mine("UNREVIEWED") });
    expect(detectEvents(snapshot({ reviewRequested: [draft] }), previous(), options)).toEqual([]);
    const ready = mr(1, { draft: false, reviewers: mine("UNREVIEWED") });
    expect(detectEvents(snapshot({ reviewRequested: [ready] }), previous(), options)).toHaveLength(
      1,
    );
  });

  it("counts pending reviews for the baseline summary", () => {
    const current = snapshot({
      reviewRequested: [
        mr(1, { reviewers: mine("UNREVIEWED") }),
        mr(2, { reviewers: mine("APPROVED") }),
        mr(3, { draft: true, reviewers: mine("UNREVIEWED") }),
      ],
    });
    expect(countPendingReviews(current)).toBe(1);
  });
});

describe("activity on the Owner's MRs (flow D)", () => {
  const bob = person("bob", "Bob");
  const base = (overrides: Partial<MergeRequest> = {}): MergeRequest =>
    mr(5, { author: ME, reviewers: [reviewer("bob", "UNREVIEWED")], ...overrides });
  const tracked = (state = "UNREVIEWED", extra: Partial<PreviousState> = {}): PreviousState =>
    previous({
      trackedAuthored: new Set(["g/p!5"]),
      reviewerStates: new Map([[reviewerKey("g/p!5", "bob"), state]]),
      ...extra,
    });

  it("emits when a Reviewer's state changes to something other than UNREVIEWED", () => {
    const current = snapshot({ authored: [base({ reviewers: [reviewer("bob", "APPROVED")] })] });
    expect(detectEvents(current, tracked(), options)).toEqual([
      { kind: "reviewer-state", mr: current.authored[0], reviewer: person("bob"), to: "APPROVED" },
    ]);
  });

  it("does not emit when the Owner re-requests review (state goes back to UNREVIEWED)", () => {
    const current = snapshot({ authored: [base()] });
    expect(detectEvents(current, tracked("APPROVED"), options)).toEqual([]);
  });

  it("does not emit for a Reviewer who was just added and has not reviewed yet", () => {
    const current = snapshot({
      authored: [
        base({ reviewers: [reviewer("bob", "UNREVIEWED"), reviewer("carol", "UNREVIEWED")] }),
      ],
    });
    expect(detectEvents(current, tracked(), options)).toEqual([]);
  });

  it("emits for a Reviewer who was added and reviewed between two polls", () => {
    const current = snapshot({
      authored: [
        base({ reviewers: [reviewer("bob", "UNREVIEWED"), reviewer("carol", "APPROVED")] }),
      ],
    });
    expect(detectEvents(current, tracked(), options)).toEqual([
      {
        kind: "reviewer-state",
        mr: current.authored[0],
        reviewer: person("carol"),
        to: "APPROVED",
      },
    ]);
  });

  it("emits for new comments from other people", () => {
    const comment = note("n1", bob);
    const current = snapshot({ authored: [base({ notes: [comment] })] });
    expect(detectEvents(current, tracked(), options)).toEqual([
      { kind: "comment", mr: current.authored[0], noteId: "n1", author: bob },
    ]);
  });

  it("ignores own notes, system notes, ignored authors and notes already seen", () => {
    const current = snapshot({
      authored: [
        base({
          notes: [note("a", ME), note("b", bob, true), note("c", person("ci-bot")), note("d", bob)],
        }),
      ],
    });
    expect(
      detectEvents(current, tracked("UNREVIEWED", { seenNotes: new Set(["d"]) }), options),
    ).toEqual([]);
  });

  it("records an MR silently the first time it is tracked, even if it already has comments", () => {
    const current = snapshot({
      authored: [base({ notes: [note("old", bob)], reviewers: [reviewer("bob", "APPROVED")] })],
    });
    expect(detectEvents(current, previous(), options)).toEqual([]);
  });

  it("ignores draft MRs of the Owner", () => {
    const current = snapshot({ authored: [base({ draft: true, notes: [note("n", bob)] })] });
    expect(detectEvents(current, tracked(), options)).toEqual([]);
  });
});
