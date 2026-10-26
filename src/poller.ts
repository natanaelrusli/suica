import type { Config } from "./config.ts";
import type { Person, Snapshot } from "./domain.ts";
import { countPendingReviews, detectEvents } from "./events.ts";
import type { ActivityEvent, PreviousState } from "./events.ts";
import { execFailure } from "./exec.ts";
import {
  NOTIFY_AFTER,
  STATE_FAILURE_NOTIFICATION,
  failureNotification,
  teamsFailureNotification,
} from "./failures.ts";
import type { FailureKind, FailureTracker, TeamsFailureReportKind } from "./failures.ts";
import type { AlertTemplates } from "./alerts.ts";
import type { Notification } from "./format.ts";
import { baselineNotifications, buildNotifications, rereviewNotifications } from "./format.ts";
import { FetchFailure } from "./gitlab.ts";
import type { GitlabFailureKind } from "./gitlab.ts";
import { firstApprovals, historyEvents } from "./history.ts";
import type { Logger } from "./log.ts";
import type { Notifier } from "./notifier.ts";
import type { Store } from "./store.ts";
import type { TeamsFailureKind } from "./teams/api.ts";
import type { HeldMessage } from "./teams/types.ts";

/** What the poll cycle needs from the Teams feature; absent when `teams.enabled` is false. */
export interface TeamsHooks {
  /** Queues messages for this snapshot. `previous` is the state from before the poll. May throw. */
  plan(snapshot: Snapshot, previous: PreviousState): void;
  /** Sends or holds queued messages. Never throws; reports what went wrong. */
  dispatch(snapshot: Snapshot): Promise<DispatchOutcome>;
}

export interface DispatchOutcome {
  readonly failure: TeamsFailureKind | undefined;
  /** Messages that started waiting for the Owner's approval in this dispatch. */
  readonly held: readonly HeldMessage[];
}

export interface PollDeps {
  readonly fetchSnapshot: () => Promise<Snapshot>;
  readonly store: Store;
  readonly notifier: Notifier;
  readonly failures: FailureTracker;
  readonly log: Logger;
  readonly config: Pick<Config, "gitlab" | "notifications">;
  readonly teams?: TeamsHooks;
  /** The Owner's notification texts; the built-in ones when absent. */
  readonly alerts?: AlertTemplates;
  /** Queues Agent Reviews after the commit; `newRequests` just asked for the Owner's review. May throw. */
  readonly queueReviews?: (snapshot: Snapshot, newRequests: readonly string[]) => void;
  /** Starts the approval recheck of reviewed MRs beside the poll loop (not awaited). May throw. */
  readonly recheckApprovals?: (snapshot: Snapshot) => void;
  /** Queues Agent Fixes for the Owner's MRs after the commit; `previous` is from before the poll. May throw. */
  readonly queueFixes?: (snapshot: Snapshot, previous: PreviousState) => Promise<void>;
  /** Reads the Finding Threads of the Owner's MRs for Lessons; `previous` is from before the poll. Never throws. */
  readonly collectLessons?: (snapshot: Snapshot, previous: PreviousState) => Promise<void>;
  /** Tells the Owner about failed pipelines of their MRs and queues Pipeline Fixes. Never throws. */
  readonly watchPipelines?: (snapshot: Snapshot) => Promise<void>;
  /**
   * Looks a username up in GitLab, so the statistics can show the names of people no open MR
   * shows any more; undefined when GitLab knows no such user. May throw.
   */
  readonly lookupPerson?: (username: string) => Promise<Person | undefined>;
  /** Milliseconds since the epoch; the poll log stamps and times each poll with it. */
  readonly now: () => number;
}

export type PollStatus = "ok" | "paused" | "failed";

const GITLAB_FAILURE_KINDS: readonly GitlabFailureKind[] = [
  "glab-missing",
  "gitlab-auth",
  "gitlab-unreachable",
  "gitlab-error",
];
const TEAMS_FAILURE_KINDS: readonly TeamsFailureReportKind[] = ["teams-unavailable", "teams-error"];

/** Tells the Owner exactly once per failure streak, when the streak reaches the kind's threshold. */
async function reportFailure(
  deps: PollDeps,
  kind: FailureKind,
  notification: Notification | undefined,
  attributes: Readonly<Record<string, string | number>>,
): Promise<void> {
  const streak = deps.failures.fail(kind);
  if (streak !== NOTIFY_AFTER[kind]) {
    deps.log.debug("poll failure not reported", { kind, streak });
    return;
  }
  deps.log.error("poll failed", { kind, ...attributes });
  if (notification === undefined) return;
  try {
    await deps.notifier.notify(notification);
  } catch {
    // The notifier itself is broken; the error log above is the only channel left.
    deps.log.error("failure notification not delivered", { kind });
  }
}

/** Clears a failure streak; logs the recovery when the streak had been reported. */
function recoverFailure(deps: PollDeps, kind: FailureKind): void {
  const streak = deps.failures.recover(kind);
  if (streak >= NOTIFY_AFTER[kind]) {
    deps.log.info("poll failure recovered", { kind, failed_polls: streak });
  }
}

/** One line per detected event, so the log shows what each alert was about. */
function logEvents(log: Logger, events: readonly ActivityEvent[]): void {
  for (const event of events) {
    switch (event.kind) {
      case "review-requested":
        log.info("review requested", { mr_key: event.mr.key });
        break;
      case "reviewer-state":
        log.info("reviewer state changed", { mr_key: event.mr.key, state: event.to });
        break;
      case "comment":
        log.info("comment received", { mr_key: event.mr.key, note_id: event.noteId });
        break;
    }
  }
}

async function reportFetchFailure(deps: PollDeps, error: unknown): Promise<GitlabFailureKind> {
  const kind: GitlabFailureKind = error instanceof FetchFailure ? error.kind : "gitlab-error";
  const reason = error instanceof FetchFailure ? error.message : "unexpected error";
  await reportFailure(deps, kind, failureNotification(kind, deps.config.gitlab.hostname), {
    reason,
  });
  return kind;
}

async function reportStateFailure(deps: PollDeps, error: unknown): Promise<void> {
  // The database error text can name files; log only the error class.
  await reportFailure(deps, "state", STATE_FAILURE_NOTIFICATION, {
    reason: error instanceof Error ? error.name : "unknown",
  });
}

/** Runs after the state commit, on every poll; a problem never fails the poll. */
function recheckApprovals(deps: PollDeps, snapshot: Snapshot): void {
  try {
    deps.recheckApprovals?.(snapshot);
  } catch (error) {
    deps.log.warn("approval recheck not started", {
      reason: error instanceof Error ? error.name : "unknown",
    });
  }
}

function queueReviews(deps: PollDeps, snapshot: Snapshot, events: readonly ActivityEvent[]): void {
  if (deps.queueReviews === undefined) return;
  const keys = events.flatMap((event) => (event.kind === "review-requested" ? [event.mr.key] : []));
  try {
    deps.queueReviews(snapshot, keys);
  } catch (error) {
    deps.log.warn("agent review not queued", {
      reason: error instanceof Error ? error.name : "unknown",
    });
  }
}

/** Runs after the state commit, once the baseline is done; a problem never fails the poll. */
async function queueFixes(
  deps: PollDeps,
  snapshot: Snapshot,
  previous: PreviousState,
): Promise<void> {
  if (deps.queueFixes === undefined || !previous.baselineDone) return;
  try {
    await deps.queueFixes(snapshot, previous);
  } catch (error) {
    deps.log.warn("agent fix not queued", {
      reason: error instanceof Error ? error.name : "unknown",
    });
  }
}

/**
 * One notification per MR for the Re-review Nudges that just started waiting for the Owner. Each
 * row moves to `pending` once, so a failed notification is never repeated and never touches the row.
 */
async function notifyHeldRereviews(deps: PollDeps, held: readonly HeldMessage[]): Promise<void> {
  for (const notification of rereviewNotifications(held, deps.alerts)) {
    try {
      await deps.notifier.notify(notification);
    } catch (error) {
      // Never log the error message: process errors embed the notification text.
      deps.log.warn("re-review notification not delivered", {
        code: String(execFailure(error).code ?? "unknown"),
      });
    }
  }
}

/** Runs after the state commit; a Teams problem never changes the poll status. */
async function runTeams(
  deps: PollDeps,
  snapshot: Snapshot,
  previous: PreviousState,
): Promise<void> {
  const { teams } = deps;
  if (teams === undefined) return;
  try {
    teams.plan(snapshot, previous);
  } catch (error) {
    await reportStateFailure(deps, error);
    return;
  }
  const { failure, held } = await teams.dispatch(snapshot);
  await notifyHeldRereviews(deps, held);
  if (failure === undefined) {
    for (const kind of TEAMS_FAILURE_KINDS) recoverFailure(deps, kind);
    return;
  }
  const kind: TeamsFailureReportKind =
    failure === "unavailable" ? "teams-unavailable" : "teams-error";
  await reportFailure(deps, kind, teamsFailureNotification(kind), {});
}

/** How a poll ended, for the poll log: the failure that ended it, if any. */
interface PollOutcome {
  readonly status: PollStatus;
  readonly failure: FailureKind | null;
}

const PAUSED: PollOutcome = { status: "paused", failure: null };

/**
 * One poll cycle. Order matters: events are delivered first and state is committed next, so a
 * failed delivery is retried on the next poll instead of being marked as seen. The exception is a
 * partial delivery: once at least one notification went out, the state is committed anyway so the
 * delivered ones are never sent again on every following poll. Teams runs last, after the commit.
 */
async function runPoll(deps: PollDeps, start: number): Promise<PollOutcome> {
  const { store, notifier, failures, log, config } = deps;
  if (store.isPaused()) return PAUSED;

  let snapshot: Snapshot;
  try {
    snapshot = await deps.fetchSnapshot();
  } catch (error) {
    return { status: "failed", failure: await reportFetchFailure(deps, error) };
  }
  for (const kind of GITLAB_FAILURE_KINDS) recoverFailure(deps, kind);

  let previous: PreviousState;
  try {
    previous = store.load();
  } catch (error) {
    await reportStateFailure(deps, error);
    return { status: "failed", failure: "state" };
  }
  const events = detectEvents(snapshot, previous, {
    ignoreAuthors: new Set(config.notifications.ignoreAuthors),
  });
  const notifications = previous.baselineDone
    ? buildNotifications(events, config.notifications.summaryThreshold, deps.alerts)
    : baselineNotifications(countPendingReviews(snapshot), deps.alerts);

  let delivered = 0;
  try {
    for (const notification of notifications) {
      await notifier.notify(notification);
      delivered += 1;
    }
  } catch (error) {
    if (failures.fail("notifier") === NOTIFY_AFTER.notifier) {
      // Never log the error message: process errors embed the notification text.
      log.error("notification delivery failed", {
        code: String(execFailure(error).code ?? "unknown"),
        delivered,
        total: notifications.length,
      });
    }
    if (delivered === 0) return { status: "failed", failure: "notifier" };
  }
  if (delivered > 0) {
    log.info("notifications delivered", { count: delivered, total: notifications.length });
  }
  const complete = delivered === notifications.length;
  if (complete) recoverFailure(deps, "notifier");

  try {
    store.commit(
      snapshot,
      historyEvents(snapshot, previous, events, start),
      firstApprovals(events, start),
    );
  } catch (error) {
    await reportStateFailure(deps, error);
    return { status: "failed", failure: "state" };
  }
  recoverFailure(deps, "state");
  if (previous.baselineDone) {
    logEvents(log, events);
  } else {
    log.info("baseline recorded", {
      pending_reviews: countPendingReviews(snapshot),
      authored: snapshot.authored.length,
    });
  }
  queueReviews(deps, snapshot, previous.baselineDone ? events : []);
  recheckApprovals(deps, snapshot);
  await queueFixes(deps, snapshot, previous);
  if (previous.baselineDone) await deps.collectLessons?.(snapshot, previous);
  await deps.watchPipelines?.(snapshot);
  await runTeams(deps, snapshot, previous);
  await lookUpNames(deps);
  log.debug("poll complete", {
    review_requested: snapshot.reviewRequested.length,
    authored: snapshot.authored.length,
    events: events.length,
    notifications: notifications.length,
    baseline: !previous.baselineDone,
  });
  return complete ? { status: "ok", failure: null } : { status: "failed", failure: "notifier" };
}

/** At most this many lookups per poll, so a long history is named over a few polls. */
const NAME_LOOKUPS_PER_POLL = 10;

/** Best effort: a failed lookup is logged and tried again on the next poll. */
async function lookUpNames(deps: PollDeps): Promise<void> {
  const { lookupPerson } = deps;
  if (lookupPerson === undefined) return;
  try {
    for (const username of deps.store.unnamedUsernames(NAME_LOOKUPS_PER_POLL)) {
      // A username GitLab no longer knows keeps itself as its name, so it is not looked up again.
      const person = (await lookupPerson(username)) ?? { username, name: username };
      deps.store.saveNames([person]);
    }
  } catch (error) {
    deps.log.warn("names not looked up", {
      reason: error instanceof FetchFailure ? error.kind : "unknown",
    });
  }
}

/** Runs one poll and logs it, unless polling is paused. A history problem never changes the result. */
export async function pollOnce(deps: PollDeps): Promise<PollStatus> {
  const start = deps.now();
  const { status, failure } = await runPoll(deps, start);
  if (status === "paused") return status;
  try {
    deps.store.recordPoll({ at: start, status, failure, durationMs: deps.now() - start });
  } catch (error) {
    // The database error text can name files; log only the error class.
    deps.log.warn("poll history not recorded", {
      reason: error instanceof Error ? error.name : "unknown",
    });
  }
  return status;
}
