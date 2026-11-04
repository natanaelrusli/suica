import { describe, expect, it } from "vitest";
import {
  costUsd,
  PRICES,
  priceOf,
  type ModelPrice,
  type TokenCounts,
} from "../src/agent-usage/prices.ts";

const none: TokenCounts = { input: 0, output: 0, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0 };
const M = 1e6;
const base: ModelPrice = {
  prefix: "x",
  input: 1,
  output: 2,
  cacheRead: 3,
  cacheWrite5m: 4,
  cacheWrite1h: 5,
};
const withLong: ModelPrice = {
  ...base,
  long: {
    above: 100,
    price: { input: 10, output: 20, cacheRead: 30, cacheWrite5m: 40, cacheWrite1h: 50 },
  },
};

describe("priceOf", () => {
  it("matches a dated model id to its entry", () => {
    expect(priceOf("claude-opus-5-5-20261001")?.prefix).toBe("claude-opus-5-5");
  });
  it("prefers the longest matching prefix", () => {
    expect(priceOf("claude-opus-5-20260101")?.prefix).toBe("claude-opus-5");
    expect(priceOf("claude-opus-5-5")?.prefix).toBe("claude-opus-5-5");
  });
  it("returns undefined for a model with no public price", () => {
    expect(priceOf("codex-auto-review")).toBeUndefined();
    expect(priceOf("<synthetic>")).toBeUndefined();
  });
  it("has no duplicate prefixes", () => {
    expect(new Set(PRICES.map((p) => p.prefix)).size).toBe(PRICES.length);
  });
});

describe("costUsd", () => {
  it("maps each count to its own rate", () => {
    expect(costUsd(base, { ...none, input: M }, false)).toBe(1);
    expect(costUsd(base, { ...none, output: M }, false)).toBe(2);
    expect(costUsd(base, { ...none, cacheRead: M }, false)).toBe(3);
    expect(costUsd(base, { ...none, cacheWrite5m: M }, false)).toBe(4);
    expect(costUsd(base, { ...none, cacheWrite1h: M }, false)).toBe(5);
  });
  it("sums all counts", () => {
    expect(
      costUsd(base, { input: M, output: M, cacheRead: M, cacheWrite5m: M, cacheWrite1h: M }, false),
    ).toBe(15);
  });
  it("uses the long rates when long and the price has them", () => {
    expect(costUsd(withLong, { ...none, input: M }, true)).toBe(10);
    expect(costUsd(withLong, { ...none, cacheWrite1h: M }, true)).toBe(50);
    expect(costUsd(withLong, { ...none, input: M }, false)).toBe(1);
  });
  it("uses the base rates when long but the price has no long rates", () => {
    expect(costUsd(base, { ...none, output: M }, true)).toBe(2);
  });
});
