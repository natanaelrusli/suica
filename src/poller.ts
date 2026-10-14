import type { Config } from "./config.ts";
import type { Snapshot } from "./domain.ts";
import { countPendingReviews, detectEvents } from "./events.ts";
import { execFailure } from "./exec.ts";
import { failureNotification } from "./failures.ts";
import type { FailureTracker } from "./failures.ts";
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

async function reportFetchFailure(deps: PollDeps, error: unknown): Promise<void> {
  const kind: GitlabFailureKind = error instanceof FetchFailure ? error.kind : "gitlab-error";
  const reason = error instanceof FetchFailure ? error.message : "unexpected error";
  if (!deps.failures.fail(kind)) {
    deps.log.warn("gitlab poll still failing", { kind });
    return;
  }
  deps.log.error("gitlab poll failed", { kind, reason });
  try {
    await deps.notifier.notify(failureNotification(kind, deps.config.gitlab.hostname));
  } catch {
    // The notifier itself is broken; the error log above is the only channel left.
    deps.log.error("failure notification not delivered", { kind });
  }
}

/**
 * One poll cycle. Order matters: events are delivered first and state is committed last, so a
 * failed delivery is retried on the next poll instead of being marked as seen.
 */
export async function pollOnce(deps: PollDeps): Promise<PollStatus> {
  const { store, notifier, failures, log, config } = deps;
  if (store.isPaused()) {
    log.info("polling paused");
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

  const previous = store.load();
  const notifications = previous.baselineDone
    ? buildNotifications(
        detectEvents(snapshot, previous, {
          ignoreAuthors: new Set(config.notifications.ignoreAuthors),
        }),
        config.notifications.summaryThreshold,
      )
    : baselineNotifications(countPendingReviews(snapshot));

  try {
    for (const notification of notifications) await notifier.notify(notification);
  } catch (error) {
    if (failures.fail("notifier")) {
      // Never log the error message: process errors embed the notification text.
      log.error("notification delivery failed", {
        code: String(execFailure(error).code ?? "unknown"),
      });
    }
    return "failed";
  }
  failures.recover("notifier");

  store.commit(snapshot);
  log.debug("poll complete", {
    review_requested: snapshot.reviewRequested.length,
    authored: snapshot.authored.length,
    notifications: notifications.length,
    baseline: !previous.baselineDone,
  });
  return "ok";
}
