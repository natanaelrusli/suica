import { addTo, type Bucket } from "./bucket.ts";
import { priceOf } from "./prices.ts";

interface Totals {
  input_tokens?: number;
  cached_input_tokens?: number;
  cache_write_input_tokens?: number;
  output_tokens?: number;
}

interface Line {
  timestamp?: string;
  type?: string;
  payload?: {
    type?: string;
    id?: string;
    model?: string;
    thread_settings?: { model?: string };
    info?: { total_token_usage?: Totals; last_token_usage?: Totals } | null;
  };
}

const ZERO: Required<Totals> = {
  input_tokens: 0,
  cached_input_tokens: 0,
  cache_write_input_tokens: 0,
  output_tokens: 0,
};

/**
 * Hourly token buckets and the session id from Codex rollout lines; only counts, model and time are read.
 * Counts are the change in the cumulative `total_token_usage`, so a repeated event adds nothing and a
 * lower total (a reset) adds nothing for that event but becomes the new baseline.
 */
export function readCodexLines(lines: Iterable<string>): {
  sessionId: string | undefined;
  buckets: Bucket[];
} {
  const buckets = new Map<string, Bucket>();
  let sessionId: string | undefined;
  let model = "unknown";
  let prev = ZERO;
  for (const line of lines) {
    let d: Line | null;
    try {
      d = JSON.parse(line) as Line | null;
    } catch {
      continue; // a line still being written
    }
    const p = d?.payload;
    if (!d || !p) continue;
    if (d.type === "session_meta") {
      if (typeof p.id === "string") sessionId = p.id;
    } else if (d.type === "turn_context" || p.type === "thread_settings_applied") {
      // many rollouts have no turn_context, only thread_settings_applied
      const m = p.model ?? p.thread_settings?.model;
      if (typeof m === "string") model = m;
    } else if (p.type === "token_count" && p.info?.total_token_usage) {
      const at = Date.parse(d.timestamp ?? "");
      if (Number.isNaN(at)) continue;
      const t = { ...ZERO, ...p.info.total_token_usage };
      const before = prev;
      prev = t;
      const up = (k: keyof Totals) => Math.max(0, t[k] - before[k]);
      const last = p.info.last_token_usage;
      const cacheWrite5m = up("cache_write_input_tokens");
      const cacheRead = up("cached_input_tokens");
      addTo(buckets, {
        hour: Math.floor(at / 3_600_000) * 3_600_000,
        agent: "codex",
        model,
        // the prompt of this one request, not the session total
        long:
          (last?.input_tokens ?? 0) + (last?.cache_write_input_tokens ?? 0) >
          (priceOf(model)?.long?.above ?? Infinity),
        // input_tokens includes cached_input_tokens in OpenAI's format
        input: Math.max(0, up("input_tokens") - cacheRead),
        // output_tokens already includes reasoning tokens, so reasoning_output_tokens is not added:
        // https://developers.openai.com/api/docs/guides/reasoning (usage example: total = input + output,
        // reasoning counted inside output); Codex also logs last_usage_includes_reasoning: true.
        output: up("output_tokens"),
        cacheRead,
        cacheWrite5m,
        cacheWrite1h: 0,
      });
    }
  }
  return { sessionId, buckets: [...buckets.values()] };
}
