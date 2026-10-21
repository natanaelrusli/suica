import { describe, expect, it } from "vitest";
import type { Config } from "../src/config.ts";
import type { Pipeline } from "../src/domain.ts";
import type { Notification } from "../src/format.ts";
import { createLogger } from "../src/log.ts";
import { newlyFailed, queuePipelineFix, watchPipelines } from "../src/pipeline-watch.ts";
import { openStore } from "../src/store.ts";
import type { Store } from "../src/store.ts";
import { ME, mr, snapshot } from "./builders.ts";
import { thread } from "./fix-builders.ts";

const NOW = 10 * 86_400_000;
const quietLog = createLogger({ write: () => undefined });

const pipeline = (iid: string, status: string): Pipeline => ({
  iid,
  status,
  url: `https://gitlab.example/g/p/-/pipelines/${iid}`,
});
const mine = (iid: number, pipe: Pipeline | null) => mr(iid, { author: ME, pipeline: pipe });

function deps(store: Store, fix: Partial<Config["fix"]> = {}) {
  const notifications: Notification[] = [];
  return {
    notifications,
    deps: {
      store,
      config: {
        fix: {
          auto: true,
          pipelines: true,
          effort: "medium" as const,
          timeoutMinutes: 20,
          maxPerDay: 10,
          ...fix,
        },
      },
      notifier: {
        notify: (n: Notification) => {
          notifications.push(n);
          return Promise.resolve();
        },
      },
      log: quietLog,
      now: () => NOW,
    },
  };
}

describe("newlyFailed", () => {
  const before = new Map([
    ["g/p!1", { iid: "10", status: "RUNNING" }],
    ["g/p!2", { iid: "20", status: "FAILED" }],
    ["g/p!3", { iid: "30", status: "FAILED" }],
  ]);

  it("finds a pipeline that went from running to failed, and a new pipeline that failed", () => {
    const keys = newlyFailed(
      [
        mine(1, pipeline("10", "FAILED")),
        mine(2, pipeline("20", "FAILED")),
        mine(3, pipeline("31", "FAILED")),
        mine(4, pipeline("40", "FAILED")),
        mine(5, pipeline("50", "SUCCESS")),
        mine(6, null),
      ],
      before,
    ).map((each) => each.key);
    expect(keys).toEqual(["g/p!1", "g/p!3", "g/p!4"]);
  });

  it("stays quiet on the first watch, when no pipeline was recorded yet", () => {
    expect(newlyFailed([mine(1, pipeline("10", "FAILED"))], new Map())).toEqual([]);
  });
});

describe("watchPipelines", () => {
  it("records first, then tells the Owner and queues a fix once when a pipeline fails", async () => {
    const store = openStore(":memory:");
    const { deps: run, notifications } = deps(store);
    await watchPipelines(run, snapshot({ authored: [mine(7, pipeline("41", "RUNNING"))] }));
    expect(notifications).toEqual([]);
    await watchPipelines(run, snapshot({ authored: [mine(7, pipeline("41", "FAILED"))] }));
    await watchPipelines(run, snapshot({ authored: [mine(7, pipeline("41", "FAILED"))] }));
    expect(notifications.map((n) => n.title)).toEqual(["Pipeline gagal: MR 7"]);
    expect(notifications[0]?.body).toBe("!7 · g/p");
    const fix = store.fixes.open("g/p!7");
    expect(fix).toMatchObject({
      status: "queued",
      trigger: "auto",
      threads: [],
      mrTitle: "MR 7",
      pipeline: { iid: "41", url: "https://gitlab.example/g/p/-/pipelines/41", sha: null },
    });
  });

  it("only tells the Owner when fix.auto or fix.pipelines is off", async () => {
    for (const fix of [{ auto: false }, { pipelines: false }]) {
      const store = openStore(":memory:");
      const { deps: run, notifications } = deps(store, fix);
      await watchPipelines(run, snapshot({ authored: [mine(7, pipeline("41", "RUNNING"))] }));
      await watchPipelines(run, snapshot({ authored: [mine(7, pipeline("41", "FAILED"))] }));
      expect(notifications).toHaveLength(1);
      expect(store.fixes.open("g/p!7")).toBeUndefined();
    }
  });

  it("joins a queued fix, and leaves an MR alone whose fix runs or waits for the Owner", async () => {
    const store = openStore(":memory:");
    const queued = store.fixes.queue("g/p!7", "auto", [thread("d1", "n1")], NOW) ?? 0;
    const ready = store.fixes.queue("g/p!8", "auto", [thread("d1", "n1")], NOW) ?? 0;
    store.fixes.transition(ready, ["queued"], "ready", {}, NOW);
    const { deps: run } = deps(store);
    const running = [mine(7, pipeline("41", "RUNNING")), mine(8, pipeline("42", "RUNNING"))];
    await watchPipelines(run, snapshot({ authored: running }));
    await watchPipelines(
      run,
      snapshot({
        authored: [mine(7, pipeline("41", "FAILED")), mine(8, pipeline("42", "FAILED"))],
      }),
    );
    expect(store.fixes.get(queued)?.pipeline?.iid).toBe("41");
    expect(store.fixes.get(queued)?.threads).toHaveLength(1);
    expect(store.fixes.get(ready)?.pipeline).toBeNull();
    expect(store.fixes.list(0)).toHaveLength(2);
  });

  it("stops at the daily cap of automatic fixes", async () => {
    const store = openStore(":memory:");
    const done = store.fixes.queue("g/p!1", "auto", [thread("d1", "n1")], NOW) ?? 0;
    store.fixes.transition(done, ["queued"], "pushed", {}, NOW);
    const { deps: run, notifications } = deps(store, { maxPerDay: 1 });
    await watchPipelines(run, snapshot({ authored: [mine(7, pipeline("41", "RUNNING"))] }));
    await watchPipelines(run, snapshot({ authored: [mine(7, pipeline("41", "FAILED"))] }));
    expect(notifications).toHaveLength(1);
    expect(store.fixes.open("g/p!7")).toBeUndefined();
  });

  it("keeps the mark of an MR that shows no pipeline for now, and forgets closed MRs", async () => {
    const store = openStore(":memory:");
    const { deps: run, notifications } = deps(store);
    await watchPipelines(
      run,
      snapshot({
        authored: [mine(7, pipeline("41", "RUNNING")), mine(8, pipeline("50", "SUCCESS"))],
      }),
    );
    await watchPipelines(run, snapshot({ authored: [mine(7, null)] }));
    expect(store.fixes.pipelineMarks()).toEqual(
      new Map([["g/p!7", { iid: "41", status: "RUNNING" }]]),
    );
    await watchPipelines(run, snapshot({ authored: [mine(7, pipeline("41", "FAILED"))] }));
    expect(notifications).toHaveLength(1);
  });
});

describe("queuePipelineFix", () => {
  const head = (author: string, status: string | null) => () =>
    Promise.resolve({
      title: "Add thing",
      author,
      pipeline: status === null ? null : pipeline("41", status),
    });
  const run = (store: Store, author = "me", status: string | null = "FAILED") => ({
    store,
    log: quietLog,
    now: () => NOW,
    head: head(author, status),
  });

  it("queues a fix of the failed head pipeline of your own MR", async () => {
    const store = openStore(":memory:");
    expect(await queuePipelineFix(run(store), "g/p!7", "me")).toBe("queued");
    expect(store.fixes.open("g/p!7")).toMatchObject({
      trigger: "manual",
      mrTitle: "Add thing",
      pipeline: { iid: "41" },
    });
    expect(await queuePipelineFix(run(store), "g/p!7", "me")).toBe("added");
  });

  it("refuses a bad key, someone else's MR, a pipeline that did not fail and a busy MR", async () => {
    const store = openStore(":memory:");
    expect(await queuePipelineFix(run(store), "g/p!x", "me")).toBe("bad-key");
    expect(await queuePipelineFix(run(store, "bob"), "g/p!7", "me")).toBe("not-yours");
    expect(await queuePipelineFix(run(store, "me", "SUCCESS"), "g/p!7", "me")).toBe(
      "no-failed-pipeline",
    );
    expect(await queuePipelineFix(run(store, "me", null), "g/p!7", "me")).toBe(
      "no-failed-pipeline",
    );
    const id = store.fixes.queue("g/p!7", "auto", [thread("d1", "n1")], NOW) ?? 0;
    store.fixes.transition(id, ["queued"], "running", {}, NOW);
    expect(await queuePipelineFix(run(store), "g/p!7", "me")).toBe("busy");
  });
});
