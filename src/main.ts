import { defaultConfigPath } from "./config.ts";
import { tickEvery } from "./agent-review.ts";
import { abortableSleep, runDaemon } from "./daemon.ts";
import { readIdleSeconds } from "./idle.ts";
import { createLogger } from "./log.ts";
import { createRuntime } from "./runtime.ts";

const REVIEW_TICK_MS = 2000;

async function main(): Promise<void> {
  const controller = new AbortController();
  process.once("SIGTERM", () => {
    controller.abort();
  });
  process.once("SIGINT", () => {
    controller.abort();
  });

  const runtime = createRuntime(defaultConfigPath(), controller.signal);
  const { config } = runtime;
  const startedAt = Date.now();
  runtime.log.info("daemon started", {
    pid: process.pid,
    node: process.version,
    poll_active_seconds: config.polling.activeSeconds,
    poll_idle_seconds: config.polling.idleSeconds,
    teams_enabled: config.teams.enabled,
    model_cli: config.model.cli,
    review_auto: config.review.auto,
    review_post: config.review.post,
    review_concurrency: config.review.concurrency,
  });
  const interrupted = runtime.store.failInterruptedAgentReviews(Date.now());
  if (interrupted > 0) runtime.log.warn("agent reviews interrupted", { count: interrupted });
  const recovered = runtime.store.recoverStalePostings(Date.now());
  if (recovered > 0) runtime.log.warn("agent review posts interrupted", { count: recovered });
  tickEvery(runtime.reviews, REVIEW_TICK_MS, controller.signal);
  try {
    await runDaemon({
      // A queued review starts right after the poll too, and runs beside the loop.
      poll: async () => {
        const status = await runtime.poll();
        runtime.reviews.tick();
        return status;
      },
      readIdleSeconds: () => readIdleSeconds(),
      polling: runtime.config.polling,
      sleep: abortableSleep,
      log: runtime.log,
      signal: controller.signal,
    });
  } finally {
    await runtime.reviews.idle();
    runtime.store.close();
  }
  runtime.log.info("daemon stopped", {
    uptime_seconds: Math.round((Date.now() - startedAt) / 1000),
  });
}

main().catch((error: unknown) => {
  // Startup failure (bad config, unwritable state): log once and exit non-zero so launchd throttles restarts.
  createLogger().error("startup failed", {
    reason: error instanceof Error ? error.message : "unknown",
  });
  process.exitCode = 1;
});
