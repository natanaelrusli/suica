import type { TokenCounts } from "./prices.ts";

/** Tokens used in one hour by one agent on one model; `long` marks over-threshold prompts. */
export interface Bucket extends TokenCounts {
  readonly hour: number;
  readonly agent: "claude" | "codex";
  readonly model: string;
  readonly long: boolean;
}

/** Adds `b` into `buckets`, summing with any bucket that has the same hour, agent, model and long. */
export function addTo(buckets: Map<string, Bucket>, b: Bucket): void {
  const key = `${b.hour}|${b.agent}|${b.model}|${b.long}`;
  const o = buckets.get(key);
  buckets.set(
    key,
    o
      ? {
          ...b,
          input: o.input + b.input,
          output: o.output + b.output,
          cacheRead: o.cacheRead + b.cacheRead,
          cacheWrite5m: o.cacheWrite5m + b.cacheWrite5m,
          cacheWrite1h: o.cacheWrite1h + b.cacheWrite1h,
        }
      : b,
  );
}
