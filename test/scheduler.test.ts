import { describe, expect, it } from "vitest";
import { nextDelaySeconds } from "../src/scheduler.ts";

const polling = {
  activeSeconds: 120,
  idleSeconds: 300,
  idleAfterSeconds: 300,
  maxBackoffSeconds: 900,
};

describe("nextDelaySeconds", () => {
  it("uses the active interval while the Owner is around", () => {
    expect(nextDelaySeconds({ idleSeconds: 10, failureStreak: 0, polling })).toBe(120);
  });

  it("switches to the idle interval at the idle threshold", () => {
    expect(nextDelaySeconds({ idleSeconds: 299, failureStreak: 0, polling })).toBe(120);
    expect(nextDelaySeconds({ idleSeconds: 300, failureStreak: 0, polling })).toBe(300);
  });

  it("doubles per consecutive failure up to the cap", () => {
    const delays = [1, 2, 3, 4].map((failureStreak) =>
      nextDelaySeconds({ idleSeconds: 0, failureStreak, polling }),
    );
    expect(delays).toEqual([240, 480, 900, 900]);
  });

  it("never goes below the base interval even if the cap is smaller", () => {
    expect(
      nextDelaySeconds({
        idleSeconds: 999,
        failureStreak: 3,
        polling: { ...polling, maxBackoffSeconds: 200 },
      }),
    ).toBe(300);
  });
});
