import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, describe, expect, it } from "vitest";
import { openStore } from "../src/store.ts";
import { thread } from "./fix-builders.ts";

const folders: string[] = [];
afterEach(() => {
  for (const folder of folders.splice(0)) rmSync(folder, { recursive: true, force: true });
});

describe("fix store", () => {
  it("queues a fix and adds later threads to it while it is still queued", () => {
    const { fixes } = openStore(":memory:");
    const id = fixes.queue("g/p!7", "auto", [thread("d1", "n1")], 1000, "Add thing");
    expect(id).toBeDefined();
    const again = fixes.queue("g/p!7", "auto", [thread("d1", "n3"), thread("d2", "n2")], 2000);
    expect(again).toBe(id);
    const row = fixes.get(id ?? 0);
    expect(row?.status).toBe("queued");
    expect(row?.mrTitle).toBe("Add thing");
    expect(row?.threads.map((each) => [each.id, each.noteId])).toEqual([
      ["d1", "n3"],
      ["d2", "n2"],
    ]);
  });

  it("refuses another fix while one is running, ready or confirming", () => {
    const { fixes } = openStore(":memory:");
    for (const status of ["running", "ready", "confirming"] as const) {
      const id = fixes.queue(`g/p!${status.length}`, "auto", [thread("d1", "n1")], 1000) ?? 0;
      expect(fixes.transition(id, ["queued"], status, {}, 1100)).toBe(true);
      expect(
        fixes.queue(`g/p!${status.length}`, "auto", [thread("d2", "n2")], 1200),
      ).toBeUndefined();
      expect(fixes.open(`g/p!${status.length}`)?.id).toBe(id);
    }
  });

  it("moves a row only from one of the given statuses, and keeps the fields it was given", () => {
    const { fixes } = openStore(":memory:");
    const id =
      fixes.queue("g/p!7", "manual", [thread("d1", "n1")], 1000, undefined, "be brief") ?? 0;
    expect(fixes.transition(id, ["running"], "ready", {}, 1100)).toBe(false);
    expect(
      fixes.transition(id, ["queued"], "running", { startedAt: 1100, cli: "claude" }, 1100),
    ).toBe(true);
    const done = fixes.transition(
      id,
      ["running"],
      "ready",
      {
        baseSha: "abc",
        diff: "diff --git",
        commitMessage: "Rename",
        threads: [thread("d1", "n1", { action: "changed" })],
      },
      1200,
    );
    expect(done).toBe(true);
    const row = fixes.get(id);
    expect(row).toMatchObject({
      status: "ready",
      trigger: "manual",
      note: "be brief",
      cli: "claude",
      baseSha: "abc",
      diff: "diff --git",
      commitMessage: "Rename",
      startedAt: 1100,
      updatedAt: 1200,
    });
    expect(row?.threads[0]?.action).toBe("changed");
  });

  it("puts a running fix back in the queue without its start or activity", () => {
    const { fixes } = openStore(":memory:");
    const id = fixes.queue("g/p!7", "auto", [thread("d1", "n1")], 1000) ?? 0;
    fixes.transition(id, ["queued"], "running", { startedAt: 1100 }, 1100);
    fixes.appendActivity(id, 1150, "Cloning");
    expect(fixes.get(id)?.activity).toEqual([{ at: 1150, text: "Cloning" }]);
    expect(fixes.interruptedRunning().map((row) => row.id)).toEqual([id]);
    expect(fixes.requeue(id, 1200)).toBe(true);
    expect(fixes.get(id)).toMatchObject({ status: "queued", startedAt: null, activity: [] });
    expect(fixes.nextQueued()?.id).toBe(id);
  });

  it("remembers the note each thread was handled at", () => {
    const { fixes } = openStore(":memory:");
    fixes.markHandled("g/p!7", [{ id: "d1", noteId: "n1" }]);
    fixes.markHandled("g/p!7", [
      { id: "d1", noteId: "n4" },
      { id: "d2", noteId: "n2" },
    ]);
    expect(fixes.handledNotes("g/p!7")).toEqual(
      new Map([
        ["d1", "n4"],
        ["d2", "n2"],
      ]),
    );
    expect(fixes.handledNotes("g/p!8")).toEqual(new Map());
  });

  it("counts automatic fixes created since a time, and lists the latest fix of each MR", () => {
    const { fixes } = openStore(":memory:");
    const first = fixes.queue("g/p!7", "auto", [thread("d1", "n1")], 1000) ?? 0;
    fixes.transition(first, ["queued"], "failed", { detail: "boom" }, 1100);
    const second = fixes.queue("g/p!7", "auto", [thread("d1", "n1")], 2000) ?? 0;
    fixes.queue("g/p!8", "manual", [thread("d1", "n1")], 3000);
    expect(fixes.countAuto(1500)).toBe(1);
    expect(fixes.countAuto(0)).toBe(2);
    expect(fixes.latestByMr().get("g/p!7")?.id).toBe(second);
    expect(fixes.list(0).map((row) => row.mrKey)).toEqual(["g/p!8", "g/p!7", "g/p!7"]);
    expect(fixes.list(1500).map((row) => row.id)).not.toContain(first);
  });

  it("remembers when the watcher read each MR, and forgets it on request", () => {
    const { fixes } = openStore(":memory:");
    fixes.markWatched("g/p!7", 1000);
    fixes.markWatched("g/p!7", 2000);
    fixes.markWatched("g/p!8", 1500);
    fixes.unwatch("g/p!8");
    expect(fixes.watchMarks()).toEqual(new Map([["g/p!7", 2000]]));
  });

  it("upgrades a schema 13 database", () => {
    const folder = mkdtempSync(join(tmpdir(), "suica-fix-store-"));
    folders.push(folder);
    const path = join(folder, "state.db");
    openStore(path).close();
    const db = new DatabaseSync(path);
    db.exec(
      "DROP TABLE fix_run; DROP TABLE fix_thread; DROP TABLE fix_watch; PRAGMA user_version = 13",
    );
    db.close();
    const store = openStore(path);
    expect(store.fixes.list(0)).toEqual([]);
    store.close();
  });
});
