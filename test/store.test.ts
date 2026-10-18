import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, describe, expect, it } from "vitest";
import { reviewerKey } from "../src/events.ts";
import { openStore } from "../src/store.ts";
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
