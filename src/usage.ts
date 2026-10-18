import type { StoredTokenUsage } from "./store.ts";

/** The document `suica usage` prints. The app window decodes it; see contracts/usage.v1.json. */
export interface TokenTotalsJson {
  /** Language model runs. */
  readonly runs: number;
  readonly inputTokens: number;
  readonly outputTokens: number;
  readonly cacheReadTokens: number;
  readonly cacheCreationTokens: number;
}

export interface PurposeUsageJson extends TokenTotalsJson {
  /** review, reply, other, or a purpose a newer agent wrote. */
  readonly purpose: string;
}

export interface DayUsageJson extends TokenTotalsJson {
  /** Local calendar day, `YYYY-MM-DD`. */
  readonly day: string;
}

export interface UsageJson {
  readonly version: 1;
  /** Epoch milliseconds. */
  readonly generatedAt: number;
  readonly last24h: TokenTotalsJson;
  readonly last7d: TokenTotalsJson;
  readonly last30d: TokenTotalsJson;
  /** Over the last 30 days, most tokens first. */
  readonly byPurpose: readonly PurposeUsageJson[];
  /** Oldest first, every day present. */
  readonly days: readonly DayUsageJson[];
}

export interface UsageInput {
  readonly rows: readonly StoredTokenUsage[];
  readonly now: number;
  readonly days: number;
  readonly dayKey: (ms: number) => string;
}

const DAY = 24 * 3_600_000;

type MutableTotals = { -readonly [K in keyof TokenTotalsJson]: TokenTotalsJson[K] };

const zero = (): MutableTotals => ({
  runs: 0,
  inputTokens: 0,
  outputTokens: 0,
  cacheReadTokens: 0,
  cacheCreationTokens: 0,
});

function add(totals: MutableTotals, row: StoredTokenUsage): void {
  totals.runs += 1;
  totals.inputTokens += row.inputTokens;
  totals.outputTokens += row.outputTokens;
  totals.cacheReadTokens += row.cacheReadTokens;
  totals.cacheCreationTokens += row.cacheCreationTokens;
}

function sum(rows: readonly StoredTokenUsage[]): TokenTotalsJson {
  const totals = zero();
  for (const row of rows) add(totals, row);
  return totals;
}

const tokens = (t: TokenTotalsJson): number =>
  t.inputTokens + t.outputTokens + t.cacheReadTokens + t.cacheCreationTokens;

export function buildUsage(input: UsageInput): UsageJson {
  const { now } = input;
  const rows = input.rows.filter((row) => row.at <= now);
  const since = (ms: number): StoredTokenUsage[] => rows.filter((row) => row.at >= now - ms);
  const month = since(30 * DAY);

  const purposes = new Map<string, MutableTotals>();
  for (const row of month) {
    const totals = purposes.get(row.purpose) ?? zero();
    add(totals, row);
    purposes.set(row.purpose, totals);
  }

  const days = new Map<string, MutableTotals & { day: string }>();
  for (let i = input.days - 1; i >= 0; i--) {
    const day = input.dayKey(now - i * DAY);
    if (!days.has(day)) days.set(day, { day, ...zero() });
  }
  for (const row of rows) {
    const day = days.get(input.dayKey(row.at));
    if (day !== undefined) add(day, row);
  }

  return {
    version: 1,
    generatedAt: now,
    last24h: sum(since(DAY)),
    last7d: sum(since(7 * DAY)),
    last30d: sum(month),
    byPurpose: [...purposes]
      .map(([purpose, totals]) => ({ purpose, ...totals }))
      .sort((a, b) => tokens(b) - tokens(a) || a.purpose.localeCompare(b.purpose)),
    days: [...days.values()],
  };
}
