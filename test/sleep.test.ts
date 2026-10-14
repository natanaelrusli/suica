import { afterEach, describe, expect, it, vi } from "vitest";
import { abortableSleep } from "../src/daemon.ts";

afterEach(() => {
  vi.useRealTimers();
});

describe("abortableSleep", () => {
  it("resolves right away when the signal is already aborted", async () => {
    const controller = new AbortController();
    controller.abort();
    await expect(abortableSleep(60_000, controller.signal)).resolves.toBeUndefined();
  });

  it("resolves when aborted while waiting", async () => {
    vi.useFakeTimers();
    const controller = new AbortController();
    let resolved = false;
    void abortableSleep(60_000, controller.signal).then(() => {
      resolved = true;
    });
    await vi.advanceTimersByTimeAsync(1_000);
    expect(resolved).toBe(false);
    controller.abort();
    await vi.advanceTimersByTimeAsync(0);
    expect(resolved).toBe(true);
  });

  it("measures the deadline on the wall clock, so a Mac that slept through it wakes up on time", async () => {
    vi.useFakeTimers();
    let clock = 0;
    const controller = new AbortController();
    let resolved = false;
    void abortableSleep(900_000, controller.signal, () => clock).then(() => {
      resolved = true;
    });
    // The wall clock jumps over the whole sleep while the monotonic timers barely advance.
    clock = 900_000;
    await vi.advanceTimersByTimeAsync(15_000);
    expect(resolved).toBe(true);
  });

  it("keeps waiting while the wall-clock deadline has not passed", async () => {
    vi.useFakeTimers();
    let clock = 0;
    const controller = new AbortController();
    let resolved = false;
    void abortableSleep(40_000, controller.signal, () => clock).then(() => {
      resolved = true;
    });
    clock = 15_000;
    await vi.advanceTimersByTimeAsync(15_000);
    expect(resolved).toBe(false);
    clock = 40_000;
    await vi.advanceTimersByTimeAsync(15_000);
    expect(resolved).toBe(true);
  });
});
