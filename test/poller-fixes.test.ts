import { describe, expect, it } from "vitest";
import { createFailureTracker } from "../src/failures.ts";
import { createLogger } from "../src/log.ts";
import { pollOnce } from "../src/poller.ts";
import type { PollDeps } from "../src/poller.ts";
import { openStore } from "../src/store.ts";
import type { Snapshot } from "../src/domain.ts";
import type { PreviousState } from "../src/events.ts";
import { ME, mr, note, person, snapshot } from "./builders.ts";

function harness(queueFixes: (snapshot: Snapshot, previous: PreviousState) => Promise<void>) {
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
    queueFixes,
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

describe("Agent Fix after a poll", () => {
  it("hands over each snapshot after the baseline, with the notes seen before that poll", async () => {
    const seen: { authored: string[]; notes: string[] }[] = [];
    const h = harness((snap, previous) => {
      seen.push({ authored: snap.authored.map((m) => m.key), notes: [...previous.seenNotes] });
      return Promise.resolve();
    });
    const mine = mr(7, { author: ME, notes: [note("n1", person("bob"))] });
    h.set(snapshot({ authored: [mine] }));
    await h.poll();
    await h.poll();
    expect(seen).toEqual([{ authored: ["g/p!7"], notes: ["n1"] }]);
  });

  it("never fails the poll when queueing fixes throws", async () => {
    const h = harness(() => Promise.reject(new TypeError("boom")));
    await h.poll();
    expect(await h.poll()).toBe("ok");
    expect(h.logs.some((line) => line.includes("agent fix not queued"))).toBe(true);
  });
});
