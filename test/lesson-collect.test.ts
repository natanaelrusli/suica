import { afterEach, describe, expect, it } from "vitest";
import { parseConfig } from "../src/config.ts";
import {
  backfillThreads,
  collectReviews,
  occurrencesFromReview,
  occurrencesFromThreads,
  threadOutcome,
} from "../src/lessons/collect.ts";
import { createLessonLearner } from "../src/lessons/learn.ts";
import { createLogger } from "../src/log.ts";
import { openStore } from "../src/store.ts";
import type { AgentReviewRow, AgentReviewStatus, Store } from "../src/store.ts";
import { thread } from "./fix-builders.ts";

const NOW = Date.UTC(2026, 9, 26, 9);
const stores: Store[] = [];
afterEach(() => {
  for (const store of stores.splice(0)) store.close();
});
function store(): Store {
  const opened = openStore(":memory:");
  stores.push(opened);
  return opened;
}

const REVIEW = [
  "# Code review",
  "",
  "## Findings",
  "",
  "### Major",
  "",
  "1. `src/a.ts:3` — Missing null check",
  "   The handler reads `user.id` before the check.",
  "",
  "### Minor",
  "",
  "1. `src/b.ts:9` — Name is unclear",
].join("\n");

const REREVIEW = [
  "# Code review",
  "",
  "## Previous review",
  "",
  "- Major `src/a.ts:3` missing null check — fixed. The check is there now.",
  "- Minor `src/b.ts:9` Name is unclear — not fixed. Still `x`.",
  "- Minor `src/c.ts:1` Something never reported — partly fixed. Half.",
  "",
  "## Findings",
  "",
  "### Nit",
  "",
  "1. `src/d.ts:2` — Trailing space",
].join("\n");

/** A review of `key` that reached `status` with `body`. */
function review(
  db: Store,
  body: string,
  status: AgentReviewStatus = "ready",
  key = "g/p!7",
): AgentReviewRow {
  const id = db.queueAgentReview(key, "manual", NOW, "Add thing") ?? 0;
  if (status !== "queued") db.transitionAgentReview(id, ["queued"], status, { body }, NOW);
  const row = db.getAgentReview(id);
  if (row === undefined) throw new Error("no review");
  return row;
}

const quiet = createLogger({ write: () => undefined });

describe("collecting review findings", () => {
  it("a review gives one occurrence per finding with its severity", () => {
    const db = store();
    const { add } = occurrencesFromReview(review(db, REVIEW), "gitlab.example");
    expect(add).toEqual([
      expect.objectContaining({
        sourceKey: "review:1:1",
        source: "review",
        mrKey: "g/p!7",
        mrTitle: "Add thing",
        mrUrl: "https://gitlab.example/g/p/-/merge_requests/7",
        path: "src/a.ts",
        line: 3,
        severity: "Major",
        title: "Missing null check",
        outcome: "open",
      }),
      expect.objectContaining({ path: "src/b.ts", severity: "Minor", title: "Name is unclear" }),
    ]);
    // Both lists start at 1: the second takes its position too.
    expect(add.map((each) => each.sourceKey)).toEqual(["review:1:1", "review:1:1#2"]);
  });

  it("collecting twice adds nothing", () => {
    const db = store();
    review(db, REVIEW);
    expect(collectReviews(db, NOW)).toBe(2);
    expect(collectReviews(db, NOW)).toBe(0);
    expect(db.lessons.countPending()).toBe(2);
  });

  it("a re-review's previous-review verdict sets the outcome of the matching occurrence", () => {
    const db = store();
    review(db, REVIEW, "posted");
    collectReviews(db, NOW);
    review(db, REREVIEW);
    collectReviews(db, NOW + 1);
    expect(
      db.lessons.findOccurrenceByLocation("g/p!7", "src/a.ts", "Missing null check"),
    ).toMatchObject({
      outcome: "fixed",
    });
    expect(
      db.lessons.findOccurrenceByLocation("g/p!7", "src/b.ts", "Name is unclear"),
    ).toMatchObject({
      outcome: "not-fixed",
    });
  });

  it("a re-review's previous-review lines add no occurrences", () => {
    const db = store();
    const { add, outcomes } = occurrencesFromReview(review(db, REREVIEW));
    expect(add.map((each) => each.path)).toEqual(["src/d.ts"]);
    expect(outcomes).toEqual([
      { mrKey: "g/p!7", path: "src/a.ts", title: "missing null check", outcome: "fixed" },
      { mrKey: "g/p!7", path: "src/b.ts", title: "Name is unclear", outcome: "not-fixed" },
      {
        mrKey: "g/p!7",
        path: "src/c.ts",
        title: "Something never reported",
        outcome: "partly-fixed",
      },
    ]);
  });

  it("collectReviews skips queued, running and failed reviews", () => {
    const db = store();
    review(db, REVIEW, "failed", "g/p!1");
    review(db, REVIEW, "running", "g/p!2");
    review(db, REVIEW, "queued", "g/p!3");
    review(db, REVIEW, "posted", "g/p!4");
    expect(collectReviews(db, NOW)).toBe(2);
    expect(db.lessons.pendingOccurrences(NOW, 10).map((each) => each.mrKey)).toEqual([
      "g/p!4",
      "g/p!4",
    ]);
  });

  it("a review still running keeps its turn: it is collected once it is ready", () => {
    const db = store();
    const running = review(db, REVIEW, "running", "g/p!1");
    review(db, REVIEW, "ready", "g/p!2");
    expect(collectReviews(db, NOW)).toBe(2);
    db.transitionAgentReview(running.id, ["running"], "ready", {}, NOW);
    expect(collectReviews(db, NOW)).toBe(2);
  });
});

describe("collecting finding threads", () => {
  it("threads give occurrences with the outcome of what the fix did", () => {
    const mr = { key: "g/p!7", title: "Add thing", url: "https://x/7" };
    const rows = occurrencesFromThreads(
      mr,
      [
        thread("d1", "n1", {
          action: "changed",
          notes: [
            {
              author: { username: "bob", name: "Bob" },
              body: "**Major**: Null check\nmore",
              createdAt: "",
            },
          ],
        }),
        thread("d2", "n2", { action: "reply" }),
        thread("d3", "n3"),
      ],
      NOW,
    );
    expect(rows.map((each) => [each.sourceKey, each.outcome, each.title])).toEqual([
      ["thread:g/p!7:d1", "changed", "Major: Null check"],
      ["thread:g/p!7:d2", "replied", "Rename this"],
      ["thread:g/p!7:d3", "open", "Rename this"],
    ]);
    expect(rows[0]).toMatchObject({
      source: "thread",
      severity: "Major",
      path: "src/a.ts",
      line: 3,
    });
    expect(threadOutcome(thread("d", "n"))).toBe("open");
  });

  it("turning lessons on backfills past reviews and stored fix threads once", async () => {
    const db = store();
    review(db, REVIEW, "posted");
    const fixId = db.fixes.queue("g/p!9", "auto", [thread("d1", "n1")], NOW, "Mine") ?? 0;
    db.fixes.transition(
      fixId,
      ["queued"],
      "pushed",
      { threads: [thread("d1", "n1", { action: "changed" })] },
      NOW,
    );
    const learner = (enabled: boolean) =>
      createLessonLearner({
        store: db,
        config: parseConfig(
          `gitlab:\n  hostname: gitlab.example\nlessons:\n  enabled: ${String(enabled)}\n`,
        ),
        log: quiet,
        now: () => NOW,
        exec: () => Promise.reject(new Error("no model in tests")),
        busy: () => false,
        detail: () => Promise.reject(new Error("no GitLab in tests")),
        scan: () => ({ repos: [] }),
      });
    await learner(false).tick();
    expect(db.lessons.countPending()).toBe(0);
    await learner(true).tick();
    expect(db.lessons.countPending()).toBe(3);
    expect(db.lessons.occurrenceBySource("thread:g/p!9:d1")?.outcome).toBe("changed");
    await learner(true).tick();
    expect(db.lessons.countPending()).toBe(3);
    expect(backfillThreads(db, NOW)).toBe(0);
  });
});
