import { describe, expect, it } from "vitest";
import { createLogger } from "../src/log.ts";

function capture(overrides: Parameters<typeof createLogger>[0] = {}): {
  lines: string[];
  log: ReturnType<typeof createLogger>;
} {
  const lines: string[] = [];
  const log = createLogger({
    serviceName: "mra",
    environment: "test",
    minLevel: "debug",
    write: (line) => lines.push(line),
    now: () => new Date("2026-10-14T01:02:03.000Z"),
    ...overrides,
  });
  return { lines, log };
}

describe("createLogger", () => {
  it("writes one JSON line with the mandatory fields and nested attributes", () => {
    const { lines, log } = capture();
    log.info("poll complete", { review_requested: 2 });
    expect(lines).toHaveLength(1);
    const parsed: unknown = JSON.parse(lines[0] ?? "");
    expect(parsed).toEqual({
      timestamp: "2026-10-14T01:02:03.000Z",
      level: "info",
      message: "poll complete",
      service_name: "mra",
      environment: "test",
      attributes: { review_requested: 2 },
    });
  });

  it("omits attributes when none are given", () => {
    const { lines, log } = capture();
    log.warn("polling paused");
    const parsed: unknown = JSON.parse(lines[0] ?? "");
    expect(parsed).not.toHaveProperty("attributes");
  });

  it("drops entries below the minimum level", () => {
    const { lines, log } = capture({ minLevel: "warn" });
    log.debug("quiet");
    log.info("quiet");
    log.error("loud");
    expect(lines).toHaveLength(1);
  });
});
