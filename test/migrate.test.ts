import { spawnSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

const SCRIPT = "scripts/migrate-to-suica.sh";
const LABEL = "com.madhani.mr-review-assistant";

const folders: string[] = [];
afterEach(() => {
  for (const folder of folders.splice(0)) rmSync(folder, { recursive: true, force: true });
});

interface Sandbox {
  home: string;
  bin: string;
  path: (...parts: string[]) => string;
  put: (relative: string, content: string) => void;
  run: (extraEnv?: Record<string, string>) => { status: number | null; output: string };
}

const stub = (bin: string, name: string, body: string): void => {
  const file = join(bin, name);
  writeFileSync(file, `#!/bin/sh\n${body}\n`);
  chmodSync(file, 0o755);
};

function sandbox(): Sandbox {
  const root = mkdtempSync(join(tmpdir(), "suica-migrate-"));
  folders.push(root);
  const home = join(root, "home");
  const bin = join(root, "bin");
  mkdirSync(home);
  mkdirSync(bin);
  stub(bin, "osascript", `echo "osascript $*" >> "$HOME/calls.log"`);
  // bootout logs and succeeds without unloading; print succeeds only while agent-loaded exists.
  stub(
    bin,
    "launchctl",
    `echo "launchctl $*" >> "$HOME/calls.log"\nif [ "$1" = print ] && [ ! -e "$HOME/agent-loaded" ]; then exit 1; fi\nexit 0`,
  );
  // -f matches by command line (marker: running); -x matches by exact name (marker: running-app).
  stub(
    bin,
    "pgrep",
    `echo "pgrep $*" >> "$HOME/calls.log"\nif [ "$1" = -x ]; then marker=running-app; else marker=running; fi\nif [ -e "$HOME/$marker" ]; then echo 4242; exit 0; fi\nexit 1`,
  );
  const path = (...parts: string[]): string => join(home, ...parts);
  return {
    home,
    bin,
    path,
    put: (relative, content) => {
      mkdirSync(dirname(path(relative)), { recursive: true });
      writeFileSync(path(relative), content);
    },
    run: (extraEnv = {}) => {
      const result = spawnSync("sh", [SCRIPT], {
        env: { HOME: home, PATH: `${bin}:/usr/bin:/bin`, ...extraEnv },
        encoding: "utf8",
      });
      return { status: result.status, output: `${result.stdout}${result.stderr}` };
    },
  };
}

const CONFIG = ".config/mr-review-assistant/config.yaml";
const STATE = "Library/Application Support/mr-review-assistant/state.db";
const WAL = "Library/Application Support/mr-review-assistant/state.db-wal";
const LOG = "Library/Logs/mr-review-assistant/stdout.log";
const PLIST = `Library/LaunchAgents/${LABEL}.plist`;
const APP = "Applications/MR Review Assistant.app/Contents/Info.plist";

const NEW_CONFIG = ".config/suica/config.yaml";
const NEW_STATE = "Library/Application Support/suica/state.db";
const NEW_WAL = "Library/Application Support/suica/state.db-wal";
const NEW_LOG = "Library/Logs/suica/stdout.log";

function seedOld(box: Sandbox, config = "pollSeconds: 60\n"): void {
  box.put(CONFIG, config);
  box.put(STATE, "db-bytes");
  box.put(WAL, "wal-bytes");
  box.put(LOG, "log-bytes");
  box.put(PLIST, "<plist/>");
  box.put(APP, "<plist/>");
}

describe("migrate-to-suica.sh", () => {
  it("moves config, state and logs and removes the old LaunchAgent and app", () => {
    const box = sandbox();
    seedOld(box);

    const { status, output } = box.run();

    expect(status).toBe(0);
    expect(readFileSync(box.path(NEW_CONFIG), "utf8")).toBe("pollSeconds: 60\n");
    expect(readFileSync(box.path(NEW_STATE), "utf8")).toBe("db-bytes");
    expect(readFileSync(box.path(NEW_WAL), "utf8")).toBe("wal-bytes");
    expect(readFileSync(box.path(NEW_LOG), "utf8")).toBe("log-bytes");
    for (const old of [CONFIG, STATE, WAL, LOG, PLIST, "Applications/MR Review Assistant.app"]) {
      expect(existsSync(box.path(old))).toBe(false);
    }
    const calls = readFileSync(box.path("calls.log"), "utf8");
    expect(calls).toContain("bootout gui/");
    expect(calls).toContain(LABEL);
    expect(calls).toContain(`${LABEL}.menubar`);
    expect(output).toContain("now run scripts/install-launchagent.sh");
  });

  it("says already migrated and changes nothing on a second run", () => {
    const box = sandbox();
    seedOld(box);
    expect(box.run().status).toBe(0);

    const { status, output } = box.run();

    expect(status).toBe(0);
    expect(output).toContain("already migrated");
    expect(readFileSync(box.path(NEW_CONFIG), "utf8")).toBe("pollSeconds: 60\n");
    expect(readFileSync(box.path(NEW_STATE), "utf8")).toBe("db-bytes");
    expect(readFileSync(box.path(NEW_LOG), "utf8")).toBe("log-bytes");
  });

  it("says already migrated on a machine that never had the old names", () => {
    const box = sandbox();
    const { status, output } = box.run();
    expect(status).toBe(0);
    expect(output).toContain("already migrated");
  });

  const expectNothingMoved = (box: Sandbox): void => {
    for (const old of [CONFIG, STATE, WAL, LOG, PLIST, APP]) {
      expect(existsSync(box.path(old))).toBe(true);
    }
    for (const created of [
      ".config/suica",
      "Library/Application Support/suica",
      "Library/Logs/suica",
    ]) {
      expect(existsSync(box.path(created))).toBe(false);
    }
  };

  it("refuses while an old process is running and moves nothing", () => {
    const box = sandbox();
    seedOld(box);
    box.put("running", "");

    const { status, output } = box.run();

    expect(status).toBe(1);
    expect(output).toContain("pid 4242");
    expect(output).toContain("an old process is still running");
    expectNothingMoved(box);
  }, 15_000);

  it("refuses while the old menu bar app is running (exact name) and moves nothing", () => {
    const box = sandbox();
    seedOld(box);
    box.put("running-app", "");

    const { status, output } = box.run();

    expect(status).toBe(1);
    expect(output).toContain("an old process is still running (pid 4242)");
    expect(readFileSync(box.path("calls.log"), "utf8")).toContain("pgrep -x MRAMenuBar");
    expectNothingMoved(box);
  }, 15_000);

  it("refuses while the old LaunchAgent is still loaded and moves nothing", () => {
    const box = sandbox();
    seedOld(box);
    box.put("agent-loaded", "");

    const { status, output } = box.run();

    expect(status).toBe(1);
    expect(output).toContain("the old LaunchAgent is still loaded");
    expect(output).toContain(LABEL);
    expect(readFileSync(box.path("calls.log"), "utf8")).toContain(`print gui/`);
    expectNothingMoved(box);
  }, 15_000);

  it("refuses when old and new folders both exist and moves nothing", () => {
    const box = sandbox();
    seedOld(box);
    box.put(NEW_CONFIG, "pollSeconds: 30\n");

    const { status, output } = box.run();

    expect(status).toBe(1);
    expect(output).toContain(box.path(".config/mr-review-assistant"));
    expect(output).toContain(box.path(".config/suica"));
    expect(output).toContain("merge them by hand");
    expect(readFileSync(box.path(NEW_CONFIG), "utf8")).toBe("pollSeconds: 30\n");
    for (const old of [CONFIG, STATE, WAL, LOG, PLIST, APP]) {
      expect(existsSync(box.path(old))).toBe(true);
    }
    expect(existsSync(box.path("Library/Application Support/suica"))).toBe(false);
    expect(existsSync(box.path("Library/Logs/suica"))).toBe(false);
  });

  it("checks every pair before moving: a conflict on only the last pair moves nothing", () => {
    const box = sandbox();
    seedOld(box);
    box.put(NEW_LOG, "newer-log");

    const { status, output } = box.run();

    expect(status).toBe(1);
    expect(output).toContain(box.path("Library/Logs/mr-review-assistant"));
    expect(output).toContain(box.path("Library/Logs/suica"));
    expect(output).toContain("merge them by hand");
    expect(readFileSync(box.path(NEW_LOG), "utf8")).toBe("newer-log");
    for (const old of [CONFIG, STATE, WAL, LOG, PLIST, APP]) {
      expect(existsSync(box.path(old))).toBe(true);
    }
    expect(existsSync(box.path(".config/suica"))).toBe(false);
    expect(existsSync(box.path("Library/Application Support/suica"))).toBe(false);
  });

  it("warns about explicit old paths in the config and leaves the YAML untouched", () => {
    const box = sandbox();
    const yaml = [
      "pollSeconds: 60",
      "statePath: /Users/x/Library/Application Support/mr-review-assistant/state.db",
      "teams:",
      "  templatesPath: /Users/x/.config/mr-review-assistant/templates",
      "",
    ].join("\n");
    seedOld(box, yaml);

    const { status, output } = box.run();

    expect(status).toBe(0);
    expect(output).toContain("warning:");
    expect(output).toContain("still names mr-review-assistant in: statePath");
    expect(output).toContain("still names mr-review-assistant in: templatesPath");
    expect(readFileSync(box.path(NEW_CONFIG), "utf8")).toBe(yaml);
  });

  it("warns about a leftover MRA_CONFIG", () => {
    const box = sandbox();
    seedOld(box);

    const { status, output } = box.run({ MRA_CONFIG: "/somewhere/config.yaml" });

    expect(status).toBe(0);
    expect(output).toContain("warning: MRA_CONFIG is set; rename it to SUICA_CONFIG");
  });
});
