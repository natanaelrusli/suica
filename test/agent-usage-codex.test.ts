import { readFileSync } from "node:fs";
import { zstdDecompressSync } from "node:zlib";
import { describe, expect, it } from "vitest";
import { readCodexLines } from "../src/agent-usage/codex.ts";

const text = readFileSync(new URL("./fixtures/agent-usage/codex.jsonl", import.meta.url), "utf8");
const hour = (iso: string) => Math.floor(Date.parse(iso) / 3_600_000) * 3_600_000;
const read = () => readCodexLines(text.split("\n"));

/** One token_count line with the given cumulative input and last-request prompt size. */
const ev = (at: string, total: number, lastInput: number, lastWrite = 0) =>
  JSON.stringify({
    timestamp: at,
    type: "event_msg",
    payload: {
      type: "token_count",
      info: {
        total_token_usage: { input_tokens: total },
        last_token_usage: { input_tokens: lastInput, cache_write_input_tokens: lastWrite },
      },
    },
  });
const model = (name: string) =>
  JSON.stringify({
    timestamp: "2026-11-04T00:00:00Z",
    type: "turn_context",
    payload: { model: name },
  });

describe("readCodexLines", () => {
  it("reads the session id from session_meta", () => {
    expect(read().sessionId).toBe("11111111-aaaa-7bbb-8ccc-000000000001");
  });

  it("counts the change in total usage; a repeat and a lower total add nothing", () => {
    const h1 = read().buckets.find((b) => b.hour === hour("2026-11-04T01:00:00Z"));
    // input 900 - cached 400; output 40 (reasoning is inside it, not added)
    expect(h1).toMatchObject({
      agent: "codex",
      model: "gpt-6.1-sol",
      input: 500,
      cacheRead: 400,
      cacheWrite5m: 100,
      cacheWrite1h: 0,
      output: 40,
      long: false,
    });
  });

  it("takes the model from the latest naming line, or unknown before any", () => {
    const first = read().buckets.find((b) => b.hour === hour("2026-11-04T00:00:00Z"));
    expect(first).toMatchObject({ model: "unknown", input: 100, output: 10 });
  });

  it("counts growth after a lower total from the new baseline", () => {
    const h2 = read().buckets.find((b) => b.hour === hour("2026-11-04T02:00:00Z"));
    expect(h2).toMatchObject({ input: 300000, cacheRead: 0, output: 100 });
  });

  it("marks long per request, past the model's own threshold, cache writes included", () => {
    const h2 = read().buckets.find((b) => b.hour === hour("2026-11-04T02:00:00Z"));
    expect(h2?.long).toBe(true);
    const run = (lastInput: number, write = 0, m = "gpt-6.1-sol") =>
      readCodexLines([model(m), ev("2026-11-04T01:00:00Z", 1, lastInput, write)]).buckets[0]!.long;
    expect(run(272_001)).toBe(true);
    expect(run(250_000)).toBe(false);
    expect(run(200_000, 80_000)).toBe(true);
    expect(run(900_000, 0, "codex-auto-review")).toBe(false);
  });

  it("splits a session that crosses the threshold across both buckets", () => {
    const { buckets } = readCodexLines([
      model("gpt-6.1-sol"),
      ev("2026-11-04T01:00:00Z", 1000, 1000),
      ev("2026-11-04T01:05:00Z", 301000, 300000),
    ]);
    expect(buckets.map((b) => [b.long, b.input])).toEqual([
      [false, 1000],
      [true, 300000],
    ]);
  });

  it("ignores other lines and a truncated last line without throwing", () => {
    expect(read().buckets.reduce((n, b) => n + b.input, 0)).toBe(100 + 500 + 300000);
    expect(readCodexLines(['{"payload":{"type":"token_count","info":{"total_tok'])).toEqual({
      sessionId: undefined,
      buckets: [],
    });
  });

  it("reads the zstd fixture the same way", () => {
    const zst = readFileSync(new URL("./fixtures/agent-usage/codex.jsonl.zst", import.meta.url));
    expect(readCodexLines(zstdDecompressSync(zst).toString("utf8").split("\n"))).toEqual(read());
  });
});
