import { describe, expect, it } from "vitest";
import { createLogger } from "../src/log.ts";
import { openStore } from "../src/store.ts";
import { TeamsFailure } from "../src/teams/api.ts";
import type { TeamsApi } from "../src/teams/api.ts";
import { createTeamsService } from "../src/teams/service.ts";
import type { ServiceDeps } from "../src/teams/service.ts";
import { DEFAULT_TEMPLATES } from "../src/teams/templates.ts";
import { ME, mr, previous, reviewer, snapshot } from "./builders.ts";

const WORKING = new Date(2026, 9, 14, 10, 0).getTime();
const teamsConfig: ServiceDeps["config"] = {
  enabled: true,
  startTimeoutSeconds: 30,
  callTimeoutSeconds: 60,
  modes: { nudge: "approval", notice: "approval", rereview: "approval" },
  workingHours: { start: "09:00", end: "17:00", days: [1, 2, 3, 4, 5] },
  reminderAfterHours: 24,
  noticeDebounceMinutes: 10,
  rereviewAfterMinutes: 10,
  maxMessagesPerReviewer: 2,
  people: {},
};

function setup(overrides: Partial<ServiceDeps> = {}) {
  const store = openStore(":memory:");
  const sent: string[] = [];
  const api: TeamsApi = {
    searchUsers: () => Promise.resolve([]),
    openChat: () => Promise.resolve("chat"),
    sendMessage: (_chat, text) => {
      sent.push(text);
      return Promise.resolve("m");
    },
  };
  const service = createTeamsService({
    store,
    gateway: { session: (use) => use(api) },
    templates: DEFAULT_TEMPLATES,
    config: teamsConfig,
    log: createLogger({ write: () => undefined }),
    now: () => WORKING,
    ...overrides,
  });
  return { service, store, sent };
}

const withNewReviewer = snapshot({
  authored: [mr(5, { author: ME, reviewers: [reviewer("bob", "UNREVIEWED", "Bob")] })],
});

describe("createTeamsService", () => {
  it("plans a nudge for a new Reviewer and holds it for approval", async () => {
    const { service, store } = setup();
    // Teams baseline first (nothing is announced), then a Reviewer appears.
    service.plan(snapshot(), previous());
    service.plan(withNewReviewer, previous());
    expect(store.listOutbox(["queued"])).toHaveLength(1);
    const result = await service.dispatch(withNewReviewer);
    expect(result.failure).toBeUndefined();
    expect(result.held.map((row) => row.kind)).toEqual(["nudge"]);
    expect(service.list(false).map((row) => [row.status, row.kind])).toEqual([
      ["pending", "nudge"],
    ]);
  });

  it("lists only rows that need attention unless asked for all", async () => {
    const { service } = setup();
    service.plan(snapshot(), previous());
    service.plan(withNewReviewer, previous());
    expect(service.list(false)).toHaveLength(0);
    expect(service.list(true)).toHaveLength(1);
    await service.dispatch(withNewReviewer);
    expect(service.list(false)).toHaveLength(1);
  });

  it("sends a pending row on request, and skips or retries rows", async () => {
    const { service, store, sent } = setup({
      gateway: {
        session: (use) =>
          use({
            searchUsers: () =>
              Promise.resolve([
                { displayName: "Bob", userPrincipalName: "b@x", mail: "b@x", id: "1" },
              ]),
            openChat: () => Promise.resolve("chat"),
            sendMessage: (_c, text) => {
              sent.push(text);
              return Promise.resolve("m");
            },
          }),
      },
    });
    service.plan(snapshot(), previous());
    service.plan(withNewReviewer, previous());
    store.commit(withNewReviewer); // the poller commits before it plans; `suica send` reads that state
    await service.dispatch(withNewReviewer);
    const id = service.list(false)[0]?.id ?? 0;
    expect(await service.sendPending(id)).toEqual({ status: "sent" });
    expect(sent).toHaveLength(1);
    expect(service.skip(id)).toBe(false);
    expect(service.retry(id)).toBe(false);
  });

  it("turns an unexpected crash while dispatching into a reported failure instead of throwing", async () => {
    const { service } = setup({
      store: {
        ...openStore(":memory:"),
        listOutbox: () => {
          throw new Error("disk");
        },
      },
    });
    await expect(service.dispatch(withNewReviewer)).resolves.toEqual({
      failure: "error",
      held: [],
    });
  });

  it("reports an unreachable Teams as 'unavailable'", async () => {
    const { service } = setup({
      config: { ...teamsConfig, modes: { nudge: "auto", notice: "auto", rereview: "auto" } },
      gateway: { session: () => Promise.reject(new TeamsFailure("unavailable", "down")) },
    });
    service.plan(snapshot(), previous());
    service.plan(withNewReviewer, previous());
    await expect(service.dispatch(withNewReviewer)).resolves.toEqual({
      failure: "unavailable",
      held: [],
    });
  });

  it("sends a connection test to the Owner's own notes chat", async () => {
    const calls: string[] = [];
    const { service } = setup({
      gateway: {
        session: (use) =>
          use({
            searchUsers: () => Promise.resolve([]),
            openChat: () => Promise.resolve("never"),
            sendMessage: (chatId) => {
              calls.push(chatId);
              return Promise.resolve("m");
            },
          }),
      },
    });
    await service.selfTest();
    expect(calls).toEqual(["48:notes"]);
  });
});

describe("Re-review Nudge through the service", () => {
  /** Polls the way the poller does: load the previous state, commit the snapshot, plan, dispatch. */
  function agent(mode: "approval" | "auto") {
    let clock = WORKING;
    const sent: string[] = [];
    const { service, store } = setup({
      now: () => clock,
      config: {
        ...teamsConfig,
        modes: { nudge: "approval", notice: "approval", rereview: mode },
        people: { bob: "bob@x.id" },
      },
      gateway: {
        session: (use) =>
          use({
            searchUsers: () => Promise.resolve([]),
            openChat: () => Promise.resolve("chat"),
            sendMessage: (_chat, text) => {
              sent.push(text);
              return Promise.resolve("m");
            },
          }),
      },
    });
    return {
      service,
      sent,
      async poll(afterMinutes: number, head: string, state: string) {
        clock += afterMinutes * 60_000;
        const current = snapshot({
          authored: [
            mr(5, { author: ME, headSha: head, reviewers: [reviewer("bob", state, "Bob")] }),
          ],
        });
        const before = store.load();
        store.commit(current);
        service.plan(current, before);
        return service.dispatch(current);
      },
    };
  }

  /** Bob approves h1, the Owner pushes h2, and the push has stood for the debounce. */
  async function afterPush(mode: "approval" | "auto") {
    const a = agent(mode);
    await a.poll(0, "h1", "UNREVIEWED");
    await a.poll(2, "h1", "APPROVED");
    await a.poll(2, "h2", "APPROVED");
    const early = await a.poll(9, "h2", "APPROVED");
    expect(early.held).toEqual([]);
    return a;
  }

  it("holds the nudge for approval and reports it as held in that poll only", async () => {
    const a = await afterPush("approval");
    const due = await a.poll(1, "h2", "APPROVED");
    expect(due.held.map((row) => [row.kind, row.recipientName])).toEqual([["rereview", "Bob"]]);
    expect(a.service.list(false).map((row) => [row.status, row.kind])).toEqual([
      ["pending", "rereview"],
    ]);
    expect((await a.poll(2, "h2", "APPROVED")).held).toEqual([]);
    expect(a.sent).toEqual([]);
  });

  it("sends it at once in auto mode and has nothing to tell the Owner", async () => {
    const a = await afterPush("auto");
    const due = await a.poll(1, "h2", "APPROVED");
    expect(due.held).toEqual([]);
    expect(a.sent).toHaveLength(1);
    expect(a.sent[0]).toContain("MR ini sudah saya update sesuai review-mu");
  });

  it("makes a waiting nudge obsolete when the Reviewer reviews again", async () => {
    const a = await afterPush("approval");
    await a.poll(1, "h2", "APPROVED");
    await a.poll(2, "h2", "REQUESTED_CHANGES");
    expect(a.service.list(false)).toEqual([]);
    expect(a.service.list(true).map((row) => [row.status, row.detail])).toEqual([
      ["skipped", "obsolete"],
    ]);
  });

  it("makes a waiting nudge obsolete when GitLab's re-request leaves the head alone, and sends the plain nudge instead", async () => {
    const a = await afterPush("approval");
    await a.poll(1, "h2", "APPROVED");
    const reRequested = await a.poll(2, "h2", "UNREVIEWED");
    expect(reRequested.held.map((row) => row.kind)).toEqual(["nudge"]);
    expect(a.service.list(true).map((row) => [row.kind, row.status])).toEqual([
      ["rereview", "skipped"],
      ["nudge", "pending"],
    ]);
  });

  it("never sends the plain nudge as well when the push itself reset the approval", async () => {
    const a = agent("approval");
    await a.poll(0, "h1", "UNREVIEWED");
    await a.poll(2, "h1", "APPROVED");
    expect((await a.poll(2, "h2", "UNREVIEWED")).held).toEqual([]);
    expect(a.service.list(true)).toEqual([]);
    const due = await a.poll(10, "h2", "UNREVIEWED");
    expect(due.held.map((row) => row.kind)).toEqual(["rereview"]);
    expect(a.service.list(true).map((row) => row.kind)).toEqual(["rereview"]);
  });
});
