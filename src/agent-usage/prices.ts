/** Token counts for one model, split by the rate each is billed at. */
export interface TokenCounts {
  readonly input: number;
  readonly output: number;
  readonly cacheRead: number;
  readonly cacheWrite5m: number;
  readonly cacheWrite1h: number;
}

/** USD per 1M tokens. `prefix` matches the start of a model id. */
export interface ModelPrice {
  readonly prefix: string;
  readonly input: number;
  readonly output: number;
  readonly cacheRead: number;
  readonly cacheWrite5m: number;
  readonly cacheWrite1h: number;
  /** Rates for a request whose prompt is over `above` tokens. */
  readonly long?: {
    readonly above: number;
    readonly price: Omit<ModelPrice, "prefix" | "long">;
  };
}

/** Day the prices below were read from the official pages. */
export const PRICES_AS_OF = "2026-11-04";

/** Default long-context threshold; a price's own `long.above` is the one that applies. */
export const LONG_CONTEXT_TOKENS = 200_000;

// Claude: https://platform.claude.com/docs/en/about-claude/pricing
// OpenAI: https://developers.openai.com/api/docs/pricing (Standard tier; 30m write -> cacheWrite5m, 12h write -> cacheWrite1h)
export const PRICES: readonly ModelPrice[] = [
  { prefix: "claude-fable-5-1", input: 10, output: 50, cacheRead: 0.25, cacheWrite5m: 12.5, cacheWrite1h: 20 },
  { prefix: "claude-opus-5-5", input: 4, output: 20, cacheRead: 0.2, cacheWrite5m: 5, cacheWrite1h: 8 },
  { prefix: "claude-opus-5", input: 5, output: 25, cacheRead: 0.5, cacheWrite5m: 6.25, cacheWrite1h: 10 },
  { prefix: "claude-opus-4-8", input: 5, output: 25, cacheRead: 0.5, cacheWrite5m: 6.25, cacheWrite1h: 10 },
  { prefix: "claude-sonnet-5-5", input: 2, output: 10, cacheRead: 0.1, cacheWrite5m: 2.5, cacheWrite1h: 4 },
  {
    prefix: "claude-haiku-5-5",
    input: 0.1,
    output: 0.5,
    cacheRead: 0.01,
    cacheWrite5m: 0.125,
    cacheWrite1h: 0.2,
    long: { above: 100_000, price: { input: 0.5, output: 2.5, cacheRead: 0.05, cacheWrite5m: 0.625, cacheWrite1h: 1 } },
  },
  { prefix: "claude-haiku-4-5", input: 1, output: 5, cacheRead: 0.1, cacheWrite5m: 1.25, cacheWrite1h: 2 },
  {
    prefix: "gpt-6-luna",
    input: 0.1,
    output: 0.5,
    cacheRead: 0.01,
    cacheWrite5m: 0.125,
    cacheWrite1h: 0.25,
    long: { above: 272_000, price: { input: 0.2, output: 0.75, cacheRead: 0.02, cacheWrite5m: 0.25, cacheWrite1h: 0.5 } },
  },
  {
    prefix: "gpt-6.1-sol",
    input: 2,
    output: 10,
    cacheRead: 0.1,
    cacheWrite5m: 2.5,
    cacheWrite1h: 5,
    long: { above: 272_000, price: { input: 4, output: 15, cacheRead: 0.2, cacheWrite5m: 5, cacheWrite1h: 10 } },
  },
];

/** The entry with the longest prefix of `model`, or undefined when it has no public price. */
export function priceOf(model: string): ModelPrice | undefined {
  let best: ModelPrice | undefined;
  for (const p of PRICES) {
    if (model.startsWith(p.prefix) && (!best || p.prefix.length > best.prefix.length)) best = p;
  }
  return best;
}

/** USD for `counts`. `long` picks the long-context rates when the price has them. */
export function costUsd(price: ModelPrice, counts: TokenCounts, long: boolean): number {
  const r = long && price.long ? price.long.price : price;
  return (
    (counts.input * r.input +
      counts.output * r.output +
      counts.cacheRead * r.cacheRead +
      counts.cacheWrite5m * r.cacheWrite5m +
      counts.cacheWrite1h * r.cacheWrite1h) /
    1e6
  );
}
