import { describe, expect, it } from "vitest";
import { createLogger } from "../src/log.ts";
import { openStore } from "../src/store.ts";
import type { Store } from "../src/store.ts";
import { TeamsFailure } from "../src/teams/api.ts";
import type { TeamsApi } from "../src/teams/api.ts";
import { dispatchQueued, retryOutbox, sendPending, skipOutbox } from "../src/teams/dispatch.ts";
import type { DispatchDeps, SendMode } from "../src/teams/dispatch.ts";
import type { TeamsGateway } from "../src/teams/gateway.ts";
import { DEFAULT_TEMPLATES } from "../src/teams/templates.ts";
import { ME, mr, person, reviewer, snapshot } from "./builders.ts";
import { NOW, intent, teamsPlan } from "./teams-builders.ts";

// Local times: Wednesday 10:00 is inside the default hours, Wednesday 20:00 is not.
const WORKING = new Date(2026, 9, 14, 10, 0).getTime();
const EVENING = new Date(2026, 9, 14, 20, 0).getTime();
const hours = { start: "09:00", end: "17:00", days: [1, 2, 3, 4, 5] };

function setup(options: { mode?: SendMode; now?: number; api?: Partial<TeamsApi> } = {}) {
  const store = openStore(":memory:");
  const sent: { chatId: string; text: string }[] = [];
  const opened: string[] = [];
  let sessions = 0;
  const api: TeamsApi = {
    searchUsers: () =>
      Promise.resolve([
        { displayName: "Bob", userPrincipalName: "bob@upn.x.id", mail: "bob@x.id", id: "u1" },
        { displayName: "Carol", userPrincipalName: "carol@upn.x.id", mail: "carol@x.id", id: "u2" },
      ]),
    openChat: (email) => {
      opened.push(email);
      return Promise.resolve(`chat-${email}`);
    },
    sendMessage: (chatId, text) => {
      sent.push({ chatId, text });
      return Promise.resolve("m1");
    },
    ...options.api,
  };
  const gateway: TeamsGateway = {
    session: (use) => {
      sessions += 1;
      return use(api);
    },
  };
  let now = options.now ?? WORKING;
  const mode = options.mode ?? "auto";
  const deps: DispatchDeps = {
    store,
    gateway,
    templates: DEFAULT_TEMPLATES,
    config: { modes: { nudge: mode, notice: mode }, workingHours: hours, people: {} },
    log: createLogger({ write: () => undefined }),
    now: () => now,
  };
  return {
    deps,
    store,
    sent,
    opened,
    sessions: () => sessions,
    setNow: (value: number) => {
      now = value;
    },
  };
}

const own = (reviewers = [reviewer("bob", "UNREVIEWED", "Bob")]) =>
  snapshot({ authored: [mr(5, { author: ME, title: "Add thing", reviewers })] });

function enqueue(store: Store, ...slots: number[]): number[] {
  store.applyTeamsPlan(
    teamsPlan({ intents: slots.map((slot) => intent(slot, { dedupeKey: `k:${slot}` })) }),
    NOW,
  );
  return store.listOutbox(["queued"]).map((row) => row.id);
}

describe("dispatchQueued", () => {
  it("sends in auto mode with one session, resolving the email and using the template", async () => {
    const h = setup();
    const [id] = enqueue(h.store, 1);
    const result = await dispatchQueued(h.deps, own());
    expect(result).toEqual({ sent: 1, failure: undefined });
    expect(h.sessions()).toBe(1);
    expect(h.opened).toEqual(["bob@x.id"]);
    expect(h.sent).toEqual([
      {
        chatId: "chat-bob@x.id",
        text: "Halo Bob, boleh minta tolong review MR ini? Add thing\nhttps://gitlab.example/g/p/-/merge_requests/5\nTerima kasih!",
      },
    ]);
    expect(h.store.getOutbox(id ?? 0)).toMatchObject({ status: "sent" });
  });

  it("opens one session for several messages", async () => {
    const h = setup();
    enqueue(h.store, 1, 2);
    await dispatchQueued(h.deps, own());
    expect(h.sessions()).toBe(1);
    expect(h.sent).toHaveLength(2);
  });

  it("holds the rendered text for approval and opens no session", async () => {
    const h = setup({ mode: "approval" });
    const [id] = enqueue(h.store, 1);
    await dispatchQueued(h.deps, own());
    expect(h.sessions()).toBe(0);
    expect(h.sent).toEqual([]);
    expect(h.store.getOutbox(id ?? 0)).toMatchObject({ status: "pending" });
    expect(h.store.getOutbox(id ?? 0)?.text).toContain("Halo Bob");
  });

  it("records a dry run with its text and sends nothing", async () => {
    const h = setup({ mode: "dry-run" });
    const [id] = enqueue(h.store, 1);
    await dispatchQueued(h.deps, own());
    expect(h.sessions()).toBe(0);
    expect(h.store.getOutbox(id ?? 0)).toMatchObject({ status: "dry-run" });
    expect(h.store.getOutbox(id ?? 0)?.text).toContain("Halo Bob");
  });

  it("uses the notice mode for notices and the nudge mode for nudges", async () => {
    const h = setup();
    h.deps = {
      ...h.deps,
      config: { ...h.deps.config, modes: { nudge: "approval", notice: "dry-run" } },
    };
    h.store.applyTeamsPlan(
      teamsPlan({
        intents: [
          intent(1),
          intent(2, {
            dedupeKey: "notice:g/p!7:APPROVED:0",
            kind: "notice",
            variant: "notice.approved",
            mr: {
              key: "g/p!7",
              iid: 7,
              projectPath: "g/p",
              title: "Fix it",
              url: "https://gitlab.example/g/p/-/merge_requests/7",
            },
          }),
        ],
      }),
      NOW,
    );
    const both = snapshot({
      authored: [mr(5, { author: ME, reviewers: [reviewer("bob", "UNREVIEWED", "Bob")] })],
      reviewRequested: [mr(7, { reviewers: [reviewer("me", "APPROVED")] })],
    });
    await dispatchQueued(h.deps, both);
    expect(h.store.listOutbox(["pending"]).map((row) => row.kind)).toEqual(["nudge"]);
    expect(h.store.listOutbox(["dry-run"]).map((row) => row.kind)).toEqual(["notice"]);
  });

  it("keeps rows queued outside working hours and sends them once the hours begin", async () => {
    const h = setup({ now: EVENING });
    const [id] = enqueue(h.store, 1);
    await dispatchQueued(h.deps, own());
    expect(h.sessions()).toBe(0);
    expect(h.store.getOutbox(id ?? 0)).toMatchObject({ status: "queued" });
    h.setNow(WORKING + 24 * 3_600_000);
    await dispatchQueued(h.deps, own());
    expect(h.sent).toHaveLength(1);
  });

  it("skips a nudge when the Reviewer has reviewed in the meantime, or the MR is gone", async () => {
    const h = setup();
    const [first] = enqueue(h.store, 1);
    await dispatchQueued(h.deps, own([reviewer("bob", "APPROVED", "Bob")]));
    expect(h.store.getOutbox(first ?? 0)).toMatchObject({ status: "skipped", detail: "obsolete" });
    const [second] = enqueue(h.store, 2);
    await dispatchQueued(h.deps, snapshot());
    expect(h.store.getOutbox(second ?? 0)).toMatchObject({ status: "skipped" });
    expect(h.sent).toEqual([]);
  });

  it("sends a notice only while the MR is still waiting for the Owner's review", async () => {
    const h = setup();
    h.store.applyTeamsPlan(
      teamsPlan({
        intents: [
          intent(1, {
            dedupeKey: "notice:g/p!7:APPROVED:0",
            kind: "notice",
            variant: "notice.approved",
            mr: {
              key: "g/p!7",
              iid: 7,
              projectPath: "g/p",
              title: "Fix it",
              url: "https://gitlab.example/g/p/-/merge_requests/7",
            },
            recipient: person("bob", "Bob"),
          }),
        ],
      }),
      NOW,
    );
    const theirs = snapshot({
      reviewRequested: [mr(7, { reviewers: [reviewer("me", "APPROVED")] })],
    });
    await dispatchQueued(h.deps, theirs);
    expect(h.sent[0]?.text).toContain("sudah saya review dan saya approve");
  });

  it("marks unresolved people without sending", async () => {
    const h = setup({ api: { searchUsers: () => Promise.resolve([]) } });
    const [id] = enqueue(h.store, 1);
    const result = await dispatchQueued(h.deps, own());
    expect(result.sent).toBe(0);
    expect(h.sent).toEqual([]);
    expect(h.store.getOutbox(id ?? 0)).toMatchObject({ status: "unresolved", detail: "no-match" });
  });

  it("sanitises values substituted into the text", async () => {
    const h = setup();
    h.store.applyTeamsPlan(
      teamsPlan({
        intents: [
          intent(1, {
            mr: {
              key: "g/p!5",
              iid: 5,
              projectPath: "g/p",
              title: "-evil\nsecond‮line",
              url: "https://gitlab.example/x",
            },
          }),
        ],
      }),
      NOW,
    );
    await dispatchQueued(h.deps, own());
    expect(h.sent[0]?.text).toContain("evil second line");
    expect(h.sent[0]?.text).not.toContain("‮");
  });
});

describe("failures", () => {
  it("leaves the row queued when the lookup fails, and reports it", async () => {
    const h = setup({
      api: { searchUsers: () => Promise.reject(new TeamsFailure("unavailable", "down")) },
    });
    const [id] = enqueue(h.store, 1);
    const result = await dispatchQueued(h.deps, own());
    expect(result).toEqual({ sent: 0, failure: "unavailable" });
    expect(h.store.getOutbox(id ?? 0)).toMatchObject({ status: "queued" });
  });

  it("reports a Teams server that cannot start and leaves everything queued", async () => {
    const h = setup();
    h.deps = {
      ...h.deps,
      gateway: { session: () => Promise.reject(new TeamsFailure("unavailable", "no server")) },
    };
    const [id] = enqueue(h.store, 1);
    expect(await dispatchQueued(h.deps, own())).toEqual({ sent: 0, failure: "unavailable" });
    expect(h.store.getOutbox(id ?? 0)).toMatchObject({ status: "queued" });
  });
});

describe("at most once", () => {
  it("a failed send is final: the row is failed, later passes do not resend it, and the rest of the batch waits", async () => {
    let calls = 0;
    const h = setup({
      api: {
        sendMessage: (chatId, text) => {
          calls += 1;
          if (calls === 1) return Promise.reject(new TeamsFailure("error", "403"));
          h.sent.push({ chatId, text });
          return Promise.resolve("m2");
        },
      },
    });
    const [first, second] = enqueue(h.store, 1, 2);
    const firstPass = await dispatchQueued(h.deps, own());
    expect(firstPass).toEqual({ sent: 0, failure: "error" });
    expect(h.store.getOutbox(first ?? 0)).toMatchObject({ status: "failed", detail: "error" });
    expect(h.store.getOutbox(second ?? 0)).toMatchObject({ status: "queued" });

    const secondPass = await dispatchQueued(h.deps, own());
    expect(secondPass).toEqual({ sent: 1, failure: undefined });
    expect(calls).toBe(2);
    expect(h.store.getOutbox(first ?? 0)).toMatchObject({ status: "failed" });
    expect(h.store.getOutbox(second ?? 0)).toMatchObject({ status: "sent" });
  });

  it("a row stuck in 'sending' (a crash) is never picked up again", async () => {
    const h = setup();
    const [id] = enqueue(h.store, 1);
    h.store.transitionOutbox(id ?? 0, "queued", "sending", { text: "halo" }, NOW);
    await dispatchQueued(h.deps, own());
    expect(h.sent).toEqual([]);
    expect(await sendPending(h.deps, id ?? 0)).toEqual({ status: "not-pending" });
  });

  it("two simultaneous sends of the same pending row result in one message", async () => {
    const h = setup({ mode: "approval" });
    const [id] = enqueue(h.store, 1);
    await dispatchQueued(h.deps, own());
    const outcomes = await Promise.all([
      sendPending(h.deps, id ?? 0),
      sendPending(h.deps, id ?? 0),
    ]);
    expect(outcomes.map((o) => o.status).sort()).toEqual(["busy", "sent"]);
    expect(h.sent).toHaveLength(1);
  });

  it("switching a flow from approval to auto does not send rows that are already pending", async () => {
    const h = setup({ mode: "approval" });
    enqueue(h.store, 1);
    await dispatchQueued(h.deps, own());
    h.deps = { ...h.deps, config: { ...h.deps.config, modes: { nudge: "auto", notice: "auto" } } };
    await dispatchQueued(h.deps, own());
    expect(h.sent).toEqual([]);
    expect(h.store.listOutbox(["pending"])).toHaveLength(1);
  });
});

describe("owner actions", () => {
  it("sends a pending row on request and reports unknown ids", async () => {
    const h = setup({ mode: "approval" });
    const [id] = enqueue(h.store, 1);
    await dispatchQueued(h.deps, own());
    expect(await sendPending(h.deps, id ?? 0)).toEqual({ status: "sent" });
    expect(await sendPending(h.deps, 9999)).toEqual({ status: "not-found" });
    expect(h.sent).toHaveLength(1);
  });

  it("keeps a pending row pending when Teams is unreachable", async () => {
    const h = setup({ mode: "approval" });
    const [id] = enqueue(h.store, 1);
    await dispatchQueued(h.deps, own());
    h.deps = {
      ...h.deps,
      gateway: { session: () => Promise.reject(new TeamsFailure("unavailable", "down")) },
    };
    expect(await sendPending(h.deps, id ?? 0)).toEqual({
      status: "retry-later",
      failure: "unavailable",
    });
    expect(h.store.getOutbox(id ?? 0)).toMatchObject({ status: "pending" });
  });

  it("skips pending, unresolved and queued rows but never a sent one, and retries only unresolved rows", async () => {
    const h = setup({ api: { searchUsers: () => Promise.resolve([]) } });
    const [id] = enqueue(h.store, 1);
    await dispatchQueued(h.deps, own());
    expect(h.store.getOutbox(id ?? 0)).toMatchObject({ status: "unresolved" });
    expect(retryOutbox(h.store, id ?? 0, NOW)).toBe(true);
    expect(h.store.getOutbox(id ?? 0)).toMatchObject({ status: "queued" });
    expect(retryOutbox(h.store, id ?? 0, NOW)).toBe(false);
    expect(skipOutbox(h.store, id ?? 0, NOW)).toBe(true);
    expect(skipOutbox(h.store, id ?? 0, NOW)).toBe(false);
  });
});
