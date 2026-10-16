import { homedir } from "node:os";
import { join } from "node:path";
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
import { createTeamsGateway } from "./teams/gateway.ts";
import { createTeamsService } from "./teams/service.ts";
import type { TeamsService } from "./teams/service.ts";
import { defaultTemplatesPath, loadTemplates } from "./teams/templates.ts";

export interface Runtime {
  readonly config: Config;
  readonly store: Store;
  readonly log: Logger;
  /** Undefined when `teams.enabled` is false. */
  readonly teams: TeamsService | undefined;
  poll(): Promise<PollStatus>;
}

const MS_PER_SECOND = 1000;

function defaultTeamsCommand(): string {
  return join(homedir(), ".config", "teams-mcp", "run.sh");
}

export function createRuntime(configPath: string): Runtime {
  const log = createLogger();
  const config = loadConfig(configPath);
  const store = openStore(config.statePath ?? defaultStatePath());
  const run = glabRunner(config.gitlab);

  // A bad template stops startup (TemplateError) instead of producing broken messages later.
  const teams = config.teams.enabled
    ? createTeamsService({
        store,
        gateway: createTeamsGateway({
          command: config.teams.command ?? defaultTeamsCommand(),
          startTimeoutMs: config.teams.startTimeoutSeconds * MS_PER_SECOND,
          callTimeoutMs: config.teams.callTimeoutSeconds * MS_PER_SECOND,
        }),
        templates: loadTemplates(config.teams.templatesPath ?? defaultTemplatesPath()),
        config: config.teams,
        log,
        now: Date.now,
      })
    : undefined;

  // While Teams is off nothing keeps the ledger current: forget it so that switching Teams on
  // later seeds from the then-current state and never announces what happened in between.
  if (teams === undefined) store.resetTeamsBaseline();

  const deps: PollDeps = {
    fetchSnapshot: () => fetchSnapshot(run),
    store,
    notifier: createNotifier(),
    failures: createFailureTracker(),
    log,
    config,
    ...(teams === undefined ? {} : { teams }),
  };
  return { config, store, log, teams, poll: () => pollOnce(deps) };
}
