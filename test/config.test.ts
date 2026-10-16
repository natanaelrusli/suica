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
      teams: {
        enabled: false,
        startTimeoutSeconds: 30,
        callTimeoutSeconds: 60,
        modes: { nudge: "approval", notice: "approval" },
        workingHours: { start: "09:00", end: "17:00", days: [1, 2, 3, 4, 5] },
        reminderAfterHours: 24,
        noticeDebounceMinutes: 10,
        maxMessagesPerReviewer: 2,
        people: {},
      },
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
    expect(() => parseConfig(`${MINIMAL}teams:\n  enable: true\n`)).toThrow(ConfigError);
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

describe("teams section", () => {
  it("lets each flow have its own send mode", () => {
    const config = parseConfig(
      `${MINIMAL}teams:\n  enabled: true\n  modes:\n    nudge: dry-run\n    notice: auto\n`,
    );
    expect(config.teams.enabled).toBe(true);
    expect(config.teams.modes).toEqual({ nudge: "dry-run", notice: "auto" });
  });

  it("rejects an unknown send mode", () => {
    expect(() => parseConfig(`${MINIMAL}teams:\n  modes:\n    nudge: yolo\n`)).toThrow(ConfigError);
  });

  it("rejects malformed or inverted working hours and bad weekdays", () => {
    expect(() => parseConfig(`${MINIMAL}teams:\n  workingHours:\n    start: "9am"\n`)).toThrow(
      ConfigError,
    );
    expect(() =>
      parseConfig(`${MINIMAL}teams:\n  workingHours:\n    start: "17:00"\n    end: "09:00"\n`),
    ).toThrow(/before/);
    expect(() => parseConfig(`${MINIMAL}teams:\n  workingHours:\n    days: [0]\n`)).toThrow(
      ConfigError,
    );
  });

  it("accepts a people map of GitLab usernames to emails and rejects anything else", () => {
    const config = parseConfig(`${MINIMAL}teams:\n  people:\n    "20435": rayhan@madhani.id\n`);
    expect(config.teams.people).toEqual({ "20435": "rayhan@madhani.id" });
    expect(() => parseConfig(`${MINIMAL}teams:\n  people:\n    "20435": not-an-email\n`)).toThrow(
      ConfigError,
    );
  });
});
