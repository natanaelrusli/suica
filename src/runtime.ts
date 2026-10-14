import { defaultStatePath, loadConfig } from "./config.ts";
import type { Config } from "./config.ts";
import { createFailureTracker } from "./failures.ts";
import { fetchSnapshot, glabRunner } from "./gitlab.ts";
import { createLogger } from "./log.ts";
import type { Logger } from "./log.ts";
import { createNotifier } from "./notifier.ts";
import { pollOnce } from "./poller.ts";
import type { PollDeps, PollStatus } from "./poller.ts";
import { openStore } from "./store.ts";
import type { Store } from "./store.ts";

export interface Runtime {
  readonly config: Config;
  readonly store: Store;
  readonly log: Logger;
  poll(): Promise<PollStatus>;
}

export function createRuntime(configPath: string): Runtime {
  const log = createLogger();
  const config = loadConfig(configPath);
  const store = openStore(config.statePath ?? defaultStatePath());
  const run = glabRunner(config.gitlab);
  const deps: PollDeps = {
    fetchSnapshot: () => fetchSnapshot(run),
    store,
    notifier: createNotifier(),
    failures: createFailureTracker(),
    log,
    config,
  };
  return { config, store, log, poll: () => pollOnce(deps) };
}
