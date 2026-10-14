import { defaultConfigPath } from "./config.ts";
import { abortableSleep, runDaemon } from "./daemon.ts";
import { readIdleSeconds } from "./idle.ts";
import { createLogger } from "./log.ts";
import { createRuntime } from "./runtime.ts";

async function main(): Promise<void> {
  const controller = new AbortController();
  process.once("SIGTERM", () => {
    controller.abort();
  });
  process.once("SIGINT", () => {
    controller.abort();
  });

  const runtime = createRuntime(defaultConfigPath());
  runtime.log.info("daemon started");
  try {
    await runDaemon({
      poll: () => runtime.poll(),
      readIdleSeconds: () => readIdleSeconds(),
      polling: runtime.config.polling,
      sleep: abortableSleep,
      log: runtime.log,
      signal: controller.signal,
    });
  } finally {
    runtime.store.close();
  }
  runtime.log.info("daemon stopped");
}

main().catch((error: unknown) => {
  // Startup failure (bad config, unwritable state): log once and exit non-zero so launchd throttles restarts.
  createLogger().error("startup failed", {
    reason: error instanceof Error ? error.message : "unknown",
  });
  process.exitCode = 1;
});
