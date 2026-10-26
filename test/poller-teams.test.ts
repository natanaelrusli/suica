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
import type { HeldMessage } from "../src/teams/types.ts";
import { mr, reviewer, snapshot } from "./builders.ts";

const config: PollDeps["config"] = {
  gitlab: { hostname: "gitlab.example", glabPath: "glab", timeoutSeconds: 60 },
  notifications: { summaryThreshold: 4, ignoreAuthors: [] },
};

function harness(options: { planThrows?: boolean; failingNotifier?: boolean } = {}) {
  const realStore = openStore(":memory:");
  const sent: Notification[] = [];
  const attempts: Notification[] = [];
  const logged: string[] = [];
  const events: string[] = [];
  const planned: PreviousState[] = [];
  let dispatchFailure: TeamsFailureKind | undefined;
  let held: readonly HeldMessage[] = [];
  let commitError: Error | undefined;
  let current: Snapshot = snapshot();
  const store: Store = {
    ...realStore,
    commit: (next, history) => {
      if (commitError !== undefined) throw commitError;
      events.push("commit");
      realStore.commit(next, history);
    },
  };
  const notifier: Notifier = {
    notify: (notification) => {
      attempts.push(notification);
      if (options.failingNotifier === true) {
        // A process error embeds the command line, so it carries the notification text.
        return Promise.reject(
          Object.assign(
            new Error(`Command failed: terminal-notifier -message ${notification.body}`),
            {
              code: 1,
            },
          ),
        );
      }
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
      // Like the real dispatch, a row is reported as held in one poll only.
      const reported = held;
      held = [];
      return Promise.resolve({ failure: dispatchFailure, held: reported });
    },
  };
  const deps: PollDeps = {
    fetchSnapshot: () => Promise.resolve(current),
    store,
    notifier,
    failures: createFailureTracker(),
    log: createLogger({ write: (line) => logged.push(line) }),
    config,
    teams,
    now: () => 0,
  };
  return {
    sent,
    attempts,
    logged,
    events,
    planned,
    poll: () => pollOnce(deps),
    setSnapshot: (next: Snapshot) => {
      current = next;
    },
    setDispatchFailure: (value: TeamsFailureKind | undefined) => {
      dispatchFailure = value;
    },
    setHeld: (value: readonly HeldMessage[]) => {
      held = value;
    },
    setCommitError: (value: Error | undefined) => {
      commitError = value;
    },
  };
}

const heldRereview = (id: number, name: string, mrKey = "g/p!5"): HeldMessage => ({
  id,
  kind: "rereview",
  mrKey,
  mrTitle: `Title of ${mrKey}`,
  recipientName: name,
});

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
    expect(h.sent.map((n) => n.title)).toEqual(["🔌 Teams tidak terhubung"]);
    expect(await h.poll()).toBe("ok");
    expect(h.sent).toHaveLength(1);
  });

  it("reports a Teams error at once, and again only after it has recovered", async () => {
    const h = harness();
    h.setDispatchFailure("error");
    await h.poll();
    await h.poll();
    expect(h.sent.map((n) => n.title)).toEqual(["⚠️ Teams mengembalikan error"]);
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
    expect(h.sent.map((n) => n.title)).toContain("🚃 Suica aktif");
    expect(h.sent.map((n) => n.title)).toContain("⚠️ Penyimpanan state bermasalah");
    expect(h.events).toEqual(["commit", "plan"]);
  });

  it("tells the Owner once per MR about Re-review Nudges that started waiting, after dispatch", async () => {
    const h = harness();
    await h.poll();
    h.sent.length = 0;
    h.setHeld([heldRereview(7, "Bob"), heldRereview(8, "Carol"), heldRereview(9, "Erin", "g/p!8")]);
    expect(await h.poll()).toBe("ok");
    expect(h.sent).toEqual([
      {
        title: "🔁 Minta review ulang?",
        body: "Kamu push ke Title of g/p!5 setelah Bob dan Carol review. Kirim pesan Teams?",
        url: "suica://messages",
        sound: "Glass",
      },
      {
        title: "🔁 Minta review ulang?",
        body: "Kamu push ke Title of g/p!8 setelah Erin review. Kirim pesan Teams?",
        url: "suica://message/9",
        sound: "Glass",
      },
    ]);
  });

  it("sends no notification when nothing started waiting, as in auto and dry-run mode", async () => {
    const h = harness();
    await h.poll();
    await h.poll();
    expect(h.sent).toEqual([]);
  });

  it("does not notify about the other kinds of held messages", async () => {
    const h = harness();
    h.setHeld([{ ...heldRereview(1, "Bob"), kind: "nudge" }]);
    await h.poll();
    expect(h.sent).toEqual([]);
  });

  it("logs a failed notification without names or titles, keeps the poll ok and never repeats it", async () => {
    const h = harness({ failingNotifier: true });
    h.setHeld([heldRereview(7, "Bob")]);
    expect(await h.poll()).toBe("ok");
    const warnings = h.logged.filter((line) => line.includes("re-review notification"));
    expect(warnings).toHaveLength(1);
    expect(warnings[0]).toContain('"level":"warn"');
    expect(warnings[0]).toContain('"code":"1"');
    expect(h.logged.join("\n")).not.toContain("Bob");
    expect(h.logged.join("\n")).not.toContain("Title of");
    await h.poll();
    await h.poll();
    expect(h.attempts).toHaveLength(1);
  });

  it("still reports a Teams failure when it also has notifications to send", async () => {
    const h = harness();
    h.setHeld([heldRereview(7, "Bob")]);
    h.setDispatchFailure("error");
    await h.poll();
    expect(h.sent.map((n) => n.title)).toEqual([
      "🔁 Minta review ulang?",
      "⚠️ Teams mengembalikan error",
    ]);
  });
});
