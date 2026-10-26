import { describe, expect, it } from "vitest";
import { runDaemon } from "../src/daemon.ts";
import { createLogger } from "../src/log.ts";
import type { PollStatus } from "../src/poller.ts";

const polling = {
  activeSeconds: 120,
  idleSeconds: 300,
  idleAfterSeconds: 300,
  maxBackoffSeconds: 900,
};
const log = createLogger({ write: () => undefined });

async function run(options: {
  statuses: (PollStatus | "crash")[];
  idleSeconds?: number;
  logs?: string[];
}): Promise<number[]> {
  const controller = new AbortController();
  const delays: number[] = [];
  let polls = 0;
  await runDaemon({
    poll: () => {
      const status = options.statuses[polls] ?? "ok";
      polls += 1;
      return status === "crash" ? Promise.reject(new Error("bug")) : Promise.resolve(status);
    },
    readIdleSeconds: () => Promise.resolve(options.idleSeconds ?? 0),
    polling,
    sleep: (ms) => {
      delays.push(ms / 1000);
      if (delays.length === options.statuses.length) controller.abort();
      return Promise.resolve();
    },
    log:
      options.logs === undefined
        ? log
        : createLogger({ write: (line) => options.logs?.push(line), minLevel: "info" }),
    signal: controller.signal,
  });
  return delays;
}

describe("runDaemon", () => {
  it("backs off while polls fail and recovers after a success", async () => {
    expect(await run({ statuses: ["ok", "failed", "failed", "ok"] })).toEqual([120, 240, 480, 120]);
  });

  it("polls less often while the Mac is idle", async () => {
    expect(await run({ statuses: ["ok"], idleSeconds: 600 })).toEqual([300]);
  });

  it("treats a crashing poll as a failure instead of dying", async () => {
    expect(await run({ statuses: ["crash", "ok"] })).toEqual([240, 120]);
  });

  it("logs when polling is paused and resumed, once per change", async () => {
    const logs: string[] = [];
    await run({ statuses: ["ok", "paused", "paused", "failed", "ok", "paused"], logs });
    expect(logs.map((line) => (JSON.parse(line) as { message: string }).message)).toEqual([
      "polling paused",
      "polling resumed",
      "polling paused",
    ]);
  });

  it("starts the work beside the loop after every poll, failed ones too", async () => {
    const controller = new AbortController();
    const order: string[] = [];
    await runDaemon({
      poll: () => {
        order.push("poll");
        return Promise.resolve(order.length > 1 ? "ok" : "failed");
      },
      afterPoll: () => order.push("after"),
      readIdleSeconds: () => Promise.resolve(0),
      polling,
      sleep: () => {
        if (order.length >= 4) controller.abort();
        return Promise.resolve();
      },
      log,
      signal: controller.signal,
    });
    expect(order).toEqual(["poll", "after", "poll", "after"]);
  });
});
