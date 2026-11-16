#!/usr/bin/env node
import { monitorEventLoopDelay } from "node:perf_hooks";
import { createReviewWorker } from "../src/agent-review.ts";
import { parseConfig } from "../src/config.ts";
import type { Exec } from "../src/exec.ts";
import { createLogger } from "../src/log.ts";
import { openStore } from "../src/store.ts";

const SHA = "0123456789abcdef0123456789abcdef01234567";
const BASE = "fedcba9876543210fedcba9876543210fedcba98";
function args(argv: string[]) {
  const values = { runs: 20, concurrency: 2, modelDelayMs: 20 };
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i];
    const value = Number(argv[i + 1]);
    if (
      !["--runs", "--concurrency", "--model-delay-ms"].includes(key ?? "") ||
      !Number.isInteger(value)
    )
      throw new Error(
        "Usage: node scripts/measure-review-performance.ts [--runs 20] [--concurrency 2] [--model-delay-ms 20]",
      );
    if (key === "--runs") values.runs = value;
    if (key === "--concurrency") values.concurrency = value;
    if (key === "--model-delay-ms") values.modelDelayMs = value;
  }
  if (
    values.runs < 1 ||
    values.runs > 100 ||
    values.concurrency < 1 ||
    values.concurrency > 20 ||
    values.modelDelayMs < 0 ||
    values.modelDelayMs > 5000
  )
    throw new Error("runs 1..100, concurrency 1..20, model delay 0..5000ms");
  return values;
}
const percentile = (values: number[], p: number) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.max(0, Math.ceil(p * sorted.length) - 1)] ?? 0;
};
const stats = (values: number[]) => ({
  p50: percentile(values, 0.5),
  p95: percentile(values, 0.95),
  max: Math.max(0, ...values),
});
const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

async function measure(count: number, config: ReturnType<typeof args>) {
  const store = openStore(":memory:");
  const records: Record<string, unknown>[] = [];
  const log = createLogger({
    minLevel: "info",
    write: (line) => {
      const event = JSON.parse(line) as { message?: string; attributes?: Record<string, unknown> };
      if (event.message === "agent review stage" || event.message === "agent review started")
        records.push(event.attributes ?? {});
    },
  });
  const parsed = parseConfig(
    `gitlab:\n  hostname: gitlab.example\nmodel:\n  cli: claude\nreview:\n  maxChangedLines: 1000\n  concurrency: ${config.concurrency}\n  approve: false\n`,
  );
  const exec: Exec = async (file, commandArgs) => {
    if (file === "git" && commandArgs.includes("clone")) return { stdout: "", stderr: "" };
    if (file === "git") return { stdout: `${SHA}\n`, stderr: "" };
    await sleep(config.modelDelayMs);
    return {
      stdout: JSON.stringify({
        is_error: false,
        result: "# Review\\nNo findings.",
        modelUsage: {},
      }),
      stderr: "",
    };
  };
  const detail = {
    data: {
      project: {
        mergeRequest: {
          title: "Benchmark review",
          description: "Deterministic fixture description",
          webUrl: "https://gitlab.example/g/p/-/merge_requests/1",
          draft: false,
          sourceBranch: "feature/benchmark",
          targetBranch: "main",
          createdAt: "2026-01-01T00:00:00Z",
          updatedAt: "2026-01-01T00:00:00Z",
          author: { username: "fixture", name: "Fixture" },
          labels: { nodes: [] },
          headPipeline: null,
          diffStatsSummary: { additions: 1, deletions: 1 },
          reviewers: { nodes: [] },
          approvedBy: { nodes: [] },
          squashOnMerge: false,
          detailedMergeStatus: null,
          forceRemoveSourceBranch: false,
          diffHeadSha: SHA,
          userPermissions: { canApprove: false },
          discussions: { pageInfo: { hasNextPage: false }, nodes: [] },
        },
      },
    },
  };
  const rest = async (path: string): Promise<unknown> => {
    if (path.endsWith("/diffs?per_page=100"))
      return [
        {
          old_path: "src/fixture.ts",
          new_path: "src/fixture.ts",
          new_file: false,
          renamed_file: false,
          deleted_file: false,
          diff: "@@ -1 +1 @@\n-old\n+new\n",
        },
      ];
    if (path.endsWith("/versions?per_page=100"))
      return [{ id: 1, head_commit_sha: SHA, base_commit_sha: BASE, start_commit_sha: BASE }];
    if (path.endsWith("/versions/1"))
      return {
        diffs: [
          {
            old_path: "src/fixture.ts",
            new_path: "src/fixture.ts",
            diff: "@@ -1 +1 @@\\n-old\\n+new\\n",
          },
        ],
        state: "collected",
        real_size: "1",
        overflow: false,
      };
    if (/\/merge_requests\/\d+$/.test(path)) return { source_project_id: 123 };
    return { ssh_url_to_repo: "ssh://git@gitlab.example/group/project.git" };
  };
  try {
    for (let i = 0; i < count; i++)
      store.queueAgentReview(`group/project!${i + 1}`, "manual", Date.now() - i * 5);
    const deps = {
      store,
      config: parsed,
      exec,
      graphql: async () => detail,
      rest,
      notifier: { notify: async () => undefined },
      log,
      now: Date.now,
      detectClis: () => [{ id: "claude" as const, name: "Claude Code", path: "/fake/claude" }],
    };
    const worker = createReviewWorker(deps);
    const delay = monitorEventLoopDelay({ resolution: 10 });
    delay.enable();
    const started = performance.now();
    worker.tick();
    await worker.idle();
    const wallMs = performance.now() - started;
    delay.disable();
    const byStage = new Map<string, number[]>();
    for (const row of records)
      if (typeof row.stage === "string" && typeof row.duration_ms === "number") {
        byStage.set(row.stage, [...(byStage.get(row.stage) ?? []), row.duration_ms]);
      }
    const queueWait = records
      .filter((row) => typeof row.queue_wait_ms === "number")
      .map((row) => row.queue_wait_ms as number);
    return {
      count,
      wallMs,
      queueWait: stats(queueWait),
      stages: Object.fromEntries(
        [...byStage].map(([name, values]) => [name, { ...stats(values), samples: values.length }]),
      ),
      eventLoopDelayMs: {
        p50: Number(delay.percentile(50)) / 1e6,
        p95: Number(delay.percentile(95)) / 1e6,
        max: Number(delay.max) / 1e6,
      },
    };
  } finally {
    store.close();
  }
}

const options = args(process.argv.slice(2));
const histogram = monitorEventLoopDelay({ resolution: 10 });
histogram.enable();
const sequential = await measure(options.runs, { ...options, concurrency: 1 });
const batch = await measure(options.concurrency, options);
histogram.disable();
console.log(
  JSON.stringify(
    {
      benchmark: "synthetic-agent-review",
      measuredAt: new Date().toISOString(),
      runtime: {
        node: process.version,
        platform: process.platform,
        arch: process.arch,
        cpus: (await import("node:os")).cpus().length,
      },
      configuration: {
        ...options,
        fixtureFiles: 1,
        fixtureDiffBytes: 37,
        fixtureDescriptionBytes: 31,
        immutableVersion: true,
        sourceProjectMetadata: true,
      },
      sequential,
      configuredConcurrencyBatch: batch,
      eventLoopDelayMsOverall: {
        p50: Number(histogram.percentile(50)) / 1e6,
        p95: Number(histogram.percentile(95)) / 1e6,
        max: Number(histogram.max) / 1e6,
      },
      limitations: [
        "Synthetic in-memory store and fake GitLab responses; no GitLab, model service, git network access, or live writes.",
        "Fake model latency is fixed; no model quality, real checkout cost, network variance, or production workload is represented.",
      ],
    },
    null,
    2,
  ),
);
