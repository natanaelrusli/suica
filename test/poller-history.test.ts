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

function harness(clock: readonly number[] = [1000, 1450]) {
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
    commit: (next, history) => {
      committed.push(history);
      realStore.commit(next, history);
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
});
