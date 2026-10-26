import { homedir } from "node:os";
import { delimiter, dirname, join } from "node:path";
import { installAgent, plistPath, uninstallAgent } from "./agent-install.ts";
import { buildStatus, loadStatusInput, readServiceStatus, restartService } from "./agent-status.ts";
import { actionJson, buildAgentState } from "./agent-state.ts";
import { MODEL_NAME, defaultConfigPath, defaultStatePath, loadConfig } from "./config.ts";
import { applyConfigEdits, parseSaveRequest, showConfig } from "./config-edit.ts";
import type { SaveResultJson } from "./config-edit.ts";
import { defaultExec } from "./exec.ts";
import {
  fetchCurrentUsername,
  fetchSnapshot,
  glabPost,
  glabPostJson,
  glabPut,
  glabRest,
  glabRunner,
} from "./gitlab.ts";
import { checkGitlab } from "./gitlab-check.ts";
import { openLessonsReadOnly } from "./lesson-store.ts";
import { readScopeCache } from "./lessons/hook.ts";
import { applyInstall, applyUninstall, lessonsStatus, planInstall } from "./lessons/install.ts";
import type { LessonsPaths } from "./lessons/install.ts";
import { serveLessons } from "./lessons/mcp-server.ts";
import { scanScopes } from "./lessons/scopes.ts";
import { exportVault } from "./lessons/vault.ts";
import { MODEL_CLI_CHOICES, detectModelClis, resolveModelCli } from "./model-cli.ts";
import { buildReviewOptions, listSkills } from "./review-options.ts";
import { closeMergeRequest, commentOnMergeRequest, mergeMergeRequest } from "./mr-actions.ts";
import {
  approveMergeRequest,
  buildReviewActivity,
  buildReviewList,
  fetchFixDetail,
  fetchMrDetail,
  parseMrKey,
  repeatLookup,
  resolveOwnThreads,
} from "./reviews.ts";
import {
  cancelAgentReview,
  dailyCapReached,
  discardAgentReview,
  postAgentReview,
  rereviewWaitingReasons,
} from "./agent-review.ts";
import { coversHead } from "./agent-rereview.ts";
import { parseTemplateRequest, saveTemplate, showTemplates } from "./template-edit.ts";
import { defaultTemplatesPath } from "./teams/templates.ts";
import type { TemplateSaveJson } from "./template-edit.ts";
import { isWatched, queueManualFix, setWatch } from "./agent-fix.ts";
import { queuePipelineFix } from "./pipeline-watch.ts";
import { fetchHeadPipeline } from "./pipelines.ts";
import {
  buildFixList,
  cancelFix,
  confirmFix,
  discardFix,
  parseConfirmEdits,
  postMissingReplies,
  retryFix,
} from "./fix-confirm.ts";
import { createNotifier } from "./notifier.ts";
import { loadAlerts } from "./alerts.ts";
import { createLogger } from "./log.ts";
import { createRuntime } from "./runtime.ts";
import type { Runtime } from "./runtime.ts";
import { RANKING_WINDOW, buildStats, localDayKey } from "./stats.ts";
import { openStore } from "./store.ts";
import { formatOutbox } from "./teams/format-outbox.ts";
import { OUTBOX_KINDS, OUTBOX_STATUSES, YOUR_MR_KINDS } from "./teams/types.ts";
import type { OutboxKind } from "./teams/types.ts";
import { fetchMessageContext, parseMessageRequest } from "./teams/manual.ts";
import { readChat } from "./office/chat.ts";
import { geminiResumeId, sendToSession } from "./office/send.ts";
import { adaptersFor, collectOffice } from "./office/collect.ts";
import { realProbe } from "./office/probe.ts";
import { buildUsage } from "./usage.ts";

const USAGE =
  "usage: suica <once|status|state|stats|usage|office --json|office chat <agent> <sessionId> --json|office send <agent> <sessionId> --json (message on stdin)|pause|resume|pending [--all]|send <id> [--json]|skip <id> [--json]|retry <id> [--json]|clear <id|yours|others|all> [--json]|selftest|message <key> --json (request on stdin)|reviews --json|mr <key> --json|mr approve <key> <sha> --json|mr comment <key> --json (body on stdin)|mr close <key> --json|mr merge <key> <sha> [--squash] [--remove-source-branch] [--when-pipeline-succeeds] --json (message on stdin)|review options [--cli <id>] --json|review queue <key> [--skill <name>] [--model <name>] [--auto] --json|review post <id> [--inline|--comment] --json|review discard <id> --json|review cancel <id> --json|fix list --json|fix queue <key> [--pipeline] --json|fix watch <key> --json|fix unwatch <key> --json|fix confirm <id> --json (edits on stdin)|fix retry <id> --json (note on stdin)|fix discard <id> --json|fix cancel <id> --json|fix replies <id> --json|config show --json|config set --json|templates show --json|templates set --json|gitlab check <host> --json|lessons mcp|lessons install [--yes] [--json]|lessons uninstall [--json]|lessons status --json|lessons export [--json]|agent install [--json]|agent uninstall|agent restart --json>\n";
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
const WITH_ID = new Set(["send", "skip", "retry", "clear"]);
const DONE_CODES: Readonly<Record<string, string>> = {
  skip: "skipped",
  retry: "retried",
  clear: "cleared",
};
/** `suica clear <group>`: the kinds whose Recent rows it clears. */
const CLEAR_GROUPS: ReadonlyMap<string, readonly OutboxKind[]> = new Map([
  ["yours", YOUR_MR_KINDS],
  ["others", OUTBOX_KINDS.filter((kind) => !YOUR_MR_KINDS.includes(kind))],
  ["all", OUTBOX_KINDS],
]);

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
      const json = argv.includes("--json");
      const kinds = command === "clear" ? CLEAR_GROUPS.get(argv[1] ?? "") : undefined;
      if (kinds !== undefined) {
        const count = teams.clearRecent(kinds);
        process.stdout.write(
          json ? `${actionJson(count > 0 ? "cleared" : "nothing")}\n` : `cleared ${count}\n`,
        );
        return 0;
      }
      const id = parseId(argv[1]);
      if (id === undefined) {
        process.stderr.write(USAGE);
        return 2;
      }
      if (command === "send") {
        const outcome = await teams.sendPending(id);
        process.stdout.write(
          json ? `${actionJson(outcome.status)}\n` : `send #${id}: ${outcome.status}\n`,
        );
        return outcome.status === "sent" ? 0 : 1;
      }
      const done =
        command === "skip"
          ? teams.skip(id)
          : command === "retry"
            ? teams.retry(id)
            : teams.clear(id);
      if (json) {
        const code = done ? (DONE_CODES[command] ?? "done") : "nothing";
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

/** `suica office --json`: the Coding Agents running on this Mac. Reads local files; no runtime. */
function officeJson(): number {
  const config = loadConfig(defaultConfigPath());
  const document = collectOffice(adaptersFor(config.office), realProbe());
  process.stdout.write(`${JSON.stringify(document)}\n`);
  return 0;
}

/** `suica office chat <agent> <sessionId> --json`: one Session's last messages, for the chat panel. */
function officeChatJson(agent: string, sessionId: string): number {
  const document = readChat(realProbe().home, agent, sessionId);
  process.stdout.write(`${JSON.stringify(document)}\n`);
  return 0;
}

/**
 * `suica office send <agent> <sessionId> --json`: the message comes on stdin; runs one headless
 * turn of the agent that resumes the Session and prints `{"status": …}` when it ends.
 */
async function officeSendCommand(agent: string, sessionId: string): Promise<number> {
  const config = loadConfig(defaultConfigPath());
  const body = await readLimitedStdin(MAX_REQUEST_BYTES);
  const probe = realProbe();
  const clis = detectModelClis();
  const outcome =
    body === undefined
      ? "too_long"
      : await sendToSession(
          {
            sessions: () => collectOffice(adaptersFor(config.office), probe).sessions,
            cliPath: (id) => clis.find((cli) => cli.id === id)?.path ?? null,
            geminiResumeId: (id) => geminiResumeId(probe.home, id),
            exec: defaultExec,
          },
          agent,
          sessionId,
          body,
        );
  // The message itself is the Owner's words: it is never logged.
  createLogger().info("office message", { agent, session_id: sessionId, outcome });
  process.stdout.write(`${actionJson(outcome)}\n`);
  return outcome === "sent" ? 0 : 1;
}

/** `suica reviews --json` and `suica mr <key> --json`: no runtime. */
async function reviewsJson(): Promise<number> {
  const config = loadConfig(defaultConfigPath());
  // The list shows no notes, and leaving them out halves GitLab's answer time.
  const snapshot = await fetchSnapshot(glabRunner(config.gitlab), { notes: false });
  const store = openStore(config.statePath ?? defaultStatePath());
  try {
    store.recoverStalePostings(Date.now());
    const choices = store.fixes.watchChoices();
    const document = buildReviewList(
      snapshot,
      store.latestAgentReviews(),
      store.rereviewBases(),
      rereviewWaitingReasons(store, config, snapshot, Date.now()),
      store.fixes.latestByMr(),
      config.review.approveWhen,
      (key) => isWatched(key, choices, config),
      repeatLookup(config.lessons.enabled, store.lessons),
    );
    process.stdout.write(`${JSON.stringify(document)}\n`);
    return 0;
  } finally {
    store.close();
  }
}

/** The argument after `flag`; undefined when the flag is not given, "" when nothing follows it. */
function flagValue(argv: readonly string[], flag: string): string | undefined {
  const at = argv.indexOf(flag);
  return at === -1 ? undefined : (argv[at + 1] ?? "");
}

/**
 * `suica review options [--cli <id>]`: the skills and models a review can use, for the CLI that
 * reviews or the one named; see contracts/review-options.v1.json.
 */
function reviewOptions(argv: readonly string[]): number {
  const config = loadConfig(defaultConfigPath());
  const named = flagValue(argv, "--cli");
  const choice = MODEL_CLI_CHOICES.find((id) => id === named) ?? config.model.cli;
  const cli = resolveModelCli(choice, detectModelClis());
  process.stdout.write(`${JSON.stringify(buildReviewOptions(config.review, cli))}\n`);
  return 0;
}

/**
 * `suica review queue|post|discard|cancel`: the background agent starts a queued review within a few
 * seconds; post and discard act on a review that waits for the Owner, and cancel stops a queued or
 * running one. `queue` takes `--skill` (an installed skill) and `--model` for that review only,
 * and `--auto` to queue an automatic re-review: `covered` when the agent already queued the MR's
 * head or a review covers it, `daily-cap` once `review.maxPerDay` is used.
 * `post` takes `--inline` or `--comment`, else `review.postAs`. Each prints `{"status": …}`.
 */
async function reviewCommand(argv: readonly string[]): Promise<number> {
  const [action, target] = [argv[1], argv[2]];
  if (action === "options") return reviewOptions(argv);
  const config = loadConfig(defaultConfigPath());
  const store = openStore(config.statePath ?? defaultStatePath());
  const reply = (status: string, ok: boolean): number => {
    process.stdout.write(`${actionJson(status)}\n`);
    return ok ? 0 : 1;
  };
  try {
    if (action === "queue") {
      if (target === undefined || parseMrKey(target) === undefined) return reply("bad-key", false);
      const skill = flagValue(argv, "--skill");
      const model = flagValue(argv, "--model");
      const installed = listSkills(config.review.skill).filter((item) => !item.missing);
      if (skill !== undefined && !installed.some((item) => item.name === skill)) {
        return reply("bad-skill", false);
      }
      if (model !== undefined && !MODEL_NAME.test(model)) return reply("bad-model", false);
      const choice =
        skill === undefined && model === undefined
          ? undefined
          : {
              ...(skill === undefined ? {} : { skill }),
              ...(model === undefined ? {} : { model }),
            };
      // The app queues the re-reviews that wait for a push to settle as automatic ones, in the cap.
      // Its list can be a poll behind: a head the agent queued itself, or that a review already
      // covers, is left alone (`covered`), so one push is never reviewed twice.
      const auto = argv.includes("--auto");
      if (auto) {
        const tracked = store.loadReviewHeads().get(target);
        const latest = store.latestAgentReviews().get(target);
        if (
          tracked === undefined ||
          tracked.queuedHead === tracked.head ||
          coversHead(latest, tracked.head)
        ) {
          return reply("covered", true);
        }
        if (dailyCapReached(store, config, Date.now())) return reply("daily-cap", false);
      }
      const id = store.queueAgentReview(
        target,
        auto ? "auto" : "manual",
        Date.now(),
        undefined,
        choice,
      );
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

/** Finished fixes stay in `suica fix list` this long; open ones always do. */
const FIX_LIST_DAYS_MS = 7 * 86_400_000;

/**
 * `suica fix list|queue|watch|unwatch|confirm|retry|discard|cancel|replies`: the background agent
 * runs a queued fix within a few seconds; confirm commits, pushes and replies as the Owner.
 * `queue --pipeline` queues a fix of the MR's failed head pipeline instead of its threads; `watch`
 * and `unwatch` choose whether automatic fixes reach the MR. Each action prints
 * `{"status": …}`.
 */
async function fixCommand(argv: readonly string[]): Promise<number> {
  const [action, target] = [argv[1], argv[2]];
  const config = loadConfig(defaultConfigPath());
  const statePath = config.statePath ?? defaultStatePath();
  const store = openStore(statePath);
  const log = createLogger();
  const reply = (status: string, ok: boolean): number => {
    process.stdout.write(`${actionJson(status)}\n`);
    return ok ? 0 : 1;
  };
  try {
    if (action === "list") {
      process.stdout.write(
        `${JSON.stringify(
          buildFixList(
            store.fixes.list(Date.now() - FIX_LIST_DAYS_MS),
            repeatLookup(config.lessons.enabled, store.lessons),
          ),
        )}\n`,
      );
      return 0;
    }
    if (action === "watch" || action === "unwatch") {
      const outcome = setWatch({ store, log, now: Date.now }, target ?? "", action === "watch");
      return reply(outcome, outcome !== "bad-key");
    }
    const graphql = glabRunner(config.gitlab);
    const rest = glabRest(config.gitlab);
    // A fix only ever changes an MR the signed-in GitLab user wrote.
    const owner = (): Promise<string> => fetchCurrentUsername(rest);
    if (action === "queue" && argv.includes("--pipeline")) {
      if (target === undefined || parseMrKey(target) === undefined) return reply("bad-key", false);
      const outcome = await queuePipelineFix(
        { store, log, now: Date.now, head: (key) => fetchHeadPipeline(graphql, key) },
        target,
        await owner(),
      );
      return reply(outcome, outcome === "queued" || outcome === "added");
    }
    if (action === "queue") {
      if (target === undefined || parseMrKey(target) === undefined) return reply("bad-key", false);
      const outcome = await queueManualFix(
        { store, log, now: Date.now, detail: (key) => fetchFixDetail(graphql, rest, key) },
        target,
        await owner(),
      );
      return reply(outcome, outcome === "queued" || outcome === "added");
    }
    const id = parseId(target);
    if (
      id === undefined ||
      !["confirm", "retry", "discard", "cancel", "replies"].includes(action ?? "")
    ) {
      process.stderr.write(USAGE);
      return 2;
    }
    const deps = {
      store,
      config,
      exec: defaultExec,
      graphql,
      rest,
      post: glabPost(config.gitlab),
      notifier: createNotifier(),
      alerts: loadAlerts(config.teams.templatesPath ?? defaultTemplatesPath()),
      log,
      now: Date.now,
      statePath,
      owner,
    };
    switch (action) {
      case "confirm": {
        const text = await readLimitedStdin(MAX_REQUEST_BYTES);
        const edits = text === undefined ? undefined : parseConfirmEdits(text);
        if (edits === undefined) return reply("bad-request", false);
        const outcome = await confirmFix(deps, id, edits);
        return reply(outcome, outcome === "pushed" || outcome === "partial");
      }
      case "retry": {
        const note = (await readLimitedStdin(MAX_REQUEST_BYTES)) ?? "";
        const outcome = retryFix(deps, id, note);
        return reply(outcome.status, outcome.status === "queued");
      }
      case "discard": {
        const done = discardFix(deps, id);
        return reply(done ? "discarded" : "nothing", done);
      }
      case "cancel": {
        const done = cancelFix(store, id, Date.now());
        return reply(done ? "cancelled" : "nothing", done);
      }
      default: {
        const outcome = await postMissingReplies(deps, id);
        return reply(outcome, outcome !== "nothing");
      }
    }
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
 * `suica message <key> --json`: a Teams message from an MR's page to its Author or a Reviewer.
 * With `send: false` it prints the template's text (`{"status": "draft", "text": …}`); with
 * `send: true` it sends the text given, else the template's, and prints how that went.
 */
async function messageCommand(key: string): Promise<number> {
  const reply = (body: Record<string, string>, ok: boolean): number => {
    process.stdout.write(`${JSON.stringify(body)}\n`);
    return ok ? 0 : 1;
  };
  const raw = await readLimitedStdin(MAX_REQUEST_BYTES);
  const request = raw === undefined ? undefined : parseMessageRequest(raw);
  if (request === undefined || parseMrKey(key) === undefined) {
    return reply({ status: "bad-request" }, false);
  }
  const runtime = createRuntime(defaultConfigPath());
  try {
    const { teams } = runtime;
    if (teams === undefined) return reply({ status: "teams-off" }, false);
    const context = await fetchMessageContext(
      glabRunner(runtime.config.gitlab),
      key,
      request,
      Date.now(),
    );
    if (context === undefined) return reply({ status: "bad-recipient" }, false);
    const text = request.text ?? teams.draft(context.intent, context.owner.name);
    if (!request.send) return reply({ status: "draft", text }, true);
    const outcome = await teams.sendManual(context.intent, text);
    return reply({ status: outcome.status }, outcome.status === "sent");
  } catch (error) {
    return reply(
      { status: "failed", message: error instanceof Error ? error.message : "unknown error" },
      false,
    );
  } finally {
    runtime.store.close();
  }
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

/** `suica mr close <key> --json`: closes an MR you wrote, without merging; prints `{"status": …}`. */
async function closeCommand(key: string): Promise<number> {
  const { gitlab } = loadConfig(defaultConfigPath());
  let outcome: string;
  if (parseMrKey(key) === undefined) {
    outcome = "bad-key";
  } else {
    const detail = await fetchMrDetail(glabRunner(gitlab), glabRest(gitlab), key);
    const me = await fetchCurrentUsername(glabRest(gitlab));
    outcome = await closeMergeRequest(glabPut(gitlab), key, detail.author.username, me);
  }
  createLogger().info("mr close", { mr_key: key, outcome });
  process.stdout.write(`${actionJson(outcome)}\n`);
  return outcome === "closed" ? 0 : 1;
}

/** With `json`, prints `{"status": "installed" | "no-config" | "failed"}` for the app. */
async function installAgentCommand(json: boolean): Promise<number> {
  const paths = {
    node: process.execPath,
    main: join(import.meta.dirname, "main.ts"),
    home: homedir(),
  };
  const configPath = defaultConfigPath();
  const outcome = await installAgent(defaultExec, process.getuid?.() ?? 0, paths, configPath);
  if (json) {
    process.stdout.write(`${actionJson(outcome)}\n`);
    return outcome === "installed" ? 0 : 1;
  }
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

/** `suica lessons mcp`: the lessons MCP server on stdio until stdin closes; stdout is JSON-RPC only. */
async function lessonsMcp(): Promise<number> {
  const path = defaultConfigPath();
  await serveLessons(process.stdin, process.stdout, {
    config: () => loadConfig(path).lessons,
    openReader: () => openLessonsReadOnly(loadConfig(path).statePath ?? defaultStatePath()),
    scan: () => {
      const config = loadConfig(path);
      const statePath = config.statePath ?? defaultStatePath();
      const { scopes } = config.lessons;
      // The daemon normally provides the cache after each scan; without it the folders are walked.
      return (
        readScopeCache(join(dirname(statePath), "lesson-scopes.json"), scopes) ??
        scanScopes(scopes, config.gitlab.hostname)
      );
    },
    now: () => Date.now(),
  });
  return 0;
}

/** `suica lessons export`: writes the vault now; exits 1 when there is nowhere or nothing to write from. */
function exportLessonsCommand(json: boolean): number {
  const config = loadConfig(defaultConfigPath());
  const { enabled, scopes, vaultPath } = config.lessons;
  const say = (result: Record<string, unknown>, line: string, code: number): number => {
    process.stdout.write(json ? `${JSON.stringify({ version: 1, ...result })}\n` : `${line}\n`);
    return code;
  };
  if (!enabled) return say({ status: "disabled" }, "lessons are off", 0);
  if (vaultPath === undefined) {
    return say({ status: "no-vault-path" }, "set lessons.vaultPath to export", 1);
  }
  const reader = openLessonsReadOnly(config.statePath ?? defaultStatePath());
  if (reader === undefined) return say({ status: "no-lessons" }, "no lessons stored yet", 1);
  try {
    const { written, removed, conflicts } = exportVault(reader, scopes, vaultPath, Date.now());
    return say(
      { status: "exported", written, removed, conflicts, path: vaultPath },
      `exported to ${vaultPath}: ${String(written)} written, ${String(removed)} removed` +
        (conflicts > 0 ? `, ${String(conflicts)} left alone (not written by Suica)` : ""),
      0,
    );
  } catch (error) {
    const message = error instanceof Error ? error.message : "export failed";
    return say({ status: "failed", message }, `export failed: ${message}`, 1);
  } finally {
    reader.close();
  }
}

function lessonsPaths(): LessonsPaths {
  return {
    node: process.execPath,
    cli: join(import.meta.dirname, "cli.ts"),
    hook: join(import.meta.dirname, "lessons-hook.ts"),
  };
}

/** The folders searched for claude and codex; SUICA_CLI_DIRS replaces them (tests, odd installs). */
function lessonsClis() {
  const override = process.env["SUICA_CLI_DIRS"];
  const dirs = override?.split(delimiter).filter((dir) => dir !== "");
  return detectModelClis(dirs);
}

/** `suica lessons install`: without `--yes` only prints the plan and exits 1. */
async function installLessonsCommand(yes: boolean, json: boolean): Promise<number> {
  const home = homedir();
  const paths = lessonsPaths();
  const clis = lessonsClis();
  const plan = planInstall(home, clis, paths);
  if (!yes) {
    if (json) {
      process.stdout.write(
        `${JSON.stringify({ version: 1, status: "needs-confirmation", plan })}\n`,
      );
    } else {
      const lines = [
        `would edit ${plan.settingsPath}, adding these hooks (command: ${plan.command}):`,
        ...plan.hooks.map(
          (hook) => `  ${hook.event}${hook.matcher === "" ? "" : ` (${hook.matcher})`}`,
        ),
        ...plan.commands.map((line) => `would run: ${line}`),
        plan.note,
        "run again with --yes to apply",
      ];
      process.stdout.write(`${lines.join("\n")}\n`);
    }
    return 1;
  }
  const result = await applyInstall(home, defaultExec, clis, paths);
  if (json) {
    process.stdout.write(`${JSON.stringify({ version: 1, ...result })}\n`);
  } else if (result.status === "invalid-settings" || result.status === "unreadable-settings") {
    process.stderr.write(
      `${result.settingsPath} cannot be used (${result.status}); left unchanged\n`,
    );
  } else {
    process.stdout.write(
      `hooks ${result.changed ? "installed in" : "already in"} ${result.settingsPath}; registered: ${result.registered.join(", ") || "none"}; skipped: ${result.skipped.join(", ") || "none"}${result.failed.length > 0 ? `; failed: ${result.failed.join(", ")}` : ""}\n`,
    );
  }
  return result.status === "installed" ? 0 : 1;
}

async function uninstallLessonsCommand(json: boolean): Promise<number> {
  const result = await applyUninstall(homedir(), defaultExec, lessonsClis(), lessonsPaths());
  if (json) process.stdout.write(`${JSON.stringify({ version: 1, ...result })}\n`);
  else if (result.status === "invalid-settings" || result.status === "unreadable-settings")
    process.stderr.write(`settings.json cannot be used (${result.status}); left unchanged\n`);
  else
    process.stdout.write(
      `removed the hooks: ${result.hookRemoved}; unregistered: ${result.removed.join(", ") || "none"}${result.failed.length > 0 ? `; failed: ${result.failed.join(", ")}` : ""}\n`,
    );
  return result.status === "uninstalled" ? 0 : 1;
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
  if (command === "office" && argv[1] === "chat" && argv.includes("--json")) {
    const [agent, sessionId] = argv.slice(2).filter((arg) => !arg.startsWith("--"));
    if (agent === undefined || sessionId === undefined) {
      process.stderr.write(USAGE);
      return 2;
    }
    return officeChatJson(agent, sessionId);
  }
  if (command === "office" && argv[1] === "send" && argv.includes("--json")) {
    const [agent, sessionId] = argv.slice(2).filter((arg) => !arg.startsWith("--"));
    if (agent === undefined || sessionId === undefined) {
      process.stderr.write(USAGE);
      return 2;
    }
    return officeSendCommand(agent, sessionId);
  }
  if (command === "office" && argv.includes("--json")) return officeJson();
  if (command === "message" && argv.includes("--json")) {
    const key = argv[1];
    if (key === undefined) {
      process.stderr.write(USAGE);
      return 2;
    }
    return messageCommand(key);
  }
  if (command === "reviews" && argv.includes("--json")) return reviewsJson();
  if (command === "review" && argv.includes("--json")) return reviewCommand(argv);
  if (command === "fix" && argv.includes("--json")) return fixCommand(argv);
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
  if (command === "mr" && argv[1] === "close" && argv.includes("--json")) {
    const key = argv[2];
    if (key === undefined) {
      process.stderr.write(USAGE);
      return 2;
    }
    return closeCommand(key);
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
  if (command === "gitlab" && argv[1] === "check" && argv.includes("--json")) {
    const host = argv.slice(2).find((arg) => !arg.startsWith("--")) ?? "";
    const result = await checkGitlab(host, defaultExec);
    process.stdout.write(`${JSON.stringify(result)}\n`);
    return result.status === "ok" ? 0 : 1;
  }
  if (command === "lessons") {
    if (argv[1] === "mcp" && argv.length === 2) return lessonsMcp();
    const flags = argv.slice(2);
    const json = flags.includes("--json");
    const known = (allowed: readonly string[]) => flags.every((flag) => allowed.includes(flag));
    if (argv[1] === "install" && known(["--yes", "--json"])) {
      return installLessonsCommand(flags.includes("--yes"), json);
    }
    if (argv[1] === "export" && known(["--json"])) return exportLessonsCommand(json);
    if (argv[1] === "uninstall" && known(["--json"])) return uninstallLessonsCommand(json);
    if (argv[1] === "status" && json && flags.length === 1) {
      const status = await lessonsStatus(homedir(), defaultExec, lessonsClis(), lessonsPaths());
      process.stdout.write(`${JSON.stringify({ version: 1, ...status })}\n`);
      return 0;
    }
    process.stderr.write(USAGE);
    return 2;
  }
  if (command === "agent") {
    if (argv[1] === "restart" && argv.includes("--json")) return restartAgent();
    if (argv[1] === "install") return installAgentCommand(argv.includes("--json"));
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
