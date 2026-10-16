import { describe, expect, it } from "vitest";
import type { MergeRequest, Snapshot } from "../src/domain.ts";
import { createFailureTracker } from "../src/failures.ts";
import type { Notification } from "../src/format.ts";
import { FetchFailure } from "../src/gitlab.ts";
import { createLogger } from "../src/log.ts";
import type { Notifier } from "../src/notifier.ts";
import { pollOnce } from "../src/poller.ts";
import type { PollDeps } from "../src/poller.ts";
import { openStore } from "../src/store.ts";
import type { Store } from "../src/store.ts";
import { ME, mr, note, person, reviewer, snapshot } from "./builders.ts";

const config: PollDeps["config"] = {
  gitlab: { hostname: "gitlab.example", glabPath: "glab", timeoutSeconds: 60 },
  notifications: { summaryThreshold: 4, ignoreAuthors: [] },
};

function harness() {
  const realStore = openStore(":memory:");
  const sent: Notification[] = [];
  const logs: string[] = [];
  let failAfter = Number.POSITIVE_INFINITY;
  let commitError: Error | undefined;
  let current: Snapshot = snapshot();
  let fetchError: Error | undefined;
  let fetchCount = 0;
  const store: Store = {
    ...realStore,
    commit: (next, history) => {
      if (commitError !== undefined) throw commitError;
      realStore.commit(next, history);
    },
  };
  const notifier: Notifier = {
    notify: (notification) => {
      if (sent.length >= failAfter) return Promise.reject(new Error("boom"));
      sent.push(notification);
      return Promise.resolve();
    },
  };
  const deps: PollDeps = {
    fetchSnapshot: () => {
      fetchCount += 1;
      return fetchError === undefined ? Promise.resolve(current) : Promise.reject(fetchError);
    },
    store,
    notifier,
    failures: createFailureTracker(),
    log: createLogger({ write: (line) => logs.push(line), minLevel: "debug" }),
    config,
    now: () => 0,
  };
  return {
    store: realStore,
    sent,
    logs,
    poll: () => pollOnce(deps),
    fetchCount: () => fetchCount,
    setSnapshot: (next: Snapshot) => {
      current = next;
    },
    setFetchError: (error: Error | undefined) => {
      fetchError = error;
    },
    setNotifierFailing: (value: boolean) => {
      failAfter = value ? 0 : Number.POSITIVE_INFINITY;
    },
    /** Delivers this many notifications, then fails every further one. */
    setNotifierFailAfter: (count: number) => {
      failAfter = count;
    },
    setCommitError: (error: Error | undefined) => {
      commitError = error;
    },
  };
}

const waiting = (iid: number) => mr(iid, { reviewers: [reviewer("me", "UNREVIEWED")] });

describe("pollOnce", () => {
  it("records a silent baseline with one summary, then stays quiet", async () => {
    const h = harness();
    h.setSnapshot(snapshot({ reviewRequested: [waiting(1), waiting(2)] }));
    expect(await h.poll()).toBe("ok");
    expect(h.sent).toEqual([{ title: "Suica aktif", body: "2 MR menunggu review-mu" }]);
    expect(await h.poll()).toBe("ok");
    expect(h.sent).toHaveLength(1);
  });

  it("notifies about a review request that appears after the baseline", async () => {
    const h = harness();
    await h.poll();
    h.setSnapshot(snapshot({ reviewRequested: [waiting(3)] }));
    await h.poll();
    expect(h.sent).toEqual([
      {
        title: "Diminta review: MR 3",
        body: "Author · g/p",
        url: "https://gitlab.example/g/p/-/merge_requests/3",
      },
    ]);
  });

  it("alerts about activity on the Owner's own MR", async () => {
    const h = harness();
    const own = (overrides: Partial<MergeRequest> = {}): MergeRequest =>
      mr(5, { author: ME, reviewers: [reviewer("bob", "UNREVIEWED", "Bob")], ...overrides });
    h.setSnapshot(snapshot({ authored: [own()] }));
    await h.poll();
    h.setSnapshot(
      snapshot({
        authored: [
          own({
            reviewers: [reviewer("bob", "APPROVED", "Bob")],
            notes: [note("n1", person("bob", "Bob"))],
          }),
        ],
      }),
    );
    await h.poll();
    expect(h.sent).toHaveLength(1);
    expect(h.sent[0]?.body).toBe("Bob menyetujui; 1 komentar baru dari Bob");
  });

  it("wake catch-up: many changes at once become one summary", async () => {
    const h = harness();
    await h.poll();
    h.setSnapshot(snapshot({ reviewRequested: [1, 2, 3, 4, 5, 6].map(waiting) }));
    await h.poll();
    expect(h.sent).toHaveLength(1);
    expect(h.sent[0]?.title).toBe("6 aktivitas MR baru");
  });

  it("notifier failure keeps state uncommitted so the events are retried, and never logs the text", async () => {
    const h = harness();
    h.setSnapshot(
      snapshot({
        reviewRequested: [
          mr(1, { title: "Secret title", reviewers: [reviewer("me", "UNREVIEWED")] }),
        ],
      }),
    );
    h.setNotifierFailing(true);
    expect(await h.poll()).toBe("failed");
    expect(h.store.load().baselineDone).toBe(false);
    expect(h.logs.join("\n")).not.toContain("Secret title");
    h.setNotifierFailing(false);
    expect(await h.poll()).toBe("ok");
    expect(h.sent).toHaveLength(1);
  });

  it("a partial delivery is committed so delivered alerts are never repeated", async () => {
    const h = harness();
    await h.poll();
    h.setSnapshot(snapshot({ reviewRequested: [waiting(1), waiting(2)] }));
    h.setNotifierFailAfter(1);
    expect(await h.poll()).toBe("failed");
    expect(h.sent).toHaveLength(1);
    h.setNotifierFailAfter(Number.POSITIVE_INFINITY);
    expect(await h.poll()).toBe("ok");
    expect(h.sent).toHaveLength(1);
  });

  it("a failing state commit is reported to the Owner once instead of repeating alerts silently", async () => {
    const h = harness();
    await h.poll();
    h.setSnapshot(snapshot({ reviewRequested: [waiting(1)] }));
    h.setCommitError(new Error("database is locked"));
    expect(await h.poll()).toBe("failed");
    expect(await h.poll()).toBe("failed");
    const stateAlerts = h.sent.filter((n) => n.title === "Penyimpanan state bermasalah");
    expect(stateAlerts).toHaveLength(1);
    expect(h.logs.join("\n")).not.toContain("database is locked");
  });

  it("tells the Owner about a GitLab failure once, and again only after recovery", async () => {
    const h = harness();
    h.setFetchError(new FetchFailure("gitlab-auth", "no current user"));
    expect(await h.poll()).toBe("failed");
    expect(await h.poll()).toBe("failed");
    expect(h.sent).toHaveLength(1);
    expect(h.sent[0]?.title).toBe("Login GitLab gagal");
    h.setFetchError(undefined);
    expect(await h.poll()).toBe("ok");
    h.setFetchError(new FetchFailure("gitlab-auth", "no current user"));
    await h.poll();
    expect(h.sent).toHaveLength(2);
  });

  it("waits for a second consecutive failure before reporting 'unreachable' (network after wake)", async () => {
    const h = harness();
    h.setFetchError(new FetchFailure("gitlab-unreachable", "glab failed with code 1"));
    await h.poll();
    expect(h.sent).toHaveLength(0);
    await h.poll();
    expect(h.sent).toHaveLength(1);
    expect(h.sent[0]?.title).toBe("GitLab tidak terjangkau");
    await h.poll();
    expect(h.sent).toHaveLength(1);
  });

  it("does not touch GitLab while paused", async () => {
    const h = harness();
    h.store.setPaused(true);
    expect(await h.poll()).toBe("paused");
    expect(h.fetchCount()).toBe(0);
  });
});
