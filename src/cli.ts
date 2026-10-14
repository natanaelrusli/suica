import { defaultConfigPath } from "./config.ts";
import { createRuntime } from "./runtime.ts";

const USAGE = "usage: mra <once|status|pause|resume>\n";

async function main(argv: readonly string[]): Promise<number> {
  const command = argv[0];
  if (command !== "once" && command !== "status" && command !== "pause" && command !== "resume") {
    process.stderr.write(USAGE);
    return 2;
  }
  const runtime = createRuntime(defaultConfigPath());
  try {
    switch (command) {
      case "once": {
        const status = await runtime.poll();
        process.stdout.write(`poll: ${status}\n`);
        return status === "failed" ? 1 : 0;
      }
      case "status": {
        const state = runtime.store.load();
        process.stdout.write(
          [
            `paused: ${runtime.store.isPaused() ? "yes" : "no"}`,
            `baseline: ${state.baselineDone ? "done" : "pending"}`,
            `tracked authored MRs: ${state.trackedAuthored.size}`,
            `review-requested MRs known: ${state.myReviewStates.size}`,
          ].join("\n") + "\n",
        );
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
