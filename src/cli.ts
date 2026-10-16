import { homedir } from "node:os";
import { join } from "node:path";
import { buildStatus, loadStatusInput, readServiceStatus, restartService } from "./agent-status.ts";
import { actionJson, buildAgentState } from "./agent-state.ts";
import { defaultConfigPath, defaultStatePath, loadConfig } from "./config.ts";
import { applyConfigEdits, parseSaveRequest, showConfig } from "./config-edit.ts";
import type { SaveResultJson } from "./config-edit.ts";
import { defaultExec } from "./exec.ts";
import { createRuntime } from "./runtime.ts";
import type { Runtime } from "./runtime.ts";
import { buildStats, localDayKey } from "./stats.ts";
import { openStore } from "./store.ts";
import { formatOutbox } from "./teams/format-outbox.ts";
import { OUTBOX_STATUSES } from "./teams/types.ts";

const USAGE =
  "usage: suica <once|status|state|stats|pause|resume|pending [--all]|send <id> [--json]|skip <id> [--json]|retry <id> [--json]|selftest|config show --json|config set --json|agent restart --json>\n";
const TEAMS_DISABLED = "teams is disabled: set teams.enabled to true in the config\n";
const SHOWN_WITH_ALL = 50;

const SIMPLE = new Set([
  "once",
  "status",
  "state",
  "stats",
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
  const document = buildStatus({ service, configPath, logsPath, loaded });
  process.stdout.write(`${JSON.stringify(document)}\n`);
  return 0;
}

/** A turnaround counts when it ended within 30 days, so its start can be up to 60 days back. */
const STATS_HISTORY_MS = 60 * 86_400_000;

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
      history: store.loadHistory(now - STATS_HISTORY_MS),
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

async function main(argv: readonly string[]): Promise<number> {
  const command = argv[0];
  if (command === "config") {
    if (argv[1] === "show" && argv.includes("--json")) {
      process.stdout.write(`${JSON.stringify(showConfig(defaultConfigPath()))}\n`);
      return 0;
    }
    if (argv[1] === "set" && argv.includes("--json")) return setConfig();
    process.stderr.write(USAGE);
    return 2;
  }
  if (command === "agent") {
    if (argv[1] === "restart" && argv.includes("--json")) return restartAgent();
    process.stderr.write(USAGE);
    return 2;
  }
  if (command === undefined || (!SIMPLE.has(command) && !WITH_ID.has(command))) {
    process.stderr.write(USAGE);
    return 2;
  }
  if (command === "status" && argv.includes("--json")) return statusJson();
  if (command === "stats") return statsJson();
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
