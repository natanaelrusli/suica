import type { Config } from "../config.ts";
import { UNREVIEWED } from "../domain.ts";
import type { Snapshot } from "../domain.ts";
import { clean } from "../format.ts";
import { reviewerKey } from "../events.ts";
import type { PreviousState } from "../events.ts";
import type { Logger } from "../log.ts";
import type { Store } from "../store.ts";
import { TeamsFailure } from "./api.ts";
import type { TeamsApi, TeamsFailureKind } from "./api.ts";
import type { TeamsGateway } from "./gateway.ts";
import { isWithinWorkingHours } from "./hours.ts";
import { resolveEmail } from "./identity.ts";
import type { Resolution } from "./identity.ts";
import { escapeMarkdown, markdownLink, renderTemplate } from "./templates.ts";
import type { Placeholder, Templates } from "./templates.ts";
import type { HeldMessage, OutboxRow } from "./types.ts";

type TeamsStore = Pick<
  Store,
  | "load"
  | "loadTeams"
  | "listOutbox"
  | "getOutbox"
  | "transitionOutbox"
  | "loadIdentity"
  | "saveIdentity"
>;

export type SendMode = Config["teams"]["modes"]["nudge"];

export interface DispatchDeps {
  readonly store: TeamsStore;
  readonly gateway: TeamsGateway;
  readonly templates: Templates;
  readonly config: Pick<Config["teams"], "modes" | "workingHours" | "people">;
  readonly log: Logger;
  readonly now: () => number;
}

export interface DispatchResult {
  readonly sent: number;
  readonly failure: TeamsFailureKind | undefined;
  /** Rows this call moved from `queued` to `pending`, for the Owner notification. */
  readonly held: readonly HeldMessage[];
}

export type DeliverOutcome =
  | { readonly status: "sent" | "unresolved" | "busy" }
  | {
      readonly status: "failed" | "retry-later" | "lookup-error";
      readonly failure: TeamsFailureKind;
    };

export type SendPendingOutcome =
  DeliverOutcome | { readonly status: "not-found" | "not-pending" | "obsolete" };

const TITLE_MAX = 120;
const NAME_MAX = 60;
/** A broken login fails every lookup the same way: stop early instead of parking the whole queue. */
const MAX_LOOKUP_ERRORS_IN_A_ROW = 3;

export function modeFor(
  row: Pick<OutboxRow, "kind" | "variant">,
  config: Pick<Config["teams"], "modes">,
): SendMode {
  // The Review Notice with an Agent Review's or Re-review's findings has its own mode, so it can
  // go out on its own while the other Review Notices still wait for approval.
  if (row.variant === "notice.findings" || row.variant === "notice.refindings") {
    return config.modes.findings;
  }
  if (row.kind === "notice") return config.modes.notice;
  return row.kind === "rereview" ? config.modes.rereview : config.modes.nudge;
}

function failureKind(error: unknown): TeamsFailureKind {
  return error instanceof TeamsFailure ? error.kind : "error";
}

/**
 * A Re-review Nudge waits only while the ledger still holds its round open: the planner closes it
 * when the Reviewer reviews again or the Owner re-requests them in GitLab, and drops the Reviewer's
 * row when they are removed.
 */
function rereviewOpen(store: TeamsStore, row: OutboxRow): boolean {
  const record = store.loadTeams().rereviewReviewers.get(reviewerKey(row.mrKey, row.recipient));
  return record?.nudged === true;
}

/** Is the message still worth sending now? Re-checked at send time, not only when it was queued. */
function stillNeeded(store: TeamsStore, row: OutboxRow, snapshot: Snapshot): boolean {
  if (row.kind === "notice") {
    return snapshot.reviewRequested.some((mr) => mr.key === row.mrKey && !mr.draft);
  }
  const mr = snapshot.authored.find((candidate) => candidate.key === row.mrKey);
  if (mr === undefined || mr.draft) return false;
  if (row.kind === "rereview") {
    return (
      mr.reviewers.some((reviewer) => reviewer.username === row.recipient) &&
      rereviewOpen(store, row)
    );
  }
  return mr.reviewers.some(
    (reviewer) => reviewer.username === row.recipient && reviewer.state === UNREVIEWED,
  );
}

/** The same question as `stillNeeded`, answered from the last committed poll (for `suica send`). */
function stillNeededInState(store: TeamsStore, row: OutboxRow, state: PreviousState): boolean {
  if (row.kind === "notice") return state.myReviewStates.has(row.mrKey);
  const key = reviewerKey(row.mrKey, row.recipient);
  if (row.kind === "rereview") {
    return (
      state.trackedAuthored.has(row.mrKey) &&
      state.reviewerStates.has(key) &&
      rereviewOpen(store, row)
    );
  }
  return state.trackedAuthored.has(row.mrKey) && state.reviewerStates.get(key) === UNREVIEWED;
}

function valuesFor(row: OutboxRow, ownerName: string): Record<Placeholder, string> {
  return {
    "mr.title": escapeMarkdown(clean(row.mrTitle, TITLE_MAX)),
    "mr.url": row.mrUrl,
    "mr.link": markdownLink(clean(row.mrTitle, TITLE_MAX), row.mrUrl),
    "mr.iid": String(row.mrIid),
    "mr.project": escapeMarkdown(row.mrProject),
    "person.name": escapeMarkdown(clean(row.recipientName, NAME_MAX)),
    "owner.name": escapeMarkdown(clean(ownerName, NAME_MAX)),
    // Built by describeFindings, which already escapes what it took from the review.
    "review.findings": row.findings ?? "",
  };
}

/**
 * Sends one row, which must currently be `queued` or `pending`. The row moves to `sending`
 * (compare-and-set) before anything that can deliver a message, and from there it can only end
 * as `sent` or `failed`: no code path sends a row twice.
 */
export async function deliver(
  deps: DispatchDeps,
  api: TeamsApi,
  row: OutboxRow,
  text: string,
): Promise<DeliverOutcome> {
  const from = row.status;
  let resolution: Resolution;
  try {
    resolution = await resolveEmail(
      { api, store: deps.store, people: deps.config.people, now: deps.now },
      { username: row.recipient, name: row.recipientName },
    );
  } catch (error) {
    // Nothing has been sent yet. A Teams that cannot be reached leaves the row as it is; an
    // error answer about this one person is permanent for this row, so it must not block the rest.
    const failure = failureKind(error);
    if (failure === "unavailable") return { status: "retry-later", failure };
    deps.store.transitionOutbox(
      row.id,
      from,
      "unresolved",
      { detail: "lookup-error", text },
      deps.now(),
    );
    return { status: "lookup-error", failure };
  }
  if (resolution.kind === "unresolved") {
    deps.store.transitionOutbox(
      row.id,
      from,
      "unresolved",
      { detail: resolution.reason, text },
      deps.now(),
    );
    return { status: "unresolved" };
  }
  // Leaving `pending` is only possible through `suica send`, so it is the Owner's approval.
  const approval = from === "pending" ? { approved: true as const } : {};
  if (!deps.store.transitionOutbox(row.id, from, "sending", { text, ...approval }, deps.now())) {
    return { status: "busy" };
  }
  try {
    const chatId = await api.openChat(resolution.email);
    await api.sendMessage(chatId, text);
  } catch (error) {
    const kind = failureKind(error);
    deps.store.transitionOutbox(row.id, "sending", "failed", { detail: kind }, deps.now());
    return { status: "failed", failure: kind };
  }
  deps.store.transitionOutbox(row.id, "sending", "sent", {}, deps.now());
  return { status: "sent" };
}

async function sendBatch(
  deps: DispatchDeps,
  batch: readonly { readonly row: OutboxRow; readonly text: string }[],
): Promise<Omit<DispatchResult, "held">> {
  let sent = 0;
  let failure: TeamsFailureKind | undefined;
  let lookupErrors = 0;
  try {
    await deps.gateway.session(async (api) => {
      for (const { row, text } of batch) {
        const outcome = await deliver(deps, api, row, text);
        if (outcome.status === "sent") sent += 1;
        lookupErrors = outcome.status === "lookup-error" ? lookupErrors + 1 : 0;
        if (outcome.status === "lookup-error") failure = outcome.failure;
        if (outcome.status === "failed" || outcome.status === "retry-later") {
          // Stop: the rows after this one were never attempted and stay queued.
          failure = outcome.failure;
          return;
        }
        if (lookupErrors >= MAX_LOOKUP_ERRORS_IN_A_ROW) return;
      }
    });
  } catch (error) {
    failure = failureKind(error);
  }
  return { sent, failure };
}

/** Turns `queued` rows into pending / dry-run / sent according to each flow's mode. */
export async function dispatchQueued(
  deps: DispatchDeps,
  snapshot: Snapshot,
): Promise<DispatchResult> {
  const rows = deps.store.listOutbox(["queued", "pending"]);
  const nowMs = deps.now();
  const inHours = isWithinWorkingHours(new Date(nowMs), deps.config.workingHours);
  const automatic: { row: OutboxRow; text: string }[] = [];
  const held: HeldMessage[] = [];

  for (const row of rows) {
    if (!stillNeeded(deps.store, row, snapshot)) {
      deps.store.transitionOutbox(row.id, row.status, "skipped", { detail: "obsolete" }, nowMs);
      continue;
    }
    // A pending row only waits for the Owner; the checks above are all it needs here.
    if (row.status === "pending" || !inHours) continue;
    let text: string;
    try {
      text = renderTemplate(deps.templates[row.variant], valuesFor(row, snapshot.me.name));
    } catch {
      deps.store.transitionOutbox(row.id, "queued", "failed", { detail: "template" }, nowMs);
      continue;
    }
    const mode = modeFor(row, deps.config);
    if (mode === "dry-run") {
      deps.store.transitionOutbox(row.id, "queued", "dry-run", { text }, nowMs);
      deps.log.info("dry-run message recorded", { kind: row.kind });
    } else if (mode === "approval") {
      if (deps.store.transitionOutbox(row.id, "queued", "pending", { text }, nowMs)) held.push(row);
    } else {
      automatic.push({ row, text });
    }
  }
  if (automatic.length === 0) return { sent: 0, failure: undefined, held };
  return { ...(await sendBatch(deps, automatic)), held };
}

/** `suica send <id>`: sends one row that is waiting for the Owner's approval. */
export async function sendPending(deps: DispatchDeps, id: number): Promise<SendPendingOutcome> {
  const row = deps.store.getOutbox(id);
  if (row === undefined) return { status: "not-found" };
  if (row.status !== "pending" || row.text === null) return { status: "not-pending" };
  const text = row.text;
  if (!stillNeededInState(deps.store, row, deps.store.load())) {
    deps.store.transitionOutbox(row.id, "pending", "skipped", { detail: "obsolete" }, deps.now());
    return { status: "obsolete" };
  }
  try {
    return await deps.gateway.session((api) => deliver(deps, api, row, text));
  } catch (error) {
    return { status: "retry-later", failure: failureKind(error) };
  }
}

/** `suica skip <id>`: true when a pending, unresolved or queued row was skipped. */
export function skipOutbox(
  store: Pick<Store, "transitionOutbox">,
  id: number,
  now: number,
): boolean {
  return (["pending", "unresolved", "queued"] as const).some((from) =>
    store.transitionOutbox(id, from, "skipped", { detail: "skipped by owner" }, now),
  );
}

/** `suica retry <id>`: puts an unresolved row back in the queue after the Owner fixed `teams.people`. */
export function retryOutbox(
  store: Pick<Store, "transitionOutbox">,
  id: number,
  now: number,
): boolean {
  return store.transitionOutbox(id, "unresolved", "queued", { detail: "" }, now);
}
