import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import type { StoredTokenUsage } from "../src/store.ts";
import { buildUsage } from "../src/usage.ts";

const NOW = Date.UTC(2026, 9, 16, 12);
const H = 3_600_000;
const D = 24 * H;
const utcDay = (ms: number): string => new Date(ms).toISOString().slice(0, 10);

function run(
  purpose: string,
  at: number,
  inputTokens: number,
  outputTokens: number,
  cacheReadTokens = 0,
  cacheCreationTokens = 0,
): StoredTokenUsage {
  return { at, purpose, inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens };
}
const build = (rows: readonly StoredTokenUsage[], days = 14) =>
  buildUsage({ rows, now: NOW, days, dayKey: utcDay });

describe("buildUsage", () => {
  it("matches the golden contract file", () => {
    const rows = [
      run("other", NOW - 40 * D, 9000, 900),
      run("review", NOW - 10 * D, 100, 10),
      run("review", NOW - 26 * H, 1000, 200, 5000, 300),
      run("review", NOW - 3 * H, 2000, 300, 1000),
      run("reply", NOW - 2 * H, 400, 50),
      run("review", NOW + H, 7000, 700),
    ];
    const golden: unknown = JSON.parse(readFileSync("contracts/usage.v1.json", "utf8"));
    expect(build(rows, 2)).toEqual(golden);
  });

  it("returns zeros, no purposes and every day with no runs", () => {
    const usage = build([], 3);
    expect(usage.last30d).toEqual({
      runs: 0,
      inputTokens: 0,
      outputTokens: 0,
      cacheReadTokens: 0,
      cacheCreationTokens: 0,
    });
    expect(usage.byPurpose).toEqual([]);
    expect(usage.days.map((day) => [day.day, day.runs])).toEqual([
      ["2026-10-14", 0],
      ["2026-10-15", 0],
      ["2026-10-16", 0],
    ]);
  });

  it("orders purposes by all tokens, cache included, then by name", () => {
    const usage = build([
      run("reply", NOW - H, 10, 10),
      run("review", NOW - H, 1, 1, 100),
      run("other", NOW - H, 5, 5),
      run("assist", NOW - H, 5, 5),
    ]);
    expect(usage.byPurpose.map((p) => p.purpose)).toEqual(["review", "reply", "assist", "other"]);
  });
});
