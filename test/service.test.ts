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
  modes: { nudge: "approval", notice: "approval" },
  workingHours: { start: "09:00", end: "17:00", days: [1, 2, 3, 4, 5] },
  reminderAfterHours: 24,
  noticeDebounceMinutes: 10,
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
    expect(result).toEqual({ failure: undefined });
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
    const { service, sent } = setup({
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
    await expect(service.dispatch(withNewReviewer)).resolves.toEqual({ failure: "error" });
  });

  it("reports an unreachable Teams as 'unavailable'", async () => {
    const { service } = setup({
      config: { ...teamsConfig, modes: { nudge: "auto", notice: "auto" } },
      gateway: { session: () => Promise.reject(new TeamsFailure("unavailable", "down")) },
    });
    service.plan(snapshot(), previous());
    service.plan(withNewReviewer, previous());
    await expect(service.dispatch(withNewReviewer)).resolves.toEqual({ failure: "unavailable" });
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
