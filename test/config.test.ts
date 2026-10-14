import { describe, expect, it } from "vitest";
import { ConfigError, parseConfig } from "../src/config.ts";

const MINIMAL = "gitlab:\n  hostname: gitlab.example\n";

describe("parseConfig", () => {
  it("applies every default to a minimal config", () => {
    expect(parseConfig(MINIMAL)).toEqual({
      gitlab: { hostname: "gitlab.example", glabPath: "glab", timeoutSeconds: 60 },
      polling: {
        activeSeconds: 120,
        idleSeconds: 300,
        idleAfterSeconds: 300,
        maxBackoffSeconds: 900,
      },
      notifications: { summaryThreshold: 4, ignoreAuthors: [] },
    });
  });

  it("lets values be overridden", () => {
    const config = parseConfig(
      `${MINIMAL}polling:\n  activeSeconds: 60\nnotifications:\n  ignoreAuthors: [ci-bot]\nstatePath: /tmp/state.db\n`,
    );
    expect(config.polling.activeSeconds).toBe(60);
    expect(config.notifications.ignoreAuthors).toEqual(["ci-bot"]);
    expect(config.statePath).toBe("/tmp/state.db");
  });

  it("rejects unknown keys so typos are not silently ignored", () => {
    expect(() => parseConfig(`${MINIMAL}polling:\n  activeSecs: 5\n`)).toThrow(ConfigError);
  });

  it("rejects non-positive intervals", () => {
    expect(() => parseConfig(`${MINIMAL}polling:\n  activeSeconds: 0\n`)).toThrow(ConfigError);
  });

  it("rejects a missing GitLab hostname and names the field", () => {
    expect(() => parseConfig("polling: {}\n")).toThrow(/gitlab/);
  });

  it("rejects invalid YAML and an empty file", () => {
    expect(() => parseConfig("gitlab: [unclosed")).toThrow(ConfigError);
    expect(() => parseConfig("")).toThrow(ConfigError);
  });
});
