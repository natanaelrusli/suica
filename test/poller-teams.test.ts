import { describe, expect, it } from "vitest";
import type { Snapshot } from "../src/domain.ts";
import type { PreviousState } from "../src/events.ts";
import { createFailureTracker } from "../src/failures.ts";
import type { Notification } from "../src/format.ts";
import { createLogger } from "../src/log.ts";
import type { Notifier } from "../src/notifier.ts";
import { pollOnce } from "../src/poller.ts";
import type { PollDeps, TeamsHooks } from "../src/poller.ts";
import { openStore } from "../src/store.ts";
import type { Store } from "../src/store.ts";
import type { TeamsFailureKind } from "../src/teams/api.ts";
import { mr, reviewer, snapshot } from "./builders.ts";

const config: PollDeps["config"] = {
  gitlab: { hostname: "gitlab.example", glabPath: "glab", timeoutSeconds: 60 },
  notifications: { summaryThreshold: 4, ignoreAuthors: [] },
};

function harness(options: { planThrows?: boolean } = {}) {
  const realStore = openStore(":memory:");
  const sent: Notification[] = [];
  const events: string[] = [];
  const planned: PreviousState[] = [];
  let dispatchFailure: TeamsFailureKind | undefined;
  let commitError: Error | undefined;
  let current: Snapshot = snapshot();
  const store: Store = {
    ...realStore,
    commit: (next) => {
      if (commitError !== undefined) throw commitError;
      events.push("commit");
      realStore.commit(next);
    },
  };
  const notifier: Notifier = {
    notify: (notification) => {
      sent.push(notification);
      return Promise.resolve();
    },
  };
  const teams: TeamsHooks = {
    plan: (_snapshot, previous) => {
      events.push("plan");
      planned.push(previous);
      if (options.planThrows === true) throw new Error("db");
    },
    dispatch: () => {
      events.push("dispatch");
      return Promise.resolve({ failure: dispatchFailure });
    },
  };
  const deps: PollDeps = {
    fetchSnapshot: () => Promise.resolve(current),
    store,
    notifier,
    failures: createFailureTracker(),
    log: createLogger({ write: () => undefined }),
    config,
    teams,
  };
  return {
    sent,
    events,
    planned,
    poll: () => pollOnce(deps),
    setSnapshot: (next: Snapshot) => {
      current = next;
    },
    setDispatchFailure: (value: TeamsFailureKind | undefined) => {
      dispatchFailure = value;
    },
    setCommitError: (value: Error | undefined) => {
      commitError = value;
    },
  };
}

describe("pollOnce with Teams", () => {
  it("plans and dispatches after the state commit, with the state from before the poll", async () => {
    const h = harness();
    expect(await h.poll()).toBe("ok");
    expect(h.events).toEqual(["commit", "plan", "dispatch"]);
    expect(h.planned[0]?.baselineDone).toBe(false);
  });

  it("does nothing for Teams when the state commit fails, so counters cannot be inflated", async () => {
    const h = harness();
    h.setCommitError(new Error("busy"));
    expect(await h.poll()).toBe("failed");
    expect(h.events).toEqual([]);
  });

  it("reports an unavailable Teams only after two polls in a row, and never changes the poll status", async () => {
    const h = harness();
    h.setDispatchFailure("unavailable");
    expect(await h.poll()).toBe("ok");
    expect(h.sent.map((n) => n.title)).toEqual([]);
    expect(await h.poll()).toBe("ok");
    expect(h.sent.map((n) => n.title)).toEqual(["Teams tidak terhubung"]);
    expect(await h.poll()).toBe("ok");
    expect(h.sent).toHaveLength(1);
  });

  it("reports a Teams error at once, and again only after it has recovered", async () => {
    const h = harness();
    h.setDispatchFailure("error");
    await h.poll();
    await h.poll();
    expect(h.sent.map((n) => n.title)).toEqual(["Teams mengembalikan error"]);
    h.setDispatchFailure(undefined);
    await h.poll();
    h.setDispatchFailure("error");
    await h.poll();
    expect(h.sent).toHaveLength(2);
  });

  it("still delivers Owner notifications and commits when planning fails, and reports the state problem once", async () => {
    const h = harness({ planThrows: true });
    h.setSnapshot(
      snapshot({ reviewRequested: [mr(1, { reviewers: [reviewer("me", "UNREVIEWED")] })] }),
    );
    expect(await h.poll()).toBe("ok");
    expect(h.sent.map((n) => n.title)).toContain("MR Review Assistant aktif");
    expect(h.sent.map((n) => n.title)).toContain("Penyimpanan state bermasalah");
    expect(h.events).toEqual(["commit", "plan"]);
  });
});
