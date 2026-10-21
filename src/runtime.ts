import { homedir } from "node:os";
import { join } from "node:path";
import { defaultStatePath, loadConfig } from "./config.ts";
import type { Config } from "./config.ts";
import { queueAutomaticFixes } from "./agent-fix.ts";
import { createReviewWorker, queueAutomaticReviews } from "./agent-review.ts";
import type { ReviewWorker } from "./agent-review.ts";
import { defaultExec } from "./exec.ts";
import { createFailureTracker } from "./failures.ts";
import {
  fetchPerson,
  fetchSnapshot,
  glabPost,
  glabPostJson,
  glabRest,
  glabRunner,
} from "./gitlab.ts";
import { createLogger } from "./log.ts";
import type { Logger } from "./log.ts";
import { loadAlerts } from "./alerts.ts";
import { createNotifier } from "./notifier.ts";
import { createFixWorker } from "./fix-runner.ts";
import { fetchMrDetail } from "./reviews.ts";
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
  /** Runs queued Agent Reviews; only the daemon ticks it. */
  readonly reviews: ReviewWorker;
  /** Runs queued Agent Fixes, one at a time; only the daemon ticks it. */
  readonly fixes: ReviewWorker;
  /** The state database's path; Agent Fix checkouts live beside it. */
  readonly statePath: string;
  poll(): Promise<PollStatus>;
}

const MS_PER_SECOND = 1000;

function defaultTeamsCommand(): string {
  return join(homedir(), ".config", "teams-mcp", "run.sh");
}

/** `signal` stops a running Agent Review when the daemon shuts down. */
export function createRuntime(configPath: string, signal?: AbortSignal): Runtime {
  const log = createLogger();
  const config = loadConfig(configPath);
  const statePath = config.statePath ?? defaultStatePath();
  const store = openStore(statePath);
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

  // A bad notification template stops startup too, whether Teams is on or not.
  const alerts = loadAlerts(config.teams.templatesPath ?? defaultTemplatesPath());
  const notifier = createNotifier();
  const reviews = createReviewWorker({
    store,
    config,
    exec: defaultExec,
    graphql: run,
    rest: glabRest(config.gitlab),
    post: glabPost(config.gitlab),
    postJson: glabPostJson(config.gitlab),
    notifier,
    alerts,
    log,
    now: Date.now,
    ...(signal === undefined ? {} : { signal }),
  });

  const fixes = createFixWorker({
    store,
    config,
    exec: defaultExec,
    graphql: run,
    rest: glabRest(config.gitlab),
    notifier,
    alerts,
    log,
    now: Date.now,
    statePath,
    ...(signal === undefined ? {} : { signal }),
  });

  const deps: PollDeps = {
    fetchSnapshot: () => fetchSnapshot(run),
    lookupPerson: (username) => fetchPerson(glabRest(config.gitlab), username),
    store,
    notifier,
    alerts,
    queueReviews: (snapshot, newRequests) => {
      queueAutomaticReviews({ store, config, log, now: Date.now }, snapshot, newRequests);
    },
    queueFixes: (snapshot, previous) =>
      queueAutomaticFixes(
        {
          store,
          config,
          log,
          now: Date.now,
          detail: (key) => fetchMrDetail(run, glabRest(config.gitlab), key),
        },
        snapshot,
        previous.seenNotes,
      ),
    failures: createFailureTracker(),
    log,
    config,
    now: Date.now,
    ...(teams === undefined ? {} : { teams }),
  };
  return { config, store, log, teams, reviews, fixes, statePath, poll: () => pollOnce(deps) };
}
