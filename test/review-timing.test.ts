import { describe, expect, it } from "vitest";
import { measureReviewStage } from "../src/review-timing.ts";

describe("measureReviewStage", () => {
  it("records one safe success record and preserves the value", async () => {
    let time = 100;
    const records: unknown[] = [];
    const result = await measureReviewStage(4, "model", () => time, (record) => records.push(record), async () => { time = 140; return "ok"; });
    expect(result).toBe("ok");
    expect(records).toEqual([{ reviewId: 4, stage: "model", durationMs: 40, outcome: "ok" }]);
  });

  it("records one failure and preserves the original error", async () => {
    let time = 100;
    const records: unknown[] = [];
    const failure = new Error("sensitive prompt/body");
    await expect(measureReviewStage(4, "judge", () => time, (record) => records.push(record), async () => { time = 140; throw failure; })).rejects.toBe(failure);
    expect(records).toEqual([{ reviewId: 4, stage: "judge", durationMs: 40, outcome: "failed" }]);
    expect(JSON.stringify(records)).not.toMatch(/prompt|body|sensitive/);
  });
});
