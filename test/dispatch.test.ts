import { describe, expect, it } from "vitest";
import { createLogger } from "../src/log.ts";
import { openStore } from "../src/store.ts";
import type { Store } from "../src/store.ts";
import { TeamsFailure } from "../src/teams/api.ts";
import type { TeamsApi } from "../src/teams/api.ts";
import {
  dispatchQueued,
  modeFor,
  retryOutbox,
  sendPending,
  skipOutbox,
} from "../src/teams/dispatch.ts";
import type { DispatchDeps, SendMode } from "../src/teams/dispatch.ts";
import type { TeamsGateway } from "../src/teams/gateway.ts";
import { DEFAULT_TEMPLATES, greetingAt, pickVariant } from "../src/teams/templates.ts";
import type { RereviewReviewer } from "../src/teams/types.ts";
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
    config: {
      modes: { nudge: mode, notice: mode, rereview: mode, findings: mode, approved: mode },
      workingHours: hours,
      people: {},
      agentName: "Bahlil",
    },
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
    expect(result).toEqual({ sent: 1, failure: undefined, held: [] });
    expect(h.sessions()).toBe(1);
    expect(h.opened).toEqual(["bob@x.id"]);
    expect(h.sent).toEqual([
      {
        chatId: "chat-bob@x.id",
        text: "Halo Bob, saya Bahlil, agen review-nya Nata. Boleh minta tolong review MR ini?\n[Add thing](https://gitlab.example/g/p/-/merge_requests/5)\nTerima kasih!",
      },
    ]);
    expect(h.store.getOutbox(id ?? 0)).toMatchObject({ status: "sent", approved: false });
  });

  it("records the Owner's approval on a pending row that is sent", async () => {
    const h = setup({ mode: "approval" });
    const [id] = enqueue(h.store, 1);
    h.store.commit(own());
    await dispatchQueued(h.deps, own());
    expect(h.store.getOutbox(id ?? 0)).toMatchObject({ status: "pending", approved: false });
    expect(await sendPending(h.deps, id ?? 0)).toEqual({ status: "sent" });
    expect(h.store.getOutbox(id ?? 0)).toMatchObject({ status: "sent", approved: true });
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
      config: {
        ...h.deps.config,
        modes: {
          nudge: "approval",
          notice: "dry-run",
          rereview: "approval",
          findings: "approval",
          approved: "dry-run",
        },
      },
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

  it("sends the findings notice in its own mode while other notices are a dry run", async () => {
    const h = setup();
    h.deps = {
      ...h.deps,
      config: {
        ...h.deps.config,
        modes: {
          nudge: "approval",
          notice: "dry-run",
          rereview: "approval",
          findings: "auto",
          approved: "dry-run",
        },
      },
    };
    const theirs = {
      key: "g/p!7",
      iid: 7,
      projectPath: "g/p",
      title: "Fix it",
      url: "https://gitlab.example/g/p/-/merge_requests/7",
    };
    h.store.applyTeamsPlan(
      teamsPlan({
        intents: [
          intent(1, {
            dedupeKey: "findings:4",
            kind: "notice",
            variant: "notice.findings",
            mr: theirs,
            findings: "ada 3 findings (2 Minor, 1 Nit)",
          }),
          intent(2, {
            dedupeKey: "notice:g/p!7:APPROVED:0",
            kind: "notice",
            variant: "notice.approved",
            mr: theirs,
          }),
        ],
      }),
      NOW,
    );
    const requested = snapshot({
      reviewRequested: [mr(7, { reviewers: [reviewer("me", "APPROVED")] })],
    });
    const result = await dispatchQueued(h.deps, requested);
    expect(result.sent).toBe(1);
    expect(h.sent).toEqual([
      {
        chatId: "chat-bob@x.id",
        text: "Halo Bob, saya Bahlil, agen review-nya Nata. Saya sudah review MR kamu: ada 3 findings (2 Minor, 1 Nit).\n[Fix it](https://gitlab.example/g/p/-/merge_requests/7)\nDetailnya ada di komentar MR.",
      },
    ]);
    expect(h.store.listOutbox(["dry-run"]).map((row) => row.variant)).toEqual(["notice.approved"]);
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

  it("writes each message from the variant its dedupe key picks, with emoji and the new placeholders", async () => {
    const h = setup();
    const nudge =
      "{{time.greeting}} {{person.firstName}} :wave:\n--- or ---\nHai {{person.firstName}} :rocket:";
    const deps = { ...h.deps, templates: { ...DEFAULT_TEMPLATES, nudge } };
    const keys = Array.from({ length: 6 }, (_, i) => i + 1);
    enqueue(h.store, ...keys);
    await dispatchQueued(deps, own());
    const greeting = greetingAt(new Date(WORKING));
    expect(h.sent.map((each) => each.text)).toEqual(
      keys.map((slot) =>
        pickVariant(nudge, `k:${slot}`).includes("Hai") ? "Hai Bob 🚀" : `${greeting} Bob 👋`,
      ),
    );
    expect(new Set(h.sent.map((each) => each.text)).size).toBe(2);
  });
});

describe("failures", () => {
  it("leaves the row queued when the lookup fails, and reports it", async () => {
    const h = setup({
      api: { searchUsers: () => Promise.reject(new TeamsFailure("unavailable", "down")) },
    });
    const [id] = enqueue(h.store, 1);
    const result = await dispatchQueued(h.deps, own());
    expect(result).toEqual({ sent: 0, failure: "unavailable", held: [] });
    expect(h.store.getOutbox(id ?? 0)).toMatchObject({ status: "queued" });
  });

  it("reports a Teams server that cannot start and leaves everything queued", async () => {
    const h = setup();
    h.deps = {
      ...h.deps,
      gateway: { session: () => Promise.reject(new TeamsFailure("unavailable", "no server")) },
    };
    const [id] = enqueue(h.store, 1);
    expect(await dispatchQueued(h.deps, own())).toEqual({
      sent: 0,
      failure: "unavailable",
      held: [],
    });
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
    expect(firstPass).toEqual({ sent: 0, failure: "error", held: [] });
    expect(h.store.getOutbox(first ?? 0)).toMatchObject({ status: "failed", detail: "error" });
    expect(h.store.getOutbox(second ?? 0)).toMatchObject({ status: "queued" });

    const secondPass = await dispatchQueued(h.deps, own());
    expect(secondPass).toEqual({ sent: 1, failure: undefined, held: [] });
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
    h.store.commit(own());
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
    h.deps = {
      ...h.deps,
      config: {
        ...h.deps.config,
        modes: {
          nudge: "auto",
          notice: "auto",
          rereview: "auto",
          findings: "auto",
          approved: "auto",
        },
      },
    };
    await dispatchQueued(h.deps, own());
    expect(h.sent).toEqual([]);
    expect(h.store.listOutbox(["pending"])).toHaveLength(1);
  });
});

describe("pending rows are re-checked", () => {
  it("skips a pending nudge when the Reviewer reviewed after it was queued", async () => {
    const h = setup({ mode: "approval" });
    const [id] = enqueue(h.store, 1);
    await dispatchQueued(h.deps, own());
    expect(h.store.getOutbox(id ?? 0)).toMatchObject({ status: "pending" });
    await dispatchQueued(h.deps, own([reviewer("bob", "APPROVED", "Bob")]));
    expect(h.store.getOutbox(id ?? 0)).toMatchObject({ status: "skipped", detail: "obsolete" });
  });

  it("refuses to send a pending nudge to a Reviewer who has reviewed since", async () => {
    const h = setup({ mode: "approval" });
    const [id] = enqueue(h.store, 1);
    await dispatchQueued(h.deps, own());
    h.store.commit(own([reviewer("bob", "APPROVED", "Bob")]));
    expect(await sendPending(h.deps, id ?? 0)).toEqual({ status: "obsolete" });
    expect(h.sent).toEqual([]);
    expect(h.store.getOutbox(id ?? 0)).toMatchObject({ status: "skipped", detail: "obsolete" });
  });

  it("refuses to send a pending notice once the MR is no longer waiting for the Owner", async () => {
    const h = setup({ mode: "approval" });
    h.store.applyTeamsPlan(
      teamsPlan({
        intents: [
          intent(1, {
            dedupeKey: "notice:g/p!7:APPROVED:0",
            kind: "notice",
            variant: "notice.approved",
            mr: { key: "g/p!7", iid: 7, projectPath: "g/p", title: "T", url: "https://x/7" },
          }),
        ],
      }),
      NOW,
    );
    const id = h.store.listOutbox(["queued"])[0]?.id ?? 0;
    h.store.commit(
      snapshot({ reviewRequested: [mr(7, { reviewers: [reviewer("me", "APPROVED")] })] }),
    );
    await dispatchQueued(
      h.deps,
      snapshot({ reviewRequested: [mr(7, { reviewers: [reviewer("me", "APPROVED")] })] }),
    );
    expect(h.store.getOutbox(id)).toMatchObject({ status: "pending" });
    h.store.commit(snapshot());
    expect(await sendPending(h.deps, id)).toEqual({ status: "obsolete" });
    expect(h.sent).toEqual([]);
  });
});

describe("lookup errors", () => {
  const failFor = (name: string) => (query: string) =>
    query === name
      ? Promise.reject(new TeamsFailure("error", "invalid filter"))
      : Promise.resolve([
          { displayName: "Carol", userPrincipalName: "c@upn.x.id", mail: "carol@x.id", id: "u2" },
        ]);

  it("marks the row with the broken lookup unresolved and carries on with the rest", async () => {
    const h = setup({ api: { searchUsers: failFor("Bob") } });
    h.store.applyTeamsPlan(
      teamsPlan({
        intents: [
          intent(1, { dedupeKey: "k:1" }),
          intent(2, { dedupeKey: "k:2", recipient: person("carol", "Carol") }),
        ],
      }),
      NOW,
    );
    const snap = own([
      reviewer("bob", "UNREVIEWED", "Bob"),
      reviewer("carol", "UNREVIEWED", "Carol"),
    ]);
    const result = await dispatchQueued(h.deps, snap);
    expect(result).toEqual({ sent: 1, failure: "error", held: [] });
    expect(h.store.listOutbox(["unresolved"])).toHaveLength(1);
    expect(h.store.listOutbox(["unresolved"])[0]).toMatchObject({
      recipient: "bob",
      detail: "lookup-error",
    });
    expect(h.opened).toEqual(["carol@x.id"]);
  });

  it("stops after three lookup errors in a row so an expired login does not park the whole queue", async () => {
    const h = setup({
      api: { searchUsers: () => Promise.reject(new TeamsFailure("error", "401")) },
    });
    h.store.applyTeamsPlan(
      teamsPlan({
        intents: [1, 2, 3, 4, 5].map((slot) => intent(slot, { dedupeKey: `k:${slot}` })),
      }),
      NOW,
    );
    const result = await dispatchQueued(h.deps, own());
    expect(result).toEqual({ sent: 0, failure: "error", held: [] });
    expect(h.store.listOutbox(["unresolved"])).toHaveLength(3);
    expect(h.store.listOutbox(["queued"])).toHaveLength(2);
  });
});

describe("owner actions", () => {
  it("sends a pending row on request and reports unknown ids", async () => {
    const h = setup({ mode: "approval" });
    const [id] = enqueue(h.store, 1);
    h.store.commit(own());
    await dispatchQueued(h.deps, own());
    expect(await sendPending(h.deps, id ?? 0)).toEqual({ status: "sent" });
    expect(await sendPending(h.deps, 9999)).toEqual({ status: "not-found" });
    expect(h.sent).toHaveLength(1);
  });

  it("keeps a pending row pending when Teams is unreachable", async () => {
    const h = setup({ mode: "approval" });
    const [id] = enqueue(h.store, 1);
    h.store.commit(own());
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

describe("Re-review Nudge", () => {
  const BOB_KEY = "g/p!5|bob";
  const open: RereviewReviewer = { reviewedHead: "h1", state: "APPROVED", notes: 0, nudged: true };
  const closed: RereviewReviewer = { ...open, nudged: false };
  const reviewed = (state = "APPROVED") => own([reviewer("bob", state, "Bob")]);

  /** Queues one Re-review Nudge for bob, with the ledger holding `ledger` for him. */
  function queue(h: ReturnType<typeof setup>, ledger: RereviewReviewer | undefined): number {
    h.store.applyTeamsPlan(
      teamsPlan({
        intents: [
          intent(1, {
            dedupeKey: "rereview:g/p!5|bob:h2",
            kind: "rereview",
            variant: "rereview",
          }),
        ],
        rereviewReviewers: ledger === undefined ? new Map() : new Map([[BOB_KEY, ledger]]),
      }),
      NOW,
    );
    return h.store.listOutbox(["queued"])[0]?.id ?? 0;
  }

  it("uses its own send mode", () => {
    const modes = {
      nudge: "auto",
      notice: "auto",
      rereview: "dry-run",
      findings: "auto",
      approved: "auto",
    } as const;
    expect(modeFor({ kind: "rereview", variant: "rereview" }, { modes })).toBe("dry-run");
    expect(modeFor({ kind: "nudge", variant: "nudge" }, { modes })).toBe("auto");
    expect(modeFor({ kind: "reminder", variant: "reminder" }, { modes })).toBe("auto");
    expect(modeFor({ kind: "notice", variant: "notice.comments" }, { modes })).toBe("auto");
  });

  it("sends both findings notices in the findings mode", () => {
    const modes = {
      nudge: "auto",
      notice: "dry-run",
      rereview: "auto",
      findings: "approval",
      approved: "auto",
    } as const;
    expect(modeFor({ kind: "notice", variant: "notice.findings" }, { modes })).toBe("approval");
    expect(modeFor({ kind: "notice", variant: "notice.refindings" }, { modes })).toBe("approval");
    expect(modeFor({ kind: "notice", variant: "notice.reapproved" }, { modes })).toBe("approval");
  });

  it("sends the approval notice in its own mode, and the other notices in the notice mode", () => {
    const modes = {
      nudge: "approval",
      notice: "dry-run",
      rereview: "approval",
      findings: "approval",
      approved: "auto",
    } as const;
    expect(modeFor({ kind: "notice", variant: "notice.approved" }, { modes })).toBe("auto");
    expect(modeFor({ kind: "notice", variant: "notice.comments" }, { modes })).toBe("dry-run");
    expect(modeFor({ kind: "notice", variant: "notice.changes" }, { modes })).toBe("dry-run");
    expect(modeFor({ kind: "notice", variant: "notice.comments" }, { modes })).toBe("dry-run");
  });

  it("holds it for approval, renders the re-review template and reports it as held", async () => {
    const h = setup({ mode: "approval" });
    const id = queue(h, open);
    const result = await dispatchQueued(h.deps, reviewed());
    expect(h.sessions()).toBe(0);
    expect(h.store.getOutbox(id)).toMatchObject({ status: "pending" });
    expect(h.store.getOutbox(id)?.text).toBe(
      "Halo Bob, saya Bahlil, agen review-nya Nata. MR ini sudah saya update sesuai review-mu. Boleh minta tolong dicek lagi?\n[Add thing](https://gitlab.example/g/p/-/merge_requests/5)\nTerima kasih!",
    );
    expect(result.held).toEqual([
      expect.objectContaining({ id, kind: "rereview", mrKey: "g/p!5", recipientName: "Bob" }),
    ]);
  });

  it("reports a message as held once, not on every later poll while it waits", async () => {
    const h = setup({ mode: "approval" });
    queue(h, open);
    expect((await dispatchQueued(h.deps, reviewed())).held).toHaveLength(1);
    expect((await dispatchQueued(h.deps, reviewed())).held).toEqual([]);
  });

  it("reports nothing as held in auto and dry-run mode, where nothing waits for the Owner", async () => {
    for (const mode of ["auto", "dry-run"] as const) {
      const h = setup({ mode });
      queue(h, open);
      expect((await dispatchQueued(h.deps, reviewed())).held).toEqual([]);
    }
  });

  it("reports nothing as held outside working hours, and reports it once the hours begin", async () => {
    const h = setup({ mode: "approval", now: EVENING });
    queue(h, open);
    expect((await dispatchQueued(h.deps, reviewed())).held).toEqual([]);
    h.setNow(WORKING + 24 * 3_600_000);
    expect((await dispatchQueued(h.deps, reviewed())).held).toHaveLength(1);
  });

  it("sends it when the Reviewer is still listed and the round is open, whatever their state", async () => {
    const h = setup();
    const id = queue(h, open);
    expect(await dispatchQueued(h.deps, reviewed("REQUESTED_CHANGES"))).toMatchObject({ sent: 1 });
    expect(h.store.getOutbox(id)).toMatchObject({ status: "sent" });
  });

  it("is obsolete once the planner closed the round: the Reviewer reviewed again or was re-requested", async () => {
    const h = setup({ mode: "approval" });
    const id = queue(h, closed);
    await dispatchQueued(h.deps, reviewed());
    expect(h.store.getOutbox(id)).toMatchObject({ status: "skipped", detail: "obsolete" });
    expect(h.sent).toEqual([]);
  });

  it("is obsolete while pending too, and stops being held", async () => {
    const h = setup({ mode: "approval" });
    const id = queue(h, open);
    await dispatchQueued(h.deps, reviewed());
    expect(h.store.getOutbox(id)).toMatchObject({ status: "pending" });
    h.store.applyTeamsPlan(teamsPlan({ rereviewReviewers: new Map([[BOB_KEY, closed]]) }), NOW);
    await dispatchQueued(h.deps, reviewed());
    expect(h.store.getOutbox(id)).toMatchObject({ status: "skipped", detail: "obsolete" });
  });

  it("is obsolete when the MR is gone or a draft, the Reviewer was removed, or the ledger lost them", async () => {
    const cases = [
      snapshot(),
      snapshot({
        authored: [mr(5, { author: ME, draft: true, reviewers: [reviewer("bob", "APPROVED")] })],
      }),
      own([reviewer("carol", "APPROVED")]),
    ];
    for (const current of cases) {
      const h = setup();
      const id = queue(h, open);
      await dispatchQueued(h.deps, current);
      expect(h.store.getOutbox(id)).toMatchObject({ status: "skipped", detail: "obsolete" });
    }
    const forgotten = setup();
    const id = queue(forgotten, undefined);
    await dispatchQueued(forgotten.deps, reviewed());
    expect(forgotten.store.getOutbox(id)).toMatchObject({ status: "skipped", detail: "obsolete" });
  });

  it("is sent on `suica send` while the round is open, and refused as obsolete once it is closed", async () => {
    const stillOpen = setup({ mode: "approval" });
    const id = queue(stillOpen, open);
    stillOpen.store.commit(reviewed());
    await dispatchQueued(stillOpen.deps, reviewed());
    expect(await sendPending(stillOpen.deps, id)).toEqual({ status: "sent" });

    const reviewedAgain = setup({ mode: "approval" });
    const second = queue(reviewedAgain, open);
    reviewedAgain.store.commit(reviewed());
    await dispatchQueued(reviewedAgain.deps, reviewed());
    reviewedAgain.store.applyTeamsPlan(
      teamsPlan({ rereviewReviewers: new Map([[BOB_KEY, closed]]) }),
      NOW,
    );
    expect(await sendPending(reviewedAgain.deps, second)).toEqual({ status: "obsolete" });
    expect(reviewedAgain.store.getOutbox(second)).toMatchObject({ status: "skipped" });
    expect(reviewedAgain.sent).toEqual([]);
  });
});
