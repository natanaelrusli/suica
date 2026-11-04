import type { Bucket } from "./bucket.ts";
import { PRICES_AS_OF, costUsd, priceOf, type TokenCounts } from "./prices.ts";
import type { RateJson } from "./rate.ts";

/** The document `suica usage agents --json` prints. The app decodes it; see contracts/agent-usage.v1.json. */
export interface CostTotalsJson {
  /** All five counts, priced or not. */
  readonly tokens: number;
  /** USD at API list prices; unpriced models add nothing. The app rounds. */
  readonly costUsd: number;
}

export interface AgentUsageJson {
  readonly version: 1;
  /** Epoch milliseconds. */
  readonly generatedAt: number;
  /** Day the price table was read from the official pages, `YYYY-MM-DD`. */
  readonly pricesAsOf: string;
  readonly last24h: CostTotalsJson;
  readonly last7d: CostTotalsJson;
  readonly last30d: CostTotalsJson;
  /** Window total over 7 or 30 calendar days, so idle days count as zero. */
  readonly avgPerDay7d: CostTotalsJson;
  readonly avgPerDay30d: CostTotalsJson;
  /** The 30 local calendar days, oldest first, every day present. A partial day at the window's start counts in `last30d` but not here. */
  readonly days: readonly (CostTotalsJson & { readonly day: string })[];
  /** Over the last 30 days: priced models by cost, then unpriced ones (`costUsd` null) by tokens. */
  readonly byModel: readonly {
    readonly agent: "claude" | "codex";
    readonly model: string;
    readonly tokens: number;
    readonly costUsd: number | null;
  }[];
  readonly unpriced: { readonly tokens: number; readonly models: readonly string[] };
  /** USD to IDR, or null when no rate was ever fetched. */
  readonly rate: RateJson | null;
}

export interface AgentUsageInput {
  readonly buckets: readonly Bucket[];
  readonly now: number;
  readonly dayKey: (ms: number) => string;
  readonly rate: RateJson | null;
}

const HOUR = 3_600_000;
const DAY = 24 * HOUR;
const DAYS = 30;

const tokensOf = (c: TokenCounts): number =>
  c.input + c.output + c.cacheRead + c.cacheWrite5m + c.cacheWrite1h;

/** USD for one bucket, or null when its model has no public price. */
function priceBucket(b: Bucket): number | null {
  const price = priceOf(b.model);
  return price ? costUsd(price, b, b.long) : null;
}

function sum(buckets: readonly Bucket[]): CostTotalsJson {
  const t = { tokens: 0, costUsd: 0 };
  for (const b of buckets) {
    t.tokens += tokensOf(b);
    t.costUsd += priceBucket(b) ?? 0;
  }
  return t;
}

const average = (t: CostTotalsJson, days: number): CostTotalsJson => ({
  tokens: t.tokens / days,
  costUsd: t.costUsd / days,
});

export function buildAgentUsage(input: AgentUsageInput): AgentUsageJson {
  const { now } = input;
  const month = input.buckets.filter((b) => b.hour <= now && b.hour >= now - DAYS * DAY);
  const since = (ms: number): Bucket[] => month.filter((b) => b.hour >= now - ms);
  const last7d = sum(since(7 * DAY));
  const last30d = sum(month);

  // Step back an hour at a time until 30 distinct days: stepping whole 24 h skips or repeats a day around DST.
  const keys: string[] = [];
  for (let t = now; keys.length < DAYS; t -= HOUR) {
    const day = input.dayKey(t);
    if (!keys.includes(day)) keys.push(day);
  }
  const days = new Map<string, Bucket[]>(keys.reverse().map((day) => [day, []]));
  for (const b of month) days.get(input.dayKey(b.hour))?.push(b);

  // A model with no tokens (e.g. `<synthetic>`) is not worth a row.
  const models = new Map<
    string,
    { agent: Bucket["agent"]; model: string; tokens: number; costUsd: number | null }
  >();
  for (const b of month) {
    const tokens = tokensOf(b);
    if (tokens === 0) continue;
    const key = `${b.agent}|${b.model}`;
    const m = models.get(key) ?? { agent: b.agent, model: b.model, tokens: 0, costUsd: null };
    const cost = priceBucket(b);
    m.tokens += tokens;
    if (cost !== null) m.costUsd = (m.costUsd ?? 0) + cost;
    models.set(key, m);
  }
  const unpriced = [...models.values()].filter((m) => m.costUsd === null);

  return {
    version: 1,
    generatedAt: now,
    pricesAsOf: PRICES_AS_OF,
    last24h: sum(since(DAY)),
    last7d,
    last30d,
    avgPerDay7d: average(last7d, 7),
    avgPerDay30d: average(last30d, DAYS),
    days: [...days].map(([day, buckets]) => ({ day, ...sum(buckets) })),
    byModel: [...models.values()].sort(
      (a, b) =>
        Number(a.costUsd === null) - Number(b.costUsd === null) ||
        (b.costUsd ?? 0) - (a.costUsd ?? 0) ||
        b.tokens - a.tokens ||
        a.model.localeCompare(b.model),
    ),
    unpriced: {
      tokens: unpriced.reduce((n, m) => n + m.tokens, 0),
      models: [...new Set(unpriced.map((m) => m.model))].sort(),
    },
    rate: input.rate,
  };
}
