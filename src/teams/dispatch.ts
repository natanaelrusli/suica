import type { Config } from "../config.ts";
import { UNREVIEWED } from "../domain.ts";
import type { Snapshot } from "../domain.ts";
import { clean } from "../format.ts";
import type { Logger } from "../log.ts";
import type { Store } from "../store.ts";
import { TeamsFailure } from "./api.ts";
import type { TeamsApi, TeamsFailureKind } from "./api.ts";
import type { TeamsGateway } from "./gateway.ts";
import { isWithinWorkingHours } from "./hours.ts";
import { resolveEmail } from "./identity.ts";
import type { Resolution } from "./identity.ts";
import { renderTemplate } from "./templates.ts";
import type { Placeholder, Templates } from "./templates.ts";
import type { OutboxKind, OutboxRow } from "./types.ts";

type TeamsStore = Pick<
  Store,
  "listOutbox" | "getOutbox" | "transitionOutbox" | "loadIdentity" | "saveIdentity"
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
}

export type DeliverOutcome =
  | { readonly status: "sent" | "unresolved" | "busy" }
  | { readonly status: "failed" | "retry-later"; readonly failure: TeamsFailureKind };

export type SendPendingOutcome = DeliverOutcome | { readonly status: "not-found" | "not-pending" };

const TITLE_MAX = 120;
const NAME_MAX = 60;

export function modeFor(kind: OutboxKind, config: Pick<Config["teams"], "modes">): SendMode {
  return kind === "notice" ? config.modes.notice : config.modes.nudge;
}

function failureKind(error: unknown): TeamsFailureKind {
  return error instanceof TeamsFailure ? error.kind : "error";
}

/** Is the message still worth sending now? Re-checked at send time, not only when it was queued. */
function stillNeeded(row: OutboxRow, snapshot: Snapshot): boolean {
  if (row.kind === "notice") {
    return snapshot.reviewRequested.some((mr) => mr.key === row.mrKey && !mr.draft);
  }
  const mr = snapshot.authored.find((candidate) => candidate.key === row.mrKey);
  if (mr === undefined || mr.draft) return false;
  return mr.reviewers.some(
    (reviewer) => reviewer.username === row.recipient && reviewer.state === UNREVIEWED,
  );
}

function valuesFor(row: OutboxRow, ownerName: string): Record<Placeholder, string> {
  return {
    "mr.title": clean(row.mrTitle, TITLE_MAX),
    "mr.url": row.mrUrl,
    "mr.iid": String(row.mrIid),
    "mr.project": row.mrProject,
    "person.name": clean(row.recipientName, NAME_MAX),
    "owner.name": clean(ownerName, NAME_MAX),
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
    // Nothing has been sent yet, so the row simply stays as it is.
    return { status: "retry-later", failure: failureKind(error) };
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
  if (!deps.store.transitionOutbox(row.id, from, "sending", { text }, deps.now())) {
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
): Promise<DispatchResult> {
  let sent = 0;
  let failure: TeamsFailureKind | undefined;
  try {
    await deps.gateway.session(async (api) => {
      for (const { row, text } of batch) {
        const outcome = await deliver(deps, api, row, text);
        if (outcome.status === "sent") sent += 1;
        if (outcome.status === "failed" || outcome.status === "retry-later") {
          // Stop: the rows after this one were never attempted and stay queued.
          failure = outcome.failure;
          return;
        }
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
  const rows = deps.store.listOutbox(["queued"]);
  const nowMs = deps.now();
  const inHours = isWithinWorkingHours(new Date(nowMs), deps.config.workingHours);
  const automatic: { row: OutboxRow; text: string }[] = [];

  for (const row of rows) {
    if (!stillNeeded(row, snapshot)) {
      deps.store.transitionOutbox(row.id, "queued", "skipped", { detail: "obsolete" }, nowMs);
      continue;
    }
    if (!inHours) continue;
    let text: string;
    try {
      text = renderTemplate(deps.templates[row.variant], valuesFor(row, snapshot.me.name));
    } catch {
      deps.store.transitionOutbox(row.id, "queued", "failed", { detail: "template" }, nowMs);
      continue;
    }
    const mode = modeFor(row.kind, deps.config);
    if (mode === "dry-run") {
      deps.store.transitionOutbox(row.id, "queued", "dry-run", { text }, nowMs);
      deps.log.info("dry-run message recorded", { kind: row.kind });
    } else if (mode === "approval") {
      deps.store.transitionOutbox(row.id, "queued", "pending", { text }, nowMs);
    } else {
      automatic.push({ row, text });
    }
  }
  if (automatic.length === 0) return { sent: 0, failure: undefined };
  return sendBatch(deps, automatic);
}

/** `mra send <id>`: sends one row that is waiting for the Owner's approval. */
export async function sendPending(deps: DispatchDeps, id: number): Promise<SendPendingOutcome> {
  const row = deps.store.getOutbox(id);
  if (row === undefined) return { status: "not-found" };
  if (row.status !== "pending" || row.text === null) return { status: "not-pending" };
  const text = row.text;
  try {
    return await deps.gateway.session((api) => deliver(deps, api, row, text));
  } catch (error) {
    return { status: "retry-later", failure: failureKind(error) };
  }
}

/** `mra skip <id>`: true when a pending, unresolved or queued row was skipped. */
export function skipOutbox(
  store: Pick<Store, "transitionOutbox">,
  id: number,
  now: number,
): boolean {
  return (["pending", "unresolved", "queued"] as const).some((from) =>
    store.transitionOutbox(id, from, "skipped", { detail: "skipped by owner" }, now),
  );
}

/** `mra retry <id>`: puts an unresolved row back in the queue after the Owner fixed `teams.people`. */
export function retryOutbox(
  store: Pick<Store, "transitionOutbox">,
  id: number,
  now: number,
): boolean {
  return store.transitionOutbox(id, "unresolved", "queued", { detail: "" }, now);
}
