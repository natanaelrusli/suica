import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import type { Bucket } from "../src/agent-usage/bucket.ts";
import { buildAgentUsage } from "../src/agent-usage/document.ts";
import type { RateJson } from "../src/agent-usage/rate.ts";

const NOW = Date.UTC(2026, 9, 16, 12);
const H = 3_600_000;
const D = 24 * H;
const utcDay = (ms: number): string => new Date(ms).toISOString().slice(0, 10);
const RATE: RateJson = { currency: "IDR", perUsd: 16000, date: "2026-10-15", stale: false };

function bucket(
  hour: number,
  agent: Bucket["agent"],
  model: string,
  counts: Partial<Pick<Bucket, "input" | "output" | "cacheRead" | "cacheWrite5m" | "cacheWrite1h">>,
  long = false,
): Bucket {
  return {
    hour,
    agent,
    model,
    long,
    input: 0,
    output: 0,
    cacheRead: 0,
    cacheWrite5m: 0,
    cacheWrite1h: 0,
    ...counts,
  };
}
const build = (buckets: readonly Bucket[], rate: RateJson | null = RATE) =>
  buildAgentUsage({ buckets, now: NOW, dayKey: utcDay, rate });

const BUCKETS = [
  // priced Claude model: 1M in + 100k out + 2M cache read = 5 + 2.5 + 1 = $8.50
  bucket(NOW - 3 * H, "claude", "claude-opus-4-8", { input: 1e6, output: 1e5, cacheRead: 2e6 }),
  // 25 h old: in 7d, not in 24h; 200k in + 80k 5m write + 40k 1h write = 1 + 0.5 + 0.4 = $1.90
  bucket(NOW - 25 * H, "claude", "claude-opus-4-8", {
    input: 2e5,
    cacheWrite5m: 8e4,
    cacheWrite1h: 4e4,
  }),
  // long-context rates: 400k in + 10k out = 0.5 * 0.4 + 2.5 * 0.01 = $0.225
  bucket(NOW - 2 * H, "claude", "claude-haiku-5-5", { input: 4e5, output: 1e4 }, true),
  // no public price: tokens count, cost does not
  bucket(NOW - 4 * H, "codex", "codex-auto-review", { input: 5e5, output: 5e3 }),
  // 10 days old: in 30d, not in 7d; 1M in = $5
  bucket(NOW - 10 * D, "claude", "claude-opus-4-8", { input: 1e6 }),
  // no tokens: no model row
  bucket(NOW - H, "claude", "<synthetic>", {}),
  // outside the window
  bucket(NOW - 31 * D, "claude", "claude-opus-4-8", { input: 9e6 }),
  bucket(NOW + H, "claude", "claude-opus-4-8", { input: 7e6 }),
];

describe("buildAgentUsage", () => {
  it("matches the golden contract file", () => {
    const golden: unknown = JSON.parse(readFileSync("contracts/agent-usage.v1.json", "utf8"));
    expect(build(BUCKETS)).toEqual(golden);
  });

  it("has every one of the 30 days and averages over calendar days", () => {
    const usage = build(BUCKETS);
    expect(usage.days).toHaveLength(30);
    expect(usage.days[0]?.day).toBe("2026-09-17");
    expect(usage.days[29]?.day).toBe("2026-10-16");
    expect(usage.avgPerDay30d.costUsd).toBe(usage.last30d.costUsd / 30);
    expect(usage.avgPerDay7d.tokens).toBe(usage.last7d.tokens / 7);
  });

  it("counts the unpriced model's tokens but not its cost, and lists it last", () => {
    const usage = build(BUCKETS);
    expect(usage.unpriced).toEqual({ tokens: 505_000, models: ["codex-auto-review"] });
    expect(usage.byModel.map((m) => m.model)).toEqual([
      "claude-opus-4-8",
      "claude-haiku-5-5",
      "codex-auto-review",
    ]);
    expect(usage.byModel.at(-1)?.costUsd).toBeNull();
  });

  it("returns zeros, no models and no rate for no buckets", () => {
    const usage = build([], null);
    expect(usage.last30d).toEqual({ tokens: 0, costUsd: 0 });
    expect(usage.byModel).toEqual([]);
    expect(usage.unpriced).toEqual({ tokens: 0, models: [] });
    expect(usage.rate).toBeNull();
    expect(usage.days).toHaveLength(30);
  });
});
