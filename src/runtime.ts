import { renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { defaultStatePath, loadConfig } from "./config.ts";
import type { Config } from "./config.ts";
import { queueAutomaticFixes } from "./agent-fix.ts";
import {
  createReviewWorker,
  queueAutomaticReviews,
  resolvedNote,
  runJudge,
} from "./agent-review.ts";
import { createApprovalRecheck } from "./approval-recheck.ts";
import type { ReviewWorker } from "./agent-review.ts";
import { defaultExec } from "./exec.ts";
import { createFailureTracker } from "./failures.ts";
import {
  fetchCurrentUsername,
  fetchPerson,
  fetchSnapshot,
  glabPost,
  glabPostJson,
  glabRest,
  glabText,
  glabRunner,
} from "./gitlab.ts";
import { createLessonLearner } from "./lessons/learn.ts";
import type { LessonLearner } from "./lessons/learn.ts";
import { createLogger } from "./log.ts";
import type { Logger } from "./log.ts";
import { loadAlerts } from "./alerts.ts";
import { createNotifier } from "./notifier.ts";
import { createFixWorker } from "./fix-runner.ts";
import { watchPipelines } from "./pipeline-watch.ts";
import {
  approveMergeRequest,
  fetchAllDiscussions,
  fetchFixDetail,
  resolveOwnThreads,
} from "./reviews.ts";
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
  /** Learns Lessons from findings; the daemon ticks it after each poll. */
  readonly lessons: LessonLearner;
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

  // Rereads each reviewed MR's posted review with its discussion after every poll, beside it.
  const recheck = createApprovalRecheck({
    store,
    config,
    log,
    now: Date.now,
    discussions: (key) => fetchAllDiscussions(run, key),
    judge: (prompt) =>
      runJudge(
        {
          store,
          config,
          exec: defaultExec,
          now: Date.now,
          ...(signal === undefined ? {} : { signal }),
        },
        prompt,
      ),
    approve: (key, sha) => approveMergeRequest({ post: glabPost(config.gitlab), log }, key, sha),
    resolveOwnThreads: async (key) =>
      resolvedNote(await resolveOwnThreads({ graphql: run, log }, key)),
  });

  // Asked once per run of the agent; a failed lookup is asked again by the next fix.
  let owner: Promise<string> | undefined;
  const ownerName = (): Promise<string> => {
    owner ??= fetchCurrentUsername(glabRest(config.gitlab)).catch((error: unknown) => {
      owner = undefined;
      throw error;
    });
    return owner;
  };
  const fixes = createFixWorker({
    owner: ownerName,
    store,
    config,
    exec: defaultExec,
    graphql: run,
    rest: glabRest(config.gitlab),
    text: glabText(config.gitlab),
    notifier,
    alerts,
    log,
    now: Date.now,
    statePath,
    ...(signal === undefined ? {} : { signal }),
  });

  // Does nothing at all, GitLab and model included, while `lessons.enabled` is false.
  const lessons = createLessonLearner({
    store,
    config,
    exec: defaultExec,
    log,
    now: Date.now,
    busy: () => reviews.busy() || fixes.busy(),
    detail: (key) => fetchFixDetail(run, glabRest(config.gitlab), key),
    onScan: (map) => {
      try {
        const target = join(dirname(statePath), "lesson-scopes.json");
        const temporary = `${target}.${String(process.pid)}.tmp`;
        writeFileSync(temporary, JSON.stringify(map), { mode: 0o600 });
        renameSync(temporary, target);
      } catch (error) {
        log.warn("lesson scopes not written", {
          reason: error instanceof Error ? error.name : "unknown",
        });
      }
    },
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
    recheckApprovals: (snapshot) => {
      void recheck.run(snapshot).catch((error: unknown) => {
        log.warn("approval recheck failed", {
          reason: error instanceof Error ? error.name : "unknown",
        });
      });
    },
    queueFixes: (snapshot, previous) =>
      queueAutomaticFixes(
        {
          store,
          config,
          log,
          now: Date.now,
          detail: (key) => fetchFixDetail(run, glabRest(config.gitlab), key),
        },
        snapshot,
        previous.seenNotes,
      ),
    collectLessons: (snapshot, previous) => lessons.collectThreads(snapshot, previous.seenNotes),
    watchPipelines: (snapshot) =>
      watchPipelines({ store, config, notifier, alerts, log, now: Date.now }, snapshot),
    failures: createFailureTracker(),
    log,
    config,
    now: Date.now,
    ...(teams === undefined ? {} : { teams }),
  };
  return {
    config,
    store,
    log,
    teams,
    reviews,
    fixes,
    lessons,
    statePath,
    poll: () => pollOnce(deps),
  };
}
