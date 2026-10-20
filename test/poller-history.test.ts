import { describe, expect, it } from "vitest";
import type { Snapshot } from "../src/domain.ts";
import { createFailureTracker } from "../src/failures.ts";
import { FetchFailure } from "../src/gitlab.ts";
import { createLogger } from "../src/log.ts";
import type { Notifier } from "../src/notifier.ts";
import { pollOnce } from "../src/poller.ts";
import type { PollDeps } from "../src/poller.ts";
import { openStore } from "../src/store.ts";
import type { HistoryEvent, PollLogEntry, Store } from "../src/store.ts";
import { mr, reviewer, snapshot } from "./builders.ts";

const config: PollDeps["config"] = {
  gitlab: { hostname: "gitlab.example", glabPath: "glab", timeoutSeconds: 60 },
  notifications: { summaryThreshold: 4, ignoreAuthors: [] },
};

function harness(clock: readonly number[] = [1000, 1450], lookupPerson?: PollDeps["lookupPerson"]) {
  const realStore = openStore(":memory:");
  const polls: PollLogEntry[] = [];
  const committed: (readonly HistoryEvent[] | undefined)[] = [];
  const logs: string[] = [];
  let recordError: Error | undefined;
  let current: Snapshot = snapshot();
  let fetchError: Error | undefined;
  let tick = 0;
  const store: Store = {
    ...realStore,
    commit: (next, history, approvals) => {
      committed.push(history);
      realStore.commit(next, history, approvals);
    },
    recordPoll: (entry) => {
      if (recordError !== undefined) throw recordError;
      polls.push(entry);
      realStore.recordPoll(entry);
    },
  };
  const notifier: Notifier = { notify: () => Promise.resolve() };
  const deps: PollDeps = {
    fetchSnapshot: () =>
      fetchError === undefined ? Promise.resolve(current) : Promise.reject(fetchError),
    store,
    notifier,
    failures: createFailureTracker(),
    log: createLogger({ write: (line) => logs.push(line), minLevel: "debug" }),
    config,
    ...(lookupPerson === undefined ? {} : { lookupPerson }),
    now: () => {
      const value = clock[Math.min(tick, clock.length - 1)];
      tick += 1;
      return value ?? 0;
    },
  };
  return {
    store: realStore,
    polls,
    committed,
    logs,
    poll: () => pollOnce(deps),
    setSnapshot: (next: Snapshot) => {
      current = next;
    },
    setFetchError: (error: Error | undefined) => {
      fetchError = error;
    },
    setRecordError: (error: Error | undefined) => {
      recordError = error;
    },
    pause: () => {
      realStore.setPaused(true);
    },
  };
}

describe("pollOnce history", () => {
  it("logs an ok poll with its duration", async () => {
    const h = harness();
    expect(await h.poll()).toBe("ok");
    expect(h.polls).toEqual([{ at: 1000, status: "ok", failure: null, durationMs: 450 }]);
  });

  it("logs a failed fetch with its failure kind", async () => {
    const h = harness();
    h.setFetchError(new FetchFailure("gitlab-unreachable", "no route"));
    expect(await h.poll()).toBe("failed");
    expect(h.polls).toEqual([
      { at: 1000, status: "failed", failure: "gitlab-unreachable", durationMs: 450 },
    ]);
  });

  it("logs an unexpected fetch error as gitlab-error", async () => {
    const h = harness();
    h.setFetchError(new Error("boom"));
    await h.poll();
    expect(h.polls[0]?.failure).toBe("gitlab-error");
  });

  it("does not log a paused poll", async () => {
    const h = harness();
    h.pause();
    expect(await h.poll()).toBe("paused");
    expect(h.polls).toEqual([]);
  });

  it("a failing poll log does not change the poll status", async () => {
    const h = harness();
    h.setRecordError(new Error("disk full: /Users/someone/state.db"));
    expect(await h.poll()).toBe("ok");
    const warns = h.logs.filter((line) => line.includes("poll history not recorded"));
    expect(warns).toHaveLength(1);
    expect(JSON.parse(warns[0] ?? "{}")).toMatchObject({
      level: "warn",
      attributes: { reason: "Error" },
    });
    expect((JSON.parse(warns[0] ?? "{}") as { attributes: unknown }).attributes).toEqual({
      reason: "Error",
    });
    expect(warns[0]).not.toContain("someone");
  });

  it("commits the history events with the snapshot", async () => {
    const h = harness([1000, 1450, 2000, 2300]);
    await h.poll();
    h.setSnapshot(
      snapshot({ reviewRequested: [mr(1, { reviewers: [reviewer("me", "UNREVIEWED")] })] }),
    );
    await h.poll();
    expect(h.committed[0]).toEqual([]);
    expect(h.committed[1]).toEqual([
      { kind: "review-requested", mrKey: "g/p!1", username: "", at: 2000 },
    ]);
    expect(h.store.loadHistory(0).events).toHaveLength(1);
  });

  it("stores the first approval of an Owner's MR with when it was opened", async () => {
    const h = harness([1000, 1450, 2000, 2300]);
    const opened = "1970-01-01T00:00:00.500Z";
    h.setSnapshot(
      snapshot({
        authored: [mr(2, { createdAt: opened, reviewers: [reviewer("bob", "UNREVIEWED")] })],
      }),
    );
    await h.poll();
    h.setSnapshot(
      snapshot({
        authored: [mr(2, { createdAt: opened, reviewers: [reviewer("bob", "APPROVED")] })],
      }),
    );
    await h.poll();
    expect(h.store.loadApprovals(0)).toEqual([
      {
        mrKey: "g/p!2",
        title: "MR 2",
        url: "https://gitlab.example/g/p/-/merge_requests/2",
        openedAt: 500,
        approvedAt: 2000,
        approver: { username: "bob", name: "bob" },
      },
    ]);
  });
});

describe("pollOnce names", () => {
  const reviewedBy = (username: string, at: number): HistoryEvent => ({
    kind: "reviewer-reviewed",
    mrKey: "g/p!2",
    username,
    at,
  });

  it("looks up the history's unnamed people after the poll, and keeps an unknown one as itself", async () => {
    const asked: string[] = [];
    const h = harness([1000, 1450], (username) => {
      asked.push(username);
      return Promise.resolve(username === "20435" ? { username, name: "Ayu Lestari" } : undefined);
    });
    h.store.commit(snapshot(), [reviewedBy("20435", 10), reviewedBy("gone", 5)]);
    expect(await h.poll()).toBe("ok");
    expect(asked).toEqual(["20435", "gone"]);
    expect(h.store.loadNames()).toEqual(
      new Map([
        ["20435", "Ayu Lestari"],
        ["gone", "gone"],
      ]),
    );
    expect(h.store.unnamedUsernames(10)).toEqual([]);
  });

  it("logs a failed lookup without failing the poll, and tries again next time", async () => {
    const h = harness([1000, 1450], () =>
      Promise.reject(new FetchFailure("gitlab-unreachable", "timed out")),
    );
    h.store.commit(snapshot(), [reviewedBy("20435", 10)]);
    expect(await h.poll()).toBe("ok");
    const warns = h.logs.filter((line) => line.includes("names not looked up"));
    expect(warns).toHaveLength(1);
    expect(warns[0]).toContain("gitlab-unreachable");
    expect(h.store.unnamedUsernames(10)).toEqual(["20435"]);
  });
});
