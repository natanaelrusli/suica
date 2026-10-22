import { describe, expect, it } from "vitest";
import {
  findingThreads,
  isApprovedByAll,
  isWatched,
  queueAutomaticFixes,
  queueManualFix,
  setWatch,
} from "../src/agent-fix.ts";
import type { FixQueueDeps } from "../src/agent-fix.ts";
import type { Config } from "../src/config.ts";
import { createLogger } from "../src/log.ts";
import type { DiscussionJson, MrDetailJson, NoteJson } from "../src/reviews.ts";
import { openStore } from "../src/store.ts";
import type { Store } from "../src/store.ts";
import { ME, mr, note, person, reviewer, snapshot } from "./builders.ts";
import { thread } from "./fix-builders.ts";

const bob = person("bob", "Bob");
const sonar = person("sonar-bot", "SonarQube");

function gitlabNote(id: string, author = bob, system = false): NoteJson {
  return {
    id,
    body: `body of ${id}`,
    system,
    createdAt: "2026-10-21T09:00:00Z",
    author,
    filePath: "src/a.ts",
    line: 4,
  };
}

function discussion(
  id: string,
  notes: NoteJson[],
  overrides: Partial<DiscussionJson> = {},
): DiscussionJson {
  return { id, resolvable: true, resolved: false, notes, ...overrides };
}

function detail(discussions: DiscussionJson[], key = "g/p!7"): MrDetailJson {
  return {
    version: 1,
    key,
    title: "Add thing",
    description: "",
    url: "https://gitlab.example/g/p/-/merge_requests/7",
    draft: false,
    sourceBranch: "feat/thing",
    targetBranch: "main",
    createdAt: "",
    updatedAt: "",
    author: ME,
    labels: [],
    pipelineStatus: null,
    pipeline: null,
    additions: 1,
    deletions: 0,
    reviewers: [],
    approvedBy: [],
    squashOnMerge: false,
    squashReadOnly: false,
    removeSourceBranch: false,
    detailedMergeStatus: null,
    defaultMergeCommitMessage: null,
    defaultSquashCommitMessage: null,
    headSha: "abc1234",
    canApprove: false,
    discussions,
    discussionsTruncated: false,
    files: [],
    filesTruncated: false,
  };
}

const quietLog = createLogger({ write: () => undefined });

function deps(
  store: Store,
  details: Record<string, MrDetailJson>,
  fix: Partial<Config["fix"]> = {},
  now = 1_000_000,
): FixQueueDeps & { fetched: string[] } {
  const fetched: string[] = [];
  return {
    store,
    log: quietLog,
    now: () => now,
    config: {
      fix: {
        auto: true,
        watch: "all",
        pipelines: true,
        effort: "medium",
        timeoutMinutes: 20,
        maxPerDay: 10,
        ...fix,
      },
    },
    fetched,
    detail: (key) => {
      fetched.push(key);
      const found = details[key];
      return found === undefined ? Promise.reject(new Error("no such MR")) : Promise.resolve(found);
    },
  };
}

describe("findingThreads", () => {
  it("takes unresolved resolvable threads whose newest note is someone else's, bots included", () => {
    const threads = findingThreads(
      detail([
        discussion("d1", [gitlabNote("n1")]),
        discussion("d2", [gitlabNote("n2"), gitlabNote("n3", ME)]),
        discussion("d3", [gitlabNote("n4"), gitlabNote("n5", ME), gitlabNote("n6")]),
        discussion("d4", [gitlabNote("n7")], { resolved: true }),
        discussion("d5", [gitlabNote("n8")], { resolvable: false }),
        discussion("d6", [gitlabNote("n9", sonar)]),
        discussion("d7", [gitlabNote("n10"), gitlabNote("n11", bob, true)]),
      ]),
      ME.username,
      new Map(),
    );
    expect(threads.map((each) => [each.id, each.noteId])).toEqual([
      ["d1", "n1"],
      ["d3", "n6"],
      ["d6", "n9"],
      ["d7", "n10"],
    ]);
    expect(threads[0]).toEqual(
      thread("d1", "n1", {
        line: 4,
        notes: [{ author: bob, body: "body of n1", createdAt: "2026-10-21T09:00:00Z" }],
      }),
    );
  });

  it("skips a thread handled at its newest note, unless the Owner asks by hand", () => {
    const mrDetail = detail([
      discussion("d1", [gitlabNote("n1")]),
      discussion("d2", [gitlabNote("n2")]),
    ]);
    const handled = new Map([
      ["d1", "n1"],
      ["d2", "n0"],
    ]);
    expect(findingThreads(mrDetail, ME.username, handled).map((each) => each.id)).toEqual(["d2"]);
    expect(findingThreads(mrDetail, ME.username, "manual").map((each) => each.id)).toEqual([
      "d1",
      "d2",
    ]);
  });
});

describe("isApprovedByAll", () => {
  it("needs at least one Reviewer, and every Reviewer approved", () => {
    expect(isApprovedByAll(mr(7))).toBe(false);
    expect(isApprovedByAll(mr(7, { reviewers: [reviewer("bob", "APPROVED")] }))).toBe(true);
    expect(
      isApprovedByAll(
        mr(7, { reviewers: [reviewer("bob", "APPROVED"), reviewer("cy", "UNAPPROVED")] }),
      ),
    ).toBe(false);
  });
});

describe("isWatched", () => {
  it("takes the MR's own choice, else fix.watch", () => {
    const choices = new Map([
      ["g/p!1", false],
      ["g/p!2", true],
    ]);
    const all = deps(openStore(":memory:"), {}).config;
    const chosen = deps(openStore(":memory:"), {}, { watch: "chosen" }).config;
    expect(["g/p!1", "g/p!2", "g/p!3"].map((key) => isWatched(key, choices, all))).toEqual([
      false,
      true,
      true,
    ]);
    expect(["g/p!1", "g/p!2", "g/p!3"].map((key) => isWatched(key, choices, chosen))).toEqual([
      false,
      true,
      false,
    ]);
  });
});

describe("setWatch", () => {
  it("cancels a queued automatic fix on unwatch and keeps a manual one", () => {
    const store = openStore(":memory:");
    const auto = store.fixes.queue("g/p!7", "auto", [thread("d1", "n1")], 1) ?? 0;
    const manual = store.fixes.queue("g/p!8", "manual", [thread("d1", "n1")], 1) ?? 0;
    const run = deps(store, {});
    expect(setWatch(run, "g/p!7", false)).toBe("not-watching");
    expect(setWatch(run, "g/p!8", false)).toBe("not-watching");
    expect(store.fixes.get(auto)?.status).toBe("cancelled");
    expect(store.fixes.get(manual)?.status).toBe("queued");
    expect(store.fixes.watchChoices()).toEqual(
      new Map([
        ["g/p!7", false],
        ["g/p!8", false],
      ]),
    );
  });

  it("forgets the read mark on watch, and refuses a bad key", () => {
    const store = openStore(":memory:");
    store.fixes.markWatched("g/p!7", 1);
    const run = deps(store, {});
    expect(setWatch(run, "g/p!7", true)).toBe("watching");
    expect(store.fixes.watchMarks().has("g/p!7")).toBe(false);
    expect(setWatch(run, "nope", true)).toBe("bad-key");
    expect(store.fixes.watchChoices().has("nope")).toBe(false);
  });
});

describe("queueAutomaticFixes", () => {
  const mine = (overrides: Parameters<typeof mr>[1] = {}) =>
    mr(7, { author: ME, reviewers: [reviewer("bob", "REQUESTED_CHANGES")], ...overrides });

  it("checks a watched MR once, then again only when someone else writes", async () => {
    const store = openStore(":memory:");
    const details = { "g/p!7": detail([]) };
    const first = deps(store, details);
    await queueAutomaticFixes(first, snapshot({ authored: [mine()] }), new Set());
    expect(first.fetched).toEqual(["g/p!7"]);

    const quiet = deps(store, details);
    await queueAutomaticFixes(
      quiet,
      snapshot({ authored: [mine({ notes: [note("n1", ME), note("n2", bob, true)] })] }),
      new Set(),
    );
    expect(quiet.fetched).toEqual([]);

    const seen = deps(store, details);
    await queueAutomaticFixes(
      seen,
      snapshot({ authored: [mine({ notes: [note("n3", bob)] })] }),
      new Set(["n3"]),
    );
    expect(seen.fetched).toEqual([]);

    const fresh = deps(store, details);
    await queueAutomaticFixes(
      fresh,
      snapshot({ authored: [mine({ notes: [note("n3", bob)] })] }),
      new Set(),
    );
    expect(fresh.fetched).toEqual(["g/p!7"]);
  });

  it("leaves an unwatched MR alone and reads it once it is watched again", async () => {
    const store = openStore(":memory:");
    const details = { "g/p!7": detail([discussion("d1", [gitlabNote("n1")])]) };
    const run = deps(store, details);
    setWatch(run, "g/p!7", false);
    await queueAutomaticFixes(run, snapshot({ authored: [mine()] }), new Set());
    expect(run.fetched).toEqual([]);
    expect(store.fixes.open("g/p!7")).toBeUndefined();
    setWatch(run, "g/p!7", true);
    await queueAutomaticFixes(run, snapshot({ authored: [mine()] }), new Set());
    expect(store.fixes.open("g/p!7")?.threads).toHaveLength(1);
  });

  it("with fix.watch chosen, only fixes MRs the Owner watches", async () => {
    const store = openStore(":memory:");
    const details = {
      "g/p!7": detail([discussion("d1", [gitlabNote("n1")])]),
      "g/p!8": detail([discussion("d1", [gitlabNote("n1")])], "g/p!8"),
    };
    const run = deps(store, details, { watch: "chosen" });
    setWatch(run, "g/p!8", true);
    await queueAutomaticFixes(
      run,
      snapshot({
        authored: [
          mine(),
          mr(8, { author: ME, reviewers: [reviewer("bob", "REQUESTED_CHANGES")] }),
        ],
      }),
      new Set(),
    );
    expect(run.fetched).toEqual(["g/p!8"]);
  });

  it("forgets the watch choices of MRs that are no longer open", async () => {
    const store = openStore(":memory:");
    const run = deps(store, { "g/p!7": detail([]) });
    setWatch(run, "g/p!7", false);
    setWatch(run, "g/p!9", false);
    await queueAutomaticFixes(run, snapshot({ authored: [mine()] }), new Set());
    expect([...store.fixes.watchChoices().keys()]).toEqual(["g/p!7"]);
  });

  it("queues a fix for a Reviewer's new thread", async () => {
    const store = openStore(":memory:");
    const run = deps(store, { "g/p!7": detail([discussion("d1", [gitlabNote("n1")])]) });
    await queueAutomaticFixes(run, snapshot({ authored: [mine()] }), new Set());
    const queued = store.fixes.open("g/p!7");
    expect(queued).toMatchObject({ status: "queued", trigger: "auto", mrTitle: "MR 7" });
    expect(queued?.threads.map((each) => each.id)).toEqual(["d1"]);
  });

  it("looks again at an MR whose fix ended, so threads that waited behind it are picked up", async () => {
    const store = openStore(":memory:");
    const details = { "g/p!7": detail([discussion("d1", [gitlabNote("n1")])]) };
    await queueAutomaticFixes(
      deps(store, details, {}, 1000),
      snapshot({ authored: [mine()] }),
      new Set(),
    );
    const id = store.fixes.open("g/p!7")?.id ?? 0;
    store.fixes.transition(id, ["queued"], "running", {}, 1100);
    store.fixes.transition(id, ["running"], "ready", {}, 1200);
    // d2 arrives while the fix waits for the Owner: it cannot join a ready fix.
    details["g/p!7"] = detail([
      discussion("d1", [gitlabNote("n1")]),
      discussion("d2", [gitlabNote("n2")]),
    ]);
    await queueAutomaticFixes(
      deps(store, details, {}, 1300),
      snapshot({ authored: [mine({ notes: [note("n2", bob)] })] }),
      new Set(),
    );
    expect(store.fixes.open("g/p!7")?.id).toBe(id);
    store.fixes.transition(id, ["ready"], "pushed", {}, 1400);
    store.fixes.markHandled("g/p!7", [{ id: "d1", noteId: "n1" }]);
    const after = deps(store, details, {}, 1500);
    await queueAutomaticFixes(
      after,
      snapshot({ authored: [mine({ notes: [note("n2", bob)] })] }),
      new Set(["n2"]),
    );
    expect(after.fetched).toEqual(["g/p!7"]);
    expect(store.fixes.open("g/p!7")?.threads.map((each) => each.id)).toEqual(["d2"]);
  });

  it("stops watching an approved MR: a queued fix is cancelled, a ready one is left alone", async () => {
    const store = openStore(":memory:");
    const queued = store.fixes.queue("g/p!7", "auto", [thread("d1", "n1")], 1000) ?? 0;
    const ready = store.fixes.queue("g/p!8", "auto", [thread("d1", "n1")], 1000) ?? 0;
    store.fixes.transition(ready, ["queued"], "ready", {}, 1100);
    const approved = [reviewer("bob", "APPROVED")];
    const run = deps(store, {});
    await queueAutomaticFixes(
      run,
      snapshot({
        authored: [
          mine({ reviewers: approved, notes: [note("n9", bob)] }),
          mr(8, { author: ME, reviewers: approved }),
        ],
      }),
      new Set(),
    );
    expect(run.fetched).toEqual([]);
    expect(store.fixes.get(queued)).toMatchObject({
      status: "cancelled",
      detail: "The MR was approved.",
    });
    expect(store.fixes.get(ready)?.status).toBe("ready");
  });

  it("keeps a queued fix of a failed pipeline when the MR is approved", async () => {
    const store = openStore(":memory:");
    const queued =
      store.fixes.queue("g/p!7", "auto", [], 1000, "MR 7", "", {
        iid: "41",
        url: "https://gitlab.example/g/p/-/pipelines/2921",
        sha: null,
        jobs: [],
        summary: "",
      }) ?? 0;
    await queueAutomaticFixes(
      deps(store, {}),
      snapshot({ authored: [mine({ reviewers: [reviewer("bob", "APPROVED")] })] }),
      new Set(),
    );
    expect(store.fixes.get(queued)?.status).toBe("queued");
  });

  it("reads an approved MR again once it is watched again, so threads written meanwhile are found", async () => {
    const store = openStore(":memory:");
    const details: Record<string, MrDetailJson> = { "g/p!7": detail([]) };
    await queueAutomaticFixes(deps(store, details), snapshot({ authored: [mine()] }), new Set());
    // Bob approves "with nits" and opens a thread in the same poll interval.
    details["g/p!7"] = detail([discussion("d1", [gitlabNote("n1")])]);
    const approved = mine({ reviewers: [reviewer("bob", "APPROVED")], notes: [note("n1", bob)] });
    await queueAutomaticFixes(deps(store, details), snapshot({ authored: [approved] }), new Set());
    // A new Reviewer is added: the MR is watched again, and n1 is no longer new.
    const again = deps(store, details);
    const watched = mine({
      reviewers: [reviewer("bob", "APPROVED"), reviewer("cy", "UNREVIEWED")],
      notes: [note("n1", bob)],
    });
    await queueAutomaticFixes(again, snapshot({ authored: [watched] }), new Set(["n1"]));
    expect(again.fetched).toEqual(["g/p!7"]);
    expect(store.fixes.open("g/p!7")?.threads.map((each) => each.id)).toEqual(["d1"]);
  });

  it("drops the fixes of an MR that is no longer open", async () => {
    const store = openStore(":memory:");
    const queued = store.fixes.queue("g/p!7", "auto", [thread("d1", "n1")], 1000) ?? 0;
    const ready = store.fixes.queue("g/p!8", "auto", [thread("d1", "n1")], 1000) ?? 0;
    store.fixes.transition(ready, ["queued"], "ready", {}, 1100);
    await queueAutomaticFixes(deps(store, {}), snapshot({ authored: [] }), new Set());
    expect(store.fixes.get(queued)).toMatchObject({
      status: "cancelled",
      detail: "The MR is no longer open.",
    });
    expect(store.fixes.get(ready)).toMatchObject({
      status: "discarded",
      detail: "The MR is no longer open.",
    });
  });

  it("queues nothing once the daily limit is reached, and nothing when fix.auto is off", async () => {
    const store = openStore(":memory:");
    const details = { "g/p!7": detail([discussion("d1", [gitlabNote("n1")])]) };
    store.fixes.queue("g/p!1", "auto", [thread("d1", "n1")], 999_000);
    await queueAutomaticFixes(
      deps(store, details, { maxPerDay: 1 }),
      snapshot({ authored: [mine()] }),
      new Set(),
    );
    expect(store.fixes.open("g/p!7")).toBeUndefined();
    const off = deps(store, details, { auto: false });
    await queueAutomaticFixes(off, snapshot({ authored: [mine()] }), new Set());
    expect(off.fetched).toEqual([]);
    expect(store.fixes.open("g/p!7")).toBeUndefined();
  });

  it("logs a failed detail fetch and carries on with the next MR", async () => {
    const store = openStore(":memory:");
    const run = deps(store, { "g/p!8": detail([discussion("d1", [gitlabNote("n1")])], "g/p!8") });
    await queueAutomaticFixes(
      run,
      snapshot({ authored: [mine(), mr(8, { author: ME })] }),
      new Set(),
    );
    expect(run.fetched).toEqual(["g/p!7", "g/p!8"]);
    expect(store.fixes.open("g/p!8")?.status).toBe("queued");
  });
});

describe("queueManualFix", () => {
  it("takes every open thread, says when there is nothing to fix, and waits while a fix is ready", async () => {
    const store = openStore(":memory:");
    store.fixes.markHandled("g/p!7", [{ id: "d1", noteId: "n1" }]);
    const run = deps(store, {
      "g/p!7": detail([discussion("d1", [gitlabNote("n1")])]),
      "g/p!8": detail([discussion("d1", [gitlabNote("n1", ME)])], "g/p!8"),
    });
    expect(await queueManualFix(run, "g/p!7", ME.username)).toBe("queued");
    expect(store.fixes.open("g/p!7")?.trigger).toBe("manual");
    expect(await queueManualFix(run, "g/p!7", ME.username)).toBe("added");
    expect(await queueManualFix(run, "g/p!8", ME.username)).toBe("nothing-to-fix");
    expect(await queueManualFix(run, "nope", ME.username)).toBe("bad-key");
    const id = store.fixes.open("g/p!7")?.id ?? 0;
    store.fixes.transition(id, ["queued"], "ready", {}, 2000);
    expect(await queueManualFix(run, "g/p!7", ME.username)).toBe("busy");
  });

  it("refuses an MR someone else wrote", async () => {
    const store = openStore(":memory:");
    const theirs = { ...detail([discussion("d1", [gitlabNote("n1")])]), author: bob };
    const run = deps(store, { "g/p!7": theirs });
    expect(await queueManualFix(run, "g/p!7", ME.username)).toBe("not-yours");
    expect(store.fixes.open("g/p!7")).toBeUndefined();
  });
});
