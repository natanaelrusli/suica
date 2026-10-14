import type { Config } from "./config.ts";
import type { Logger } from "./log.ts";
import type { PollStatus } from "./poller.ts";
import { nextDelaySeconds } from "./scheduler.ts";

export interface DaemonDeps {
  readonly poll: () => Promise<PollStatus>;
  readonly readIdleSeconds: () => Promise<number>;
  readonly polling: Config["polling"];
  readonly sleep: (ms: number, signal: AbortSignal) => Promise<void>;
  readonly log: Logger;
  readonly signal: AbortSignal;
}

export function abortableSleep(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    if (signal.aborted) {
      resolve();
      return;
    }
    const finish = (): void => {
      clearTimeout(timer);
      signal.removeEventListener("abort", finish);
      resolve();
    };
    const timer = setTimeout(finish, ms);
    signal.addEventListener("abort", finish, { once: true });
  });
}

async function pollSafely(deps: DaemonDeps): Promise<PollStatus> {
  try {
    return await deps.poll();
  } catch (error) {
    deps.log.error("poll crashed", { reason: error instanceof Error ? error.name : "unknown" });
    return "failed";
  }
}

/**
 * Polls until aborted. After a full sleep the sleeping timer simply fires late, and the next poll
 * catches up from stored state, so no separate wake handling is needed.
 */
export async function runDaemon(deps: DaemonDeps): Promise<void> {
  let failureStreak = 0;
  while (!deps.signal.aborted) {
    failureStreak = (await pollSafely(deps)) === "failed" ? failureStreak + 1 : 0;
    const delaySeconds = nextDelaySeconds({
      idleSeconds: await deps.readIdleSeconds(),
      failureStreak,
      polling: deps.polling,
    });
    deps.log.debug("next poll scheduled", { delay_seconds: delaySeconds });
    await deps.sleep(delaySeconds * 1000, deps.signal);
  }
}
