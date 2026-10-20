import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, describe, expect, it } from "vitest";
import { reviewerKey } from "../src/events.ts";
import { openStore } from "../src/store.ts";
import type { ReviewHead, Store } from "../src/store.ts";
import { ME, mr, note, person, reviewer, snapshot } from "./builders.ts";

const folders: string[] = [];
function tempDb(): string {
  const folder = mkdtempSync(join(tmpdir(), "suica-store-"));
  folders.push(folder);
  return join(folder, "state.db");
}
afterEach(() => {
  for (const folder of folders.splice(0)) rmSync(folder, { recursive: true, force: true });
});

const bob = person("bob", "Bob");

describe("openStore", () => {
  it("starts empty and not yet baselined", () => {
    const store = openStore(":memory:");
    expect(store.load()).toEqual({
      baselineDone: false,
      trackedAuthored: new Set(),
      myReviewStates: new Map(),
      reviewerStates: new Map(),
      seenNotes: new Set(),
    });
    expect(store.isPaused()).toBe(false);
  });

  it("commits exactly what the next diff needs, leaving drafts out", () => {
    const store = openStore(":memory:");
    store.commit(
      snapshot({
        reviewRequested: [
          mr(1, { reviewers: [reviewer("me", "UNREVIEWED")] }),
          mr(2, { draft: true, reviewers: [reviewer("me", "UNREVIEWED")] }),
        ],
        authored: [
          mr(5, {
            author: ME,
            reviewers: [reviewer("bob", "APPROVED")],
            notes: [note("n1", bob)],
          }),
          mr(6, { author: ME, draft: true, notes: [note("n2", bob)] }),
        ],
      }),
    );
    expect(store.load()).toEqual({
      baselineDone: true,
      trackedAuthored: new Set(["g/p!5"]),
      myReviewStates: new Map([["g/p!1", "UNREVIEWED"]]),
      reviewerStates: new Map([[reviewerKey("g/p!5", "bob"), "APPROVED"]]),
      seenNotes: new Set(["n1"]),
    });
  });

  it("replaces state on every commit so closed MRs and old notes are pruned", () => {
    const store = openStore(":memory:");
    store.commit(snapshot({ authored: [mr(5, { author: ME, notes: [note("n1", bob)] })] }));
    store.commit(snapshot());
    const state = store.load();
    expect(state.trackedAuthored.size).toBe(0);
    expect(state.seenNotes.size).toBe(0);
    expect(state.baselineDone).toBe(true);
  });

  it("persists across reopening and keeps the pause flag", () => {
    const path = tempDb();
    const first = openStore(path);
    first.commit(
      snapshot({ reviewRequested: [mr(1, { reviewers: [reviewer("me", "UNREVIEWED")] })] }),
    );
    first.setPaused(true);
    first.close();
    const second = openStore(path);
    expect(second.load().myReviewStates.get("g/p!1")).toBe("UNREVIEWED");
    expect(second.isPaused()).toBe(true);
    second.setPaused(false);
    expect(second.isPaused()).toBe(false);
    second.close();
  });

  it("upgrades a schema 3 outbox, leaving the approval of older rows unknown", () => {
    const path = tempDb();
    openStore(path).close();
    const raw = new DatabaseSync(path);
    raw.exec("ALTER TABLE outbox DROP COLUMN approved; PRAGMA user_version = 3");
    raw.exec(
      `INSERT INTO outbox (dedupe_key, kind, variant, mr_key, mr_iid, mr_project, mr_title, mr_url,
         recipient, recipient_name, status, detail, text, created_at, updated_at)
       VALUES ('k', 'nudge', 'nudge', 'g/p!5', 5, 'g/p', 't', 'u', 'bob', 'Bob', 'sent', '', 'halo', 1, 1)`,
    );
    raw.close();
    const store = openStore(path);
    expect(store.listOutbox(["sent"])[0]?.approved).toBeNull();
    store.close();
  });

  it("refuses a database written by a newer version", () => {
    const path = tempDb();
    const raw = new DatabaseSync(path);
    raw.exec("PRAGMA user_version = 99");
    raw.close();
    expect(() => openStore(path)).toThrow(/newer/);
  });
});

describe("opening a database another process holds", () => {
  it("waits for the lock instead of failing at once", async () => {
    const path = tempDb();
    // The other process takes the lock on the new file and lets go a moment later.
    const holder = spawn(
      process.execPath,
      [
        "-e",
        `const { DatabaseSync } = require("node:sqlite");
         const db = new DatabaseSync(process.argv[1]);
         db.exec("BEGIN EXCLUSIVE; CREATE TABLE held (x);");
         process.stdout.write("held\\n");
         setTimeout(() => { db.exec("COMMIT"); db.close(); }, 400);`,
        path,
      ],
      { stdio: ["ignore", "pipe", "inherit"] },
    );
    const exited = new Promise((resolve) => holder.on("exit", resolve));
    await new Promise<void>((resolve) => holder.stdout.once("data", () => resolve()));
    try {
      const store = openStore(path);
      expect(store.isPaused()).toBe(false);
      store.close();
    } finally {
      await exited;
    }
  });
});

describe("schema 10", () => {
  const NOW = Date.UTC(2026, 9, 19, 12);

  /** Queues, runs and moves a review of `mrKey` to `status`, reviewed at `headSha`. */
  function review(
    store: Store,
    mrKey: string,
    status: "posted" | "discarded" | "failed" | "skipped" | "ready",
    headSha: string,
  ): number {
    const id = store.queueAgentReview(mrKey, "auto", NOW) ?? 0;
    store.transitionAgentReview(id, ["queued"], "running", { headSha }, NOW);
    if (status === "failed" || status === "skipped") {
      store.transitionAgentReview(id, ["running"], status, {}, NOW);
    } else {
      store.transitionAgentReview(id, ["running"], "ready", { body: "b" }, NOW);
      if (status !== "ready") {
        store.transitionAgentReview(id, ["ready"], status, {}, NOW);
      }
    }
    return id;
  }

  it("upgrades schema 9 to 10: agent_review gains previous_sha (null on old rows) and review_head starts empty", () => {
    const path = tempDb();
    const first = openStore(path);
    const id = review(first, "g/p!1", "posted", "aaa1111");
    first.close();
    const raw = new DatabaseSync(path);
    raw.exec(
      "ALTER TABLE agent_review DROP COLUMN previous_sha; DROP TABLE review_head; PRAGMA user_version = 9;",
    );
    raw.close();

    const store = openStore(path);
    expect(store.getAgentReview(id)?.previousSha).toBeNull();
    expect(store.loadReviewHeads()).toEqual(new Map());
    const next = store.queueAgentReview("g/p!1", "manual", NOW) ?? 0;
    store.transitionAgentReview(next, ["queued"], "running", { previousSha: "aaa1111" }, NOW);
    expect(store.getAgentReview(next)?.previousSha).toBe("aaa1111");
    store.close();
    const check = new DatabaseSync(path);
    expect(check.prepare("PRAGMA user_version").get()?.["user_version"]).toBe(11);
    check.close();
  });

  it("upgrades schema 10 to 11: agent_review gains description_sha (null) and approved (false) on old rows", () => {
    const path = tempDb();
    const first = openStore(path);
    const id = review(first, "g/p!1", "posted", "aaa1111");
    first.close();
    const raw = new DatabaseSync(path);
    raw.exec(
      "ALTER TABLE agent_review DROP COLUMN description_sha; ALTER TABLE agent_review DROP COLUMN approved; PRAGMA user_version = 10;",
    );
    raw.close();

    const store = openStore(path);
    expect(store.getAgentReview(id)).toMatchObject({ descriptionSha: null, approved: false });
    const next = store.queueAgentReview("g/p!1", "manual", NOW) ?? 0;
    store.transitionAgentReview(
      next,
      ["queued"],
      "running",
      { descriptionSha: "d1", approved: true },
      NOW,
    );
    expect(store.getAgentReview(next)).toMatchObject({ descriptionSha: "d1", approved: true });
    store.close();
    const check = new DatabaseSync(path);
    expect(check.prepare("PRAGMA user_version").get()?.["user_version"]).toBe(11);
    check.close();
  });

  it("hasAgentReviewAt matches the commit and the description, taking an old row without a hash as the same description", () => {
    const store = openStore(":memory:");
    const old = review(store, "g/p!1", "posted", "aaa1111");
    expect(store.hasAgentReviewAt("g/p!1", "aaa1111", "d1")).toBe(true);
    expect(store.hasAgentReviewAt("g/p!1", "bbb2222", "d1")).toBe(false);
    store.transitionAgentReview(old, ["posted"], "posted", { descriptionSha: "d1" }, NOW);
    expect(store.hasAgentReviewAt("g/p!1", "aaa1111", "d1")).toBe(true);
    expect(store.hasAgentReviewAt("g/p!1", "aaa1111", "d2")).toBe(false);
    review(store, "g/p!2", "failed", "ccc3333");
    expect(store.hasAgentReviewAt("g/p!2", "ccc3333", "d1")).toBe(false);
    store.close();
  });

  it("rereviewBases returns the newest posted or discarded review per MR and ignores later failed and skipped rows", () => {
    const store = openStore(":memory:");
    review(store, "g/p!1", "posted", "aaa1111");
    const newer = review(store, "g/p!1", "discarded", "bbb2222");
    review(store, "g/p!1", "failed", "ccc3333");
    review(store, "g/p!1", "skipped", "ddd4444");
    review(store, "g/p!1", "ready", "eee5555");
    const other = review(store, "g/p!2", "posted", "fff6666");
    review(store, "g/p!3", "failed", "ggg7777");
    const bases = store.rereviewBases();
    expect([...bases.keys()].sort()).toEqual(["g/p!1", "g/p!2"]);
    expect(bases.get("g/p!1")).toMatchObject({
      id: newer,
      status: "discarded",
      headSha: "bbb2222",
    });
    expect(bases.get("g/p!2")?.id).toBe(other);
    store.close();
  });

  it("rereviewBase only looks at rows before the given id", () => {
    const store = openStore(":memory:");
    const first = review(store, "g/p!1", "posted", "aaa1111");
    const second = review(store, "g/p!1", "posted", "bbb2222");
    expect(store.rereviewBase("g/p!1", second)?.id).toBe(first);
    expect(store.rereviewBase("g/p!1", first)).toBeUndefined();
    expect(store.rereviewBase("g/p!1", second + 1)?.id).toBe(second);
    expect(store.rereviewBase("g/p!2", second)).toBeUndefined();
    store.close();
  });

  it("saveReviewHeads replaces every row and loadReviewHeads reads them back", () => {
    const path = tempDb();
    const store = openStore(path);
    const a: ReviewHead = { head: "aaa1111", changedAt: NOW, queuedHead: "" };
    const b: ReviewHead = { head: "bbb2222", changedAt: NOW + 1, queuedHead: "bbb2222" };
    store.saveReviewHeads(
      new Map([
        ["g/p!1", a],
        ["g/p!2", b],
      ]),
    );
    expect(store.loadReviewHeads()).toEqual(
      new Map([
        ["g/p!1", a],
        ["g/p!2", b],
      ]),
    );
    store.saveReviewHeads(new Map([["g/p!2", { ...b, queuedHead: "" }]]));
    expect(store.loadReviewHeads()).toEqual(new Map([["g/p!2", { ...b, queuedHead: "" }]]));
    store.close();
  });
});
