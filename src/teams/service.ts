import type { Config } from "../config.ts";
import type { Snapshot } from "../domain.ts";
import type { PreviousState } from "../events.ts";
import type { Logger } from "../log.ts";
import type { DispatchOutcome, TeamsHooks } from "../poller.ts";
import type { Store } from "../store.ts";
import {
  dispatchQueued,
  draftManual,
  retryOutbox,
  sendManual,
  sendPending,
  skipOutbox,
} from "./dispatch.ts";
import type { DispatchDeps, SendPendingOutcome } from "./dispatch.ts";
import type { TeamsGateway } from "./gateway.ts";
import { planTeams } from "./plan.ts";
import type { Templates } from "./templates.ts";
import { ATTENTION_STATUSES, OUTBOX_STATUSES } from "./types.ts";
import type { Intent, OutboxKind, OutboxRow } from "./types.ts";

export interface TeamsService extends TeamsHooks {
  sendPending(id: number): Promise<SendPendingOutcome>;
  /** The template's text for a message the Owner is about to send by hand. */
  draft(intent: Intent, ownerName: string): string;
  /** Sends a message the Owner wrote or approved on an MR page, now. */
  sendManual(intent: Intent, text: string): Promise<SendPendingOutcome>;
  /** Rows that need attention, or every row when `all` is true. */
  list(all: boolean): OutboxRow[];
  skip(id: number): boolean;
  retry(id: number): boolean;
  /** Hides a finished row from `list`; the row stays for stats. */
  clear(id: number): boolean;
  /** Hides every sent, skipped or dry-run row of these kinds from `list`; how many. */
  clearRecent(kinds: readonly OutboxKind[]): number;
  /** Sends a fixed test line to the Owner's own notes chat; proves the MCP path end to end. */
  selfTest(): Promise<void>;
}

export interface ServiceDeps {
  readonly store: Store;
  readonly gateway: TeamsGateway;
  readonly templates: Templates;
  readonly config: Config["teams"];
  readonly log: Logger;
  readonly now: () => number;
}

const HOUR_MS = 3_600_000;
const MINUTE_MS = 60_000;
const SELF_CHAT_ID = "48:notes";
const SELF_TEST_TEXT = "Suica: tes koneksi Teams berhasil.";

export function createTeamsService(deps: ServiceDeps): TeamsService {
  const dispatchDeps: DispatchDeps = {
    store: deps.store,
    gateway: deps.gateway,
    templates: deps.templates,
    config: deps.config,
    log: deps.log,
    now: deps.now,
  };
  return {
    plan(snapshot: Snapshot, previous: PreviousState): void {
      const now = deps.now();
      const plan = planTeams({
        snapshot,
        previous,
        state: deps.store.loadTeams(),
        now,
        config: {
          maxMessagesPerReviewer: deps.config.maxMessagesPerReviewer,
          reminderAfterMs: deps.config.reminderAfterHours * HOUR_MS,
          noticeDebounceMs: deps.config.noticeDebounceMinutes * MINUTE_MS,
          rereviewAfterMs: deps.config.rereviewAfterMinutes * MINUTE_MS,
        },
      });
      const created = deps.store.applyTeamsPlan(plan, now);
      if (created > 0) deps.log.info("teams messages queued", { count: created });
    },

    async dispatch(snapshot: Snapshot): Promise<DispatchOutcome> {
      try {
        const result = await dispatchQueued(dispatchDeps, snapshot);
        return { failure: result.failure, held: result.held };
      } catch (error) {
        deps.log.error("teams dispatch crashed", {
          reason: error instanceof Error ? error.name : "unknown",
        });
        return { failure: "error", held: [] };
      }
    },

    sendPending: (id) => sendPending(dispatchDeps, id),
    draft: (intent, ownerName) => draftManual(dispatchDeps, intent, ownerName),
    sendManual: (intent, text) => sendManual(dispatchDeps, intent, text),
    list: (all) =>
      deps.store.listOutbox(all ? OUTBOX_STATUSES : ATTENTION_STATUSES, { hideCleared: true }),
    skip: (id) => skipOutbox(deps.store, id, deps.now()),
    retry: (id) => retryOutbox(deps.store, id, deps.now()),
    clear: (id) => deps.store.clearOutbox(id, deps.now()),
    clearRecent: (kinds) => deps.store.clearRecentOutbox(kinds, deps.now()),
    selfTest: () =>
      deps.gateway.session(async (api) => {
        await api.sendMessage(SELF_CHAT_ID, SELF_TEST_TEXT);
      }),
  };
}
