import { defaultConfigPath } from "./config.ts";
import { createRuntime } from "./runtime.ts";
import type { Runtime } from "./runtime.ts";
import { formatOutbox } from "./teams/format-outbox.ts";
import { OUTBOX_STATUSES } from "./teams/types.ts";

const USAGE =
  "usage: mra <once|status|pause|resume|pending [--all]|send <id>|skip <id>|retry <id>|selftest>\n";
const TEAMS_DISABLED = "teams is disabled: set teams.enabled to true in the config\n";
const SHOWN_WITH_ALL = 50;

const SIMPLE = new Set(["once", "status", "pause", "resume", "selftest", "pending"]);
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
      if (command === "send") {
        const outcome = await teams.sendPending(id);
        process.stdout.write(`send #${id}: ${outcome.status}\n`);
        return outcome.status === "sent" ? 0 : 1;
      }
      const done = command === "skip" ? teams.skip(id) : teams.retry(id);
      process.stdout.write(`${command} #${id}: ${done ? "done" : "nothing to do"}\n`);
      return done ? 0 : 1;
    }
  }
}

async function main(argv: readonly string[]): Promise<number> {
  const command = argv[0];
  if (command === undefined || (!SIMPLE.has(command) && !WITH_ID.has(command))) {
    process.stderr.write(USAGE);
    return 2;
  }
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
    process.stderr.write(`mra: ${error instanceof Error ? error.message : "unknown error"}\n`);
    process.exitCode = 1;
  },
);
