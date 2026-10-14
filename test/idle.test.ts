import { describe, expect, it } from "vitest";
import { parseIdleSeconds, readIdleSeconds } from "../src/idle.ts";

describe("parseIdleSeconds", () => {
  it("converts nanoseconds from ioreg output to seconds", () => {
    expect(parseIdleSeconds('    | |   "HIDIdleTime" = 4500000000\n')).toBe(4.5);
  });

  it("returns null when the field is absent", () => {
    expect(parseIdleSeconds("nothing here")).toBeNull();
  });
});

describe("readIdleSeconds", () => {
  it("treats a failing ioreg as 'active' so polling stays at the fast interval", async () => {
    await expect(readIdleSeconds(() => Promise.reject(new Error("no ioreg")))).resolves.toBe(0);
  });
});
