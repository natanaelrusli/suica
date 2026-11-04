import { addTo, type Bucket } from "./bucket.ts";
import { priceOf } from "./prices.ts";

interface Usage {
  input_tokens?: number;
  output_tokens?: number;
  cache_read_input_tokens?: number;
  cache_creation_input_tokens?: number;
  cache_creation?: { ephemeral_5m_input_tokens?: number; ephemeral_1h_input_tokens?: number };
}

interface Line {
  timestamp?: string;
  requestId?: string;
  message?: { id?: string; model?: string; usage?: Usage };
}

/** Hourly token buckets from Claude Code log lines; only counts, model and time are read. */
export function readClaudeLines(lines: Iterable<string>): Bucket[] {
  const buckets = new Map<string, Bucket>();
  const seen = new Set<string>();
  for (const line of lines) {
    let d: Line | null;
    try {
      d = JSON.parse(line) as Line | null;
    } catch {
      continue; // a line still being written
    }
    const m = d?.message;
    const u = m?.usage;
    const at = Date.parse(d?.timestamp ?? "");
    if (!m || !u || typeof m.model !== "string" || Number.isNaN(at)) continue;
    // one reply is logged once per content block with the same ids
    if (m.id && d?.requestId) {
      const id = `${m.id}|${d.requestId}`;
      if (seen.has(id)) continue;
      seen.add(id);
    }
    const input = u.input_tokens ?? 0;
    const cacheRead = u.cache_read_input_tokens ?? 0;
    const split = u.cache_creation;
    const cacheWrite5m = split
      ? (split.ephemeral_5m_input_tokens ?? 0)
      : (u.cache_creation_input_tokens ?? 0);
    const cacheWrite1h = split?.ephemeral_1h_input_tokens ?? 0;
    const context = input + cacheRead + cacheWrite5m + cacheWrite1h;
    addTo(buckets, {
      hour: Math.floor(at / 3_600_000) * 3_600_000,
      agent: "claude",
      model: m.model,
      long: context > (priceOf(m.model)?.long?.above ?? Infinity),
      input,
      output: u.output_tokens ?? 0,
      cacheRead,
      cacheWrite5m,
      cacheWrite1h,
    });
  }
  return [...buckets.values()];
}
