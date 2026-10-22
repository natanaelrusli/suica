import { describe, expect, it } from "vitest";
import { createFailureTracker } from "../src/failures.ts";
import { createLogger } from "../src/log.ts";
import { pollOnce } from "../src/poller.ts";
import type { PollDeps } from "../src/poller.ts";
import { openStore } from "../src/store.ts";
import type { Snapshot } from "../src/domain.ts";
import { mr, reviewer, snapshot } from "./builders.ts";

function harness(
  queueReviews: (snapshot: Snapshot, newRequests: readonly string[]) => void,
  recheckApprovals?: (snapshot: Snapshot) => void,
) {
  let current: Snapshot = snapshot();
  const logs: string[] = [];
  const deps: PollDeps = {
    fetchSnapshot: () => Promise.resolve(current),
    store: openStore(":memory:"),
    notifier: { notify: () => Promise.resolve() },
    failures: createFailureTracker(),
    log: createLogger({ write: (line) => logs.push(line), minLevel: "debug" }),
    config: {
      gitlab: { hostname: "h", glabPath: "glab", timeoutSeconds: 60 },
      notifications: { summaryThreshold: 4, ignoreAuthors: [] },
    },
    queueReviews,
    ...(recheckApprovals === undefined ? {} : { recheckApprovals }),
    now: () => 0,
  };
  return {
    logs,
    poll: () => pollOnce(deps),
    set: (next: Snapshot) => {
      current = next;
    },
  };
}

const waiting = (iid: number, draft = false) =>
  mr(iid, { draft, reviewers: [reviewer("me", "UNREVIEWED")] });

describe("review requests and Agent Review", () => {
  it("hands over every snapshot, with the MRs that newly asked for your review after the baseline", async () => {
    const seen: { waiting: string[]; asked: string[] }[] = [];
    const h = harness((snap, asked) =>
      seen.push({ waiting: snap.reviewRequested.map((m) => m.key), asked: [...asked] }),
    );
    h.set(snapshot({ reviewRequested: [waiting(1)] }));
    await h.poll();
    h.set(snapshot({ reviewRequested: [waiting(1), waiting(2), waiting(3, true)] }));
    await h.poll();
    await h.poll();
    expect(seen).toEqual([
      { waiting: ["g/p!1"], asked: [] },
      { waiting: ["g/p!1", "g/p!2", "g/p!3"], asked: ["g/p!2"] },
      { waiting: ["g/p!1", "g/p!2", "g/p!3"], asked: [] },
    ]);
  });

  it("keeps the poll ok when queueing fails", async () => {
    const h = harness(() => {
      throw new Error("db");
    });
    h.set(snapshot());
    await h.poll();
    h.set(snapshot({ reviewRequested: [waiting(4)] }));
    expect(await h.poll()).toBe("ok");
    expect(h.logs.some((line) => line.includes("agent review not queued"))).toBe(true);
  });

  it("starts the approval recheck with every snapshot, and keeps the poll ok when it throws", async () => {
    const seen: string[][] = [];
    const h = harness(
      () => undefined,
      (snap) => seen.push(snap.reviewRequested.map((m) => m.key)),
    );
    h.set(snapshot({ reviewRequested: [waiting(1)] }));
    await h.poll();
    await h.poll();
    expect(seen).toEqual([["g/p!1"], ["g/p!1"]]);

    const failing = harness(
      () => undefined,
      () => {
        throw new Error("db");
      },
    );
    expect(await failing.poll()).toBe("ok");
    expect(failing.logs.some((line) => line.includes("approval recheck not started"))).toBe(true);
  });
});
