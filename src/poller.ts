import type { Config } from "./config.ts";
import type { Snapshot } from "./domain.ts";
import { countPendingReviews, detectEvents } from "./events.ts";
import type { PreviousState } from "./events.ts";
import { execFailure } from "./exec.ts";
import { NOTIFY_AFTER, STATE_FAILURE_NOTIFICATION, failureNotification } from "./failures.ts";
import type { FailureKind, FailureTracker } from "./failures.ts";
import type { Notification } from "./format.ts";
import { baselineNotifications, buildNotifications } from "./format.ts";
import { FetchFailure } from "./gitlab.ts";
import type { GitlabFailureKind } from "./gitlab.ts";
import type { Logger } from "./log.ts";
import type { Notifier } from "./notifier.ts";
import type { Store } from "./store.ts";

export interface PollDeps {
  readonly fetchSnapshot: () => Promise<Snapshot>;
  readonly store: Store;
  readonly notifier: Notifier;
  readonly failures: FailureTracker;
  readonly log: Logger;
  readonly config: Pick<Config, "gitlab" | "notifications">;
}

export type PollStatus = "ok" | "paused" | "failed";

const GITLAB_FAILURE_KINDS: readonly GitlabFailureKind[] = [
  "glab-missing",
  "gitlab-auth",
  "gitlab-unreachable",
  "gitlab-error",
];

/** Tells the Owner exactly once per failure streak, when the streak reaches the kind's threshold. */
async function reportFailure(
  deps: PollDeps,
  kind: FailureKind,
  notification: Notification | undefined,
  attributes: Readonly<Record<string, string | number>>,
): Promise<void> {
  const streak = deps.failures.fail(kind);
  const threshold = NOTIFY_AFTER[kind];
  if (streak !== threshold) {
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

async function reportFetchFailure(deps: PollDeps, error: unknown): Promise<void> {
  const kind: GitlabFailureKind = error instanceof FetchFailure ? error.kind : "gitlab-error";
  const reason = error instanceof FetchFailure ? error.message : "unexpected error";
  await reportFailure(deps, kind, failureNotification(kind, deps.config.gitlab.hostname), {
    reason,
  });
}

async function reportStateFailure(deps: PollDeps, error: unknown): Promise<void> {
  // The database error text can name files; log only the error class.
  await reportFailure(deps, "state", STATE_FAILURE_NOTIFICATION, {
    reason: error instanceof Error ? error.name : "unknown",
  });
}

/**
 * One poll cycle. Order matters: events are delivered first and state is committed last, so a
 * failed delivery is retried on the next poll instead of being marked as seen. The exception is a
 * partial delivery: once at least one notification went out, the state is committed anyway so the
 * delivered ones are never sent again on every following poll.
 */
export async function pollOnce(deps: PollDeps): Promise<PollStatus> {
  const { store, notifier, failures, log, config } = deps;
  if (store.isPaused()) {
    log.debug("polling paused");
    return "paused";
  }

  let snapshot: Snapshot;
  try {
    snapshot = await deps.fetchSnapshot();
  } catch (error) {
    await reportFetchFailure(deps, error);
    return "failed";
  }
  for (const kind of GITLAB_FAILURE_KINDS) failures.recover(kind);

  let previous: PreviousState;
  try {
    previous = store.load();
  } catch (error) {
    await reportStateFailure(deps, error);
    return "failed";
  }
  const notifications = previous.baselineDone
    ? buildNotifications(
        detectEvents(snapshot, previous, {
          ignoreAuthors: new Set(config.notifications.ignoreAuthors),
        }),
        config.notifications.summaryThreshold,
      )
    : baselineNotifications(countPendingReviews(snapshot));

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
    if (delivered === 0) return "failed";
  }
  const complete = delivered === notifications.length;
  if (complete) failures.recover("notifier");

  try {
    store.commit(snapshot);
  } catch (error) {
    await reportStateFailure(deps, error);
    return "failed";
  }
  failures.recover("state");
  log.debug("poll complete", {
    review_requested: snapshot.reviewRequested.length,
    authored: snapshot.authored.length,
    notifications: notifications.length,
    baseline: !previous.baselineDone,
  });
  return complete ? "ok" : "failed";
}
