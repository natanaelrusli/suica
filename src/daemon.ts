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

const SLEEP_SLICE_MS = 15_000;

/**
 * Sleeps until a wall-clock deadline, in short slices. Node timers run on a monotonic clock that
 * does not advance while the Mac is asleep, so one long `setTimeout` would end late after a wake;
 * re-checking the wall clock every slice lets the next poll start within one slice of the wake.
 */
export function abortableSleep(
  ms: number,
  signal: AbortSignal,
  now: () => number = Date.now,
): Promise<void> {
  return new Promise((resolve) => {
    if (signal.aborted) {
      resolve();
      return;
    }
    const deadline = now() + ms;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const finish = (): void => {
      clearTimeout(timer);
      signal.removeEventListener("abort", finish);
      resolve();
    };
    const tick = (): void => {
      const remaining = deadline - now();
      if (remaining <= 0) {
        finish();
        return;
      }
      timer = setTimeout(tick, Math.min(remaining, SLEEP_SLICE_MS));
    };
    signal.addEventListener("abort", finish, { once: true });
    tick();
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
 * Polls until aborted. After a full sleep the wall-clock sleep above ends within one slice of the
 * wake, and the next poll catches up from stored state, so no separate wake handling is needed.
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
