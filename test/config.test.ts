import { homedir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import {
  ConfigError,
  defaultConfigPath,
  expandHome,
  parseConfig,
  validateConfig,
} from "../src/config.ts";

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
        modes: { nudge: "approval", notice: "approval", rereview: "approval", findings: "auto" },
        workingHours: { start: "09:00", end: "17:00", days: [1, 2, 3, 4, 5] },
        reminderAfterHours: 24,
        noticeDebounceMinutes: 10,
        rereviewAfterMinutes: 10,
        maxMessagesPerReviewer: 2,
        people: {},
        agentName: "Suica",
      },
      model: { cli: "auto" },
      review: {
        auto: true,
        post: "approval",
        postAs: "comment",
        approve: false,
        skill: "madhani:madhani-code-review",
        maxChangedLines: 800,
        maxPerDay: 10,
        rereviewAfterMinutes: 10,
        timeoutMinutes: 20,
      },
    });
  });

  it("teams.agentName defaults to Suica and must not be blank", () => {
    expect(parseConfig(MINIMAL).teams.agentName).toBe("Suica");
    expect(parseConfig(`${MINIMAL}teams:\n  agentName: Bahlil\n`).teams.agentName).toBe("Bahlil");
    expect(() => parseConfig(`${MINIMAL}teams:\n  agentName: "  "\n`)).toThrow();
  });

  it("review.approve is off by default", () => {
    expect(parseConfig(MINIMAL).review.approve).toBe(false);
    expect(parseConfig(`${MINIMAL}review:\n  approve: true\n`).review.approve).toBe(true);
  });

  it("review.rereviewAfterMinutes defaults to 10", () => {
    expect(parseConfig(MINIMAL).review.rereviewAfterMinutes).toBe(10);
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
      `${MINIMAL}teams:\n  enabled: true\n  modes:\n    nudge: dry-run\n    notice: auto\n    rereview: auto\n`,
    );
    expect(config.teams.enabled).toBe(true);
    expect(config.teams.modes).toEqual({
      nudge: "dry-run",
      notice: "auto",
      rereview: "auto",
      findings: "auto",
    });
    expect(
      parseConfig(`${MINIMAL}teams:\n  modes:\n    findings: approval\n`).teams.modes.findings,
    ).toBe("approval");
  });

  it("asks for approval before a Re-review Nudge unless the Owner says otherwise", () => {
    expect(parseConfig(MINIMAL).teams.modes.rereview).toBe("approval");
    expect(parseConfig(`${MINIMAL}teams:\n  modes:\n    nudge: auto\n`).teams.modes.rereview).toBe(
      "approval",
    );
    const config = parseConfig(`${MINIMAL}teams:\n  modes:\n    rereview: auto\n`);
    expect(config.teams.modes).toEqual({
      nudge: "approval",
      notice: "approval",
      rereview: "auto",
      findings: "auto",
    });
  });

  it("waits 10 minutes after a push by default, takes a positive whole number and rejects the rest", () => {
    expect(parseConfig(MINIMAL).teams.rereviewAfterMinutes).toBe(10);
    expect(
      parseConfig(`${MINIMAL}teams:\n  rereviewAfterMinutes: 3\n`).teams.rereviewAfterMinutes,
    ).toBe(3);
    for (const bad of ["0", "-1", "2.5", "soon"]) {
      expect(() => parseConfig(`${MINIMAL}teams:\n  rereviewAfterMinutes: ${bad}\n`)).toThrow(
        ConfigError,
      );
    }
    expect(() => parseConfig(`${MINIMAL}teams:\n  modes:\n    rereview: yolo\n`)).toThrow(
      ConfigError,
    );
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

describe("defaultConfigPath", () => {
  it("uses SUICA_CONFIG when set", () => {
    expect(defaultConfigPath({ SUICA_CONFIG: "/x/c.yaml" })).toBe("/x/c.yaml");
  });
  it("defaults to ~/.config/suica/config.yaml", () => {
    expect(defaultConfigPath({})).toBe(join(homedir(), ".config", "suica", "config.yaml"));
  });
  it("refuses a leftover MRA_CONFIG", () => {
    expect(() => defaultConfigPath({ MRA_CONFIG: "/old.yaml" })).toThrow(
      "MRA_CONFIG is no longer read; rename it to SUICA_CONFIG",
    );
  });
  it("lets SUICA_CONFIG win over a leftover MRA_CONFIG", () => {
    expect(defaultConfigPath({ MRA_CONFIG: "/old.yaml", SUICA_CONFIG: "/new.yaml" })).toBe(
      "/new.yaml",
    );
  });
});

describe("a leading ~ in the path settings", () => {
  const home = homedir();
  const PATHS = [
    "gitlab:",
    "  hostname: h",
    "  glabPath: ~/bin/glab",
    "teams:",
    "  command: ~/run.sh",
    "  templatesPath: ~/t",
    "statePath: ~/x/state.db",
  ].join("\n");

  it("is expanded to the home folder when the config is loaded", () => {
    const config = parseConfig(PATHS);
    expect(config.gitlab.glabPath).toBe(join(home, "bin", "glab"));
    expect(config.teams.command).toBe(join(home, "run.sh"));
    expect(config.teams.templatesPath).toBe(join(home, "t"));
    expect(config.statePath).toBe(join(home, "x", "state.db"));
  });

  it("expands ~ alone and ~/ only at the start", () => {
    expect(expandHome("~")).toBe(home);
    expect(expandHome("~/")).toBe(`${home}/`);
    expect(expandHome("~/x")).toBe(`${home}/x`);
    for (const kept of ["a/~/b", "~other/x", "/abs/~", "x~", "glab", ""]) {
      expect(expandHome(kept)).toBe(kept);
    }
    expect(parseConfig(`${MINIMAL}statePath: ~other/s.db\n`).statePath).toBe("~other/s.db");
    expect(parseConfig(`${MINIMAL}statePath: a/~/s.db\n`).statePath).toBe("a/~/s.db");
  });

  it("is kept as typed by validateConfig, which the editor uses", () => {
    const result = validateConfig({ gitlab: { hostname: "h" }, statePath: "~/x/state.db" });
    expect(result.ok && result.config.statePath).toBe("~/x/state.db");
  });
});

describe("review.model", () => {
  it("takes model names and refuses anything that could be read as a flag", () => {
    for (const model of ["sonnet", "opus", "haiku", "claude-opus-5-5", "opus[1m]", "gpt-5.5"]) {
      expect(
        parseConfig(`gitlab:\n  hostname: h\nreview:\n  model: "${model}"\n`).review.model,
      ).toBe(model);
    }
    for (const model of ["-x", "--dangerously-skip-permissions", "", "a b", "a;b"]) {
      expect(() => parseConfig(`gitlab:\n  hostname: h\nreview:\n  model: "${model}"\n`)).toThrow(
        /review.model/,
      );
    }
  });
});
