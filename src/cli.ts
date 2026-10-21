import { homedir } from "node:os";
import { join } from "node:path";
import { installAgent, plistPath, uninstallAgent } from "./agent-install.ts";
import { buildStatus, loadStatusInput, readServiceStatus, restartService } from "./agent-status.ts";
import { actionJson, buildAgentState } from "./agent-state.ts";
import { defaultConfigPath, defaultStatePath, loadConfig } from "./config.ts";
import { applyConfigEdits, parseSaveRequest, showConfig } from "./config-edit.ts";
import type { SaveResultJson } from "./config-edit.ts";
import { defaultExec } from "./exec.ts";
import { fetchSnapshot, glabPost, glabPostJson, glabPut, glabRest, glabRunner } from "./gitlab.ts";
import { detectModelClis } from "./model-cli.ts";
import { commentOnMergeRequest, mergeMergeRequest } from "./mr-actions.ts";
import {
  approveMergeRequest,
  buildReviewActivity,
  buildReviewList,
  fetchMrDetail,
  parseMrKey,
  resolveOwnThreads,
} from "./reviews.ts";
import {
  cancelAgentReview,
  discardAgentReview,
  postAgentReview,
  rereviewWaitingReasons,
} from "./agent-review.ts";
import { parseTemplateRequest, saveTemplate, showTemplates } from "./template-edit.ts";
import { defaultTemplatesPath } from "./teams/templates.ts";
import type { TemplateSaveJson } from "./template-edit.ts";
import { createLogger } from "./log.ts";
import { createRuntime } from "./runtime.ts";
import type { Runtime } from "./runtime.ts";
import { RANKING_WINDOW, buildStats, localDayKey } from "./stats.ts";
import { openStore } from "./store.ts";
import { formatOutbox } from "./teams/format-outbox.ts";
import { OUTBOX_STATUSES } from "./teams/types.ts";
import { buildUsage } from "./usage.ts";

const USAGE =
  "usage: suica <once|status|state|stats|usage|pause|resume|pending [--all]|send <id> [--json]|skip <id> [--json]|retry <id> [--json]|selftest|reviews --json|mr <key> --json|mr approve <key> <sha> --json|mr comment <key> --json (body on stdin)|mr merge <key> <sha> [--squash] [--remove-source-branch] [--when-pipeline-succeeds] --json (message on stdin)|review queue <key> --json|review post <id> [--inline|--comment] --json|review discard <id> --json|review cancel <id> --json|config show --json|config set --json|templates show --json|templates set --json|agent install|agent uninstall|agent restart --json>\n";
const TEAMS_DISABLED = "teams is disabled: set teams.enabled to true in the config\n";
const SHOWN_WITH_ALL = 50;

const SIMPLE = new Set([
  "once",
  "status",
  "state",
  "stats",
  "usage",
  "pause",
  "resume",
  "selftest",
  "pending",
]);
const WITH_ID = new Set(["send", "skip", "retry"]);

function parseId(value: string | undefined): number | undefined {
  return value !== undefined && /^\d+$/.test(value) ? Number(value) : undefined;
}

async function run(runtime: Runtime, command: string, argv: readonly string[]): Promise<number> {
  const { teams } = runtime;
  switch (command) {
    case "once": {
      const status = await runtime.poll();
      process.stdout.write(`poll: ${status}\n`);
      return status === "failed" ? 1 : 0;
    }
    case "status": {
      const state = runtime.store.load();
      const lines = [
        `paused: ${runtime.store.isPaused() ? "yes" : "no"}`,
        `baseline: ${state.baselineDone ? "done" : "pending"}`,
        `tracked authored MRs: ${state.trackedAuthored.size}`,
        `review-requested MRs known: ${state.myReviewStates.size}`,
      ];
      if (teams !== undefined) {
        const rows = teams.list(true);
        const counts = OUTBOX_STATUSES.map(
          (status) => `${status} ${rows.filter((row) => row.status === status).length}`,
        );
        lines.push(`teams outbox: ${counts.join(", ")}`);
      }
      process.stdout.write(`${lines.join("\n")}\n`);
      return 0;
    }
    case "state": {
      const state = runtime.store.load();
      const document = buildAgentState({
        paused: runtime.store.isPaused(),
        baselineDone: state.baselineDone,
        trackedAuthored: state.trackedAuthored.size,
        reviewRequested: state.myReviewStates.size,
        agentReview: buildReviewActivity(
          runtime.store.agentReviewActivity(),
          runtime.config.review.model,
        ),
        rows: teams?.list(true),
      });
      process.stdout.write(`${JSON.stringify(document)}\n`);
      return 0;
    }
    case "pause":
      runtime.store.setPaused(true);
      process.stdout.write("paused\n");
      return 0;
    case "resume":
      runtime.store.setPaused(false);
      process.stdout.write("resumed\n");
      return 0;
  }

  if (teams === undefined) {
    process.stderr.write(TEAMS_DISABLED);
    return 1;
  }
  switch (command) {
    case "pending": {
      const all = argv.includes("--all");
      const rows = teams.list(all);
      process.stdout.write(formatOutbox(all ? rows.slice(-SHOWN_WITH_ALL) : rows));
      return 0;
    }
    case "selftest":
      await teams.selfTest();
      process.stdout.write("sent a test line to your own Teams notes chat\n");
      return 0;
    default: {
      const id = parseId(argv[1]);
      if (id === undefined) {
        process.stderr.write(USAGE);
        return 2;
      }
      const json = argv.includes("--json");
      if (command === "send") {
        const outcome = await teams.sendPending(id);
        process.stdout.write(
          json ? `${actionJson(outcome.status)}\n` : `send #${id}: ${outcome.status}\n`,
        );
        return outcome.status === "sent" ? 0 : 1;
      }
      const done = command === "skip" ? teams.skip(id) : teams.retry(id);
      if (json) {
        const code = done ? (command === "skip" ? "skipped" : "retried") : "nothing";
        process.stdout.write(`${actionJson(code)}\n`);
      } else {
        process.stdout.write(`${command} #${id}: ${done ? "done" : "nothing to do"}\n`);
      }
      return done ? 0 : 1;
    }
  }
}

/** `suica status --json`: works with a broken config, so it never creates the runtime. */
async function statusJson(): Promise<number> {
  const configPath = defaultConfigPath();
  const service = await readServiceStatus(defaultExec, process.getuid?.() ?? 0);
  const loaded = loadStatusInput(configPath, { loadConfig, openStore });
  const logsPath = join(homedir(), "Library", "Logs", "suica");
  const modelClis = detectModelClis();
  const document = buildStatus({ service, configPath, logsPath, modelClis, loaded });
  process.stdout.write(`${JSON.stringify(document)}\n`);
  return 0;
}

/**
 * `suica stats`: reads the config and the state database only. It never creates the runtime, which
 * would load the Teams templates and, while Teams is off, write to the database on every call.
 */
function statsJson(): number {
  const config = loadConfig(defaultConfigPath());
  const store = openStore(config.statePath ?? defaultStatePath());
  try {
    const now = Date.now();
    const document = buildStats({
      // The rankings reach back furthest; a turnaround starts at most 60 days back.
      history: store.loadHistory(now - RANKING_WINDOW),
      approvals: store.loadApprovals(now - RANKING_WINDOW),
      names: store.loadNames(),
      outbox: config.teams.enabled ? store.listOutbox(OUTBOX_STATUSES) : [],
      now,
      days: 14,
      dayKey: localDayKey,
    });
    process.stdout.write(`${JSON.stringify(document)}\n`);
    return 0;
  } finally {
    store.close();
  }
}

const USAGE_HISTORY_MS = 30 * 86_400_000;

/** `suica usage`: language model tokens. Like `suica stats`, it never creates the runtime. */
function usageJson(): number {
  const config = loadConfig(defaultConfigPath());
  const store = openStore(config.statePath ?? defaultStatePath());
  try {
    const now = Date.now();
    const document = buildUsage({
      rows: store.loadTokenUsage(now - USAGE_HISTORY_MS),
      now,
      days: 14,
      dayKey: localDayKey,
    });
    process.stdout.write(`${JSON.stringify(document)}\n`);
    return 0;
  } finally {
    store.close();
  }
}

/** `suica reviews --json` and `suica mr <key> --json`: no runtime. */
async function reviewsJson(): Promise<number> {
  const config = loadConfig(defaultConfigPath());
  const snapshot = await fetchSnapshot(glabRunner(config.gitlab));
  const store = openStore(config.statePath ?? defaultStatePath());
  try {
    store.recoverStalePostings(Date.now());
    const document = buildReviewList(
      snapshot,
      store.latestAgentReviews(),
      store.rereviewBases(),
      rereviewWaitingReasons(store, config, snapshot, Date.now()),
    );
    process.stdout.write(`${JSON.stringify(document)}\n`);
    return 0;
  } finally {
    store.close();
  }
}

/**
 * `suica review queue|post|discard|cancel`: the background agent starts a queued review within a few
 * seconds; post and discard act on a review that waits for the Owner, and cancel stops a queued or
 * running one. `post` takes `--inline` or `--comment`, else `review.postAs`. Each prints
 * `{"status": …}`.
 */
async function reviewCommand(argv: readonly string[]): Promise<number> {
  const [action, target] = [argv[1], argv[2]];
  const config = loadConfig(defaultConfigPath());
  const store = openStore(config.statePath ?? defaultStatePath());
  const reply = (status: string, ok: boolean): number => {
    process.stdout.write(`${actionJson(status)}\n`);
    return ok ? 0 : 1;
  };
  try {
    if (action === "queue") {
      if (target === undefined || parseMrKey(target) === undefined) return reply("bad-key", false);
      const id = store.queueAgentReview(target, "manual", Date.now());
      return id === undefined ? reply("already-queued", true) : reply("queued", true);
    }
    const id = parseId(target);
    if (id === undefined || !["post", "discard", "cancel"].includes(action ?? "")) {
      process.stderr.write(USAGE);
      return 2;
    }
    if (action === "discard") {
      const done = discardAgentReview(store, id, Date.now());
      return reply(done ? "discarded" : "nothing", done);
    }
    if (action === "cancel") {
      const done = cancelAgentReview(store, id, Date.now());
      return reply(done ? "cancelled" : "nothing", done);
    }
    const mode = argv.includes("--inline")
      ? "inline"
      : argv.includes("--comment")
        ? "comment"
        : config.review.postAs;
    const outcome = await postAgentReview(
      {
        store,
        config,
        now: Date.now,
        log: createLogger(),
        rest: glabRest(config.gitlab),
        graphql: glabRunner(config.gitlab),
        post: glabPost(config.gitlab),
        postJson: glabPostJson(config.gitlab),
      },
      id,
      mode,
    );
    return reply(outcome, outcome === "posted");
  } finally {
    store.close();
  }
}

async function mrJson(key: string): Promise<number> {
  const { gitlab } = loadConfig(defaultConfigPath());
  const document = await fetchMrDetail(glabRunner(gitlab), glabRest(gitlab), key);
  process.stdout.write(`${JSON.stringify(document)}\n`);
  return 0;
}

/**
 * `suica mr approve <key> <sha> --json`: approves as the Owner at that commit, then resolves the
 * open threads the Owner started; prints `{"status": …}`.
 */
async function approveCommand(key: string, sha: string): Promise<number> {
  const { gitlab } = loadConfig(defaultConfigPath());
  const log = createLogger();
  const outcome = await approveMergeRequest({ post: glabPost(gitlab), log }, key, sha);
  if (outcome === "approved") await resolveOwnThreads({ graphql: glabRunner(gitlab), log }, key);
  process.stdout.write(`${actionJson(outcome)}\n`);
  return outcome === "approved" ? 0 : 1;
}

/** `suica mr comment <key> --json`: the Markdown body comes on stdin; prints `{"status": …}`. */
async function commentCommand(key: string): Promise<number> {
  const { gitlab } = loadConfig(defaultConfigPath());
  const body = await readLimitedStdin(MAX_REQUEST_BYTES);
  const outcome =
    body === undefined ? "failed" : await commentOnMergeRequest(glabPost(gitlab), key, body);
  createLogger().info("mr comment posted", { mr_key: key, outcome });
  process.stdout.write(`${actionJson(outcome)}\n`);
  return outcome === "posted" ? 0 : 1;
}

/**
 * `suica mr merge <key> <sha> --json`: merges at the commit the Owner saw, with the commit message
 * on stdin; prints `{"status": …}`.
 */
async function mergeCommand(key: string, sha: string, argv: readonly string[]): Promise<number> {
  const { gitlab } = loadConfig(defaultConfigPath());
  const message = await readLimitedStdin(MAX_REQUEST_BYTES);
  const outcome =
    message === undefined
      ? "failed"
      : await mergeMergeRequest(glabPut(gitlab), key, sha, {
          squash: argv.includes("--squash"),
          removeSourceBranch: argv.includes("--remove-source-branch"),
          message,
          whenPipelineSucceeds: argv.includes("--when-pipeline-succeeds"),
        });
  createLogger().info("mr merge", { mr_key: key, outcome });
  process.stdout.write(`${actionJson(outcome)}\n`);
  return outcome === "merged" || outcome === "scheduled" ? 0 : 1;
}

async function installAgentCommand(): Promise<number> {
  const paths = {
    node: process.execPath,
    main: join(import.meta.dirname, "main.ts"),
    home: homedir(),
  };
  const configPath = defaultConfigPath();
  const outcome = await installAgent(defaultExec, process.getuid?.() ?? 0, paths, configPath);
  switch (outcome) {
    case "installed":
      process.stdout.write(`installed ${plistPath(paths.home)} (node: ${paths.node})\n`);
      return 0;
    case "no-config":
      process.stderr.write(`config not found: ${configPath} (see README, Setup)\n`);
      return 1;
    case "failed":
      process.stderr.write(`launchctl could not load ${plistPath(paths.home)}\n`);
      return 1;
  }
}

async function uninstallAgentCommand(): Promise<number> {
  const removed = await uninstallAgent(defaultExec, process.getuid?.() ?? 0, homedir());
  process.stdout.write(
    removed ? "removed the background agent\n" : "the background agent was not installed\n",
  );
  return 0;
}

async function restartAgent(): Promise<number> {
  const result = await restartService(defaultExec, process.getuid?.() ?? 0);
  process.stdout.write(`${actionJson(result)}\n`);
  return result === "restarted" ? 0 : 1;
}

const MAX_REQUEST_BYTES = 1024 * 1024;

/** The whole of stdin, or undefined when it is larger than the limit. */
async function readLimitedStdin(limit: number): Promise<string | undefined> {
  const chunks: Buffer[] = [];
  let total = 0;
  for await (const chunk of process.stdin as AsyncIterable<Buffer>) {
    total += chunk.length;
    if (total > limit) {
      process.stdin.destroy();
      return undefined;
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString("utf8");
}

/** `suica config set --json`: edits on stdin; works with a broken config, so no runtime. */
async function setConfig(): Promise<number> {
  const text = await readLimitedStdin(MAX_REQUEST_BYTES);
  const request = text === undefined ? undefined : parseSaveRequest(text);
  let result: SaveResultJson;
  if (request === undefined) {
    const message = text === undefined ? "request is too large" : "malformed request";
    result = { status: "bad-request", issues: [{ path: "(root)", message }], sha256: null };
  } else {
    result = applyConfigEdits(defaultConfigPath(), request);
  }
  process.stdout.write(`${JSON.stringify(result)}\n`);
  return result.status === "saved" ? 0 : 1;
}

/** The templates folder the agent loads; undefined when the config does not load. */
function templatesDirectory(): string | undefined {
  try {
    return loadConfig(defaultConfigPath()).teams.templatesPath ?? defaultTemplatesPath();
  } catch {
    return undefined;
  }
}

/** `suica templates show|set --json`: no runtime, so it works while the agent is stopped. */
async function templatesCommand(action: string | undefined): Promise<number> {
  const directory = templatesDirectory();
  const reply = (result: TemplateSaveJson): number => {
    process.stdout.write(`${JSON.stringify(result)}\n`);
    return result.status === "saved" || result.status === "reset" ? 0 : 1;
  };
  if (directory === undefined) {
    return reply({
      status: "failed",
      message: "the config does not load; fix it in Configuration",
    });
  }
  if (action === "show") {
    process.stdout.write(`${JSON.stringify(showTemplates(directory))}\n`);
    return 0;
  }
  const text = await readLimitedStdin(MAX_REQUEST_BYTES);
  const request = text === undefined ? undefined : parseTemplateRequest(text);
  if (request === undefined) return reply({ status: "bad-request", message: "malformed request" });
  return reply(saveTemplate(directory, request));
}

async function main(argv: readonly string[]): Promise<number> {
  const command = argv[0];
  if (
    command === "templates" &&
    (argv[1] === "show" || argv[1] === "set") &&
    argv.includes("--json")
  ) {
    return templatesCommand(argv[1]);
  }
  if (command === "config") {
    if (argv[1] === "show" && argv.includes("--json")) {
      process.stdout.write(`${JSON.stringify(showConfig(defaultConfigPath()))}\n`);
      return 0;
    }
    if (argv[1] === "set" && argv.includes("--json")) return setConfig();
    process.stderr.write(USAGE);
    return 2;
  }
  if (command === "reviews" && argv.includes("--json")) return reviewsJson();
  if (command === "review" && argv.includes("--json")) return reviewCommand(argv);
  if (command === "mr" && argv[1] === "approve" && argv.includes("--json")) {
    const [key, sha] = [argv[2], argv[3]];
    if (key === undefined || sha === undefined) {
      process.stderr.write(USAGE);
      return 2;
    }
    return approveCommand(key, sha);
  }
  if (command === "mr" && argv[1] === "comment" && argv.includes("--json")) {
    const key = argv[2];
    if (key === undefined) {
      process.stderr.write(USAGE);
      return 2;
    }
    return commentCommand(key);
  }
  if (command === "mr" && argv[1] === "merge" && argv.includes("--json")) {
    const [key, sha] = [argv[2], argv[3]];
    if (key === undefined || sha === undefined) {
      process.stderr.write(USAGE);
      return 2;
    }
    return mergeCommand(key, sha, argv);
  }
  if (command === "mr" && argv.includes("--json")) {
    const key = argv[1];
    if (key === undefined || parseMrKey(key) === undefined) {
      process.stderr.write(USAGE);
      return 2;
    }
    return mrJson(key);
  }
  if (command === "agent") {
    if (argv[1] === "restart" && argv.includes("--json")) return restartAgent();
    if (argv[1] === "install") return installAgentCommand();
    if (argv[1] === "uninstall") return uninstallAgentCommand();
    process.stderr.write(USAGE);
    return 2;
  }
  if (command === undefined || (!SIMPLE.has(command) && !WITH_ID.has(command))) {
    process.stderr.write(USAGE);
    return 2;
  }
  if (command === "status" && argv.includes("--json")) return statusJson();
  if (command === "stats") return statsJson();
  if (command === "usage") return usageJson();
  const runtime = createRuntime(defaultConfigPath());
  try {
    return await run(runtime, command, argv);
  } finally {
    runtime.store.close();
  }
}

main(process.argv.slice(2)).then(
  (code) => {
    process.exitCode = code;
  },
  (error: unknown) => {
    process.stderr.write(`suica: ${error instanceof Error ? error.message : "unknown error"}\n`);
    process.exitCode = 1;
  },
);
