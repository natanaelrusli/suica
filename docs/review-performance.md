# Review performance measurement

Run the reproducible synthetic benchmark from the repository root on Node.js 24 or newer:

```sh
node scripts/measure-review-performance.ts --runs 20 --concurrency 2 --model-delay-ms 20
```

The command writes one JSON artifact to stdout. Save it with shell redirection if you need to retain a result. `--runs` accepts 1–100 (default 20), `--concurrency` accepts 1–20 (default 2), and `--model-delay-ms` accepts 0–5000 (default 20). The sequential case always sets worker concurrency to one; the batch queues exactly the configured concurrency count. The harness uses a real in-memory Store and the production `createReviewWorker`/`runAgentReview` path. Fake REST, GraphQL, Exec, and notifier dependencies supply a collected immutable diff version and source project metadata. Git commands are stubbed, model calls return deterministic Claude JSON after the configured fixed delay, and no network, model executable, or live write is used.

The fixture has one changed file, a 37-byte diff, and a 31-byte description. JSON includes actual wall-clock durations, worker `queue_wait_ms` records, and input/checkout/model/judge/posting/cleanup stage distributions where those stages run. Each distribution reports p50, p95, max, and sample count. Event-loop delay is measured with `node:perf_hooks.monitorEventLoopDelay` at 10ms resolution. Runtime metadata includes Node version, platform, architecture, CPU count, and configured fixture/concurrency values. `review.approveBy` follows the repository's default configuration, so judge timing is included when enabled by that configuration; posting and cleanup are recorded only when their production paths run.

## Before/after comparison

To compare revisions, use two clean worktrees at the same machine/runtime and run this exact command in each. Do not switch or modify the current checkout automatically:

```sh
git worktree add /tmp/suica-review-before <before-revision>
git worktree add /tmp/suica-review-after <after-revision>
(cd /tmp/suica-review-before && node scripts/measure-review-performance.ts --runs 20 --concurrency 2 --model-delay-ms 20) > /tmp/review-before.json
(cd /tmp/suica-review-after && node scripts/measure-review-performance.ts --runs 20 --concurrency 2 --model-delay-ms 20) > /tmp/review-after.json
```

Run both on an otherwise idle machine. Compare the JSON fields directly; fixture configuration and runtime metadata should match. Remove only those two temporary worktrees after retaining any artifacts you need.

No before/after performance claim is made here. These synthetic results do not measure GitLab latency, real clone cost, model quality, production workload, or network variance. Fixed fake model latency makes the worker's orchestration measurable and repeatable, not representative of end-to-end production speed. Consider checkout caching only as a separate change if real measurements show checkout dominates.
