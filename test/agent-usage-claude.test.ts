import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { readClaudeLines } from "../src/agent-usage/claude.ts";

const lines = readFileSync(new URL("./fixtures/agent-usage/claude.jsonl", import.meta.url), "utf8").split("\n");
const hour = (iso: string) => Math.floor(Date.parse(iso) / 3_600_000) * 3_600_000;
const find = (model: string) => readClaudeLines(lines).filter((b) => b.model === model);

describe("readClaudeLines", () => {
  it("counts a reply repeated on 3 lines once, in its hour", () => {
    const sonnet = find("claude-sonnet-5-5");
    const h3 = sonnet.find((b) => b.hour === hour("2026-11-04T03:00:00Z"));
    // reply A (3 lines) + reply B, merged in the same hour
    expect(h3).toMatchObject({ agent: "claude", input: 12, output: 277, cacheRead: 25743, long: false });
  });

  it("splits cache writes by ttl, or puts an unsplit total in 5m", () => {
    const h3 = find("claude-sonnet-5-5")[0]!;
    expect(h3.cacheWrite5m).toBe(800 + 300);
    expect(h3.cacheWrite1h).toBe(28015);
  });

  it("marks long only past the model's own threshold", () => {
    expect(find("claude-haiku-5-5")[0]).toMatchObject({ long: true });
    expect(find("claude-opus-5-5")[0]).toMatchObject({ long: false });
  });

  it("ignores user lines and a truncated last line without throwing", () => {
    expect(readClaudeLines(lines).reduce((n, b) => n + b.input, 0)).toBe(12 + 50 + 50);
    expect(readClaudeLines(['{"type":"assistant","message":{"usage":{"input_tok'])).toEqual([]);
  });
});
