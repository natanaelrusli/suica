import { spawnSync } from "node:child_process";
import {
  existsSync,
  lstatSync,
  readlinkSync,
  symlinkSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
  chmodSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import type { Exec } from "../src/exec.ts";
import {
  InvalidSettings,
  applyInstall,
  applyUninstall,
  installHooks,
  lessonsStatus,
  hookCommand,
  planInstall,
  uninstallHooks,
  writeSettingsAtomic,
} from "../src/lessons/install.ts";
import type { LessonsPaths } from "../src/lessons/install.ts";
import type { DetectedCli } from "../src/model-cli.ts";

const folders: string[] = [];
afterEach(() => {
  for (const folder of folders.splice(0)) rmSync(folder, { recursive: true, force: true });
});
function temp(): string {
  const folder = mkdtempSync(join(tmpdir(), "suica-lesson-install-"));
  folders.push(folder);
  return folder;
}

const COMMAND = '"/n/node" "/i/src/lessons-hook.ts"';
const paths: LessonsPaths = {
  node: "/n/node",
  cli: "/i/src/cli.ts",
  hook: "/i/src/lessons-hook.ts",
};
const ours = { type: "command", command: COMMAND, timeout: 5 };
const cli = (id: "claude" | "codex" | "gemini", found: boolean): DetectedCli => ({
  id,
  name: id,
  path: found ? `/bin/${id}` : null,
});

function home0(path: string): string {
  return join(path, "..");
}

function recorder(failing: (args: readonly string[]) => boolean = () => false) {
  const calls: { file: string; args: readonly string[]; timeoutMs: number }[] = [];
  const exec: Exec = (file, args, options) => {
    calls.push({ file, args, timeoutMs: options.timeoutMs });
    return failing(args)
      ? Promise.reject(new Error("exit 1: server not found"))
      : Promise.resolve({ stdout: "", stderr: "" });
  };
  return { exec, calls };
}

describe("installHooks", () => {
  it("adds three hook entries and keeps existing hooks, groups and keys", () => {
    const user = { type: "command", command: "echo hi" };
    const before = JSON.stringify(
      {
        model: "opus",
        permissions: { allow: ["Bash(ls)"] },
        hooks: {
          PostToolUse: [
            { matcher: "Read", hooks: [user] },
            { matcher: "Bash", hooks: [user] },
          ],
          Stop: [{ hooks: [user] }],
        },
      },
      null,
      2,
    );
    const after = JSON.parse(installHooks(before + "\n", COMMAND)) as Record<string, unknown>;
    expect(after["model"]).toBe("opus");
    expect(after["permissions"]).toEqual({ allow: ["Bash(ls)"] });
    const hooks = after["hooks"] as Record<string, unknown[]>;
    expect(hooks["Stop"]).toEqual([{ hooks: [user] }]);
    expect(hooks["SessionStart"]).toEqual([{ hooks: [ours] }]);
    expect(hooks["PreToolUse"]).toEqual([{ matcher: "Write|Edit|MultiEdit", hooks: [ours] }]);
    expect(hooks["PostToolUse"]).toEqual([
      { matcher: "Read", hooks: [user] },
      { matcher: "Bash", hooks: [user] },
      { matcher: "Read", hooks: [ours] },
    ]);
  });

  it("twice yields identical text", () => {
    const once = installHooks('{"a":1}\n', COMMAND);
    expect(installHooks(once, COMMAND)).toBe(once);
  });

  it("replaces our previous entry when the command changed instead of duplicating it", () => {
    const once = installHooks(undefined, '"/old/node" "/old/src/lessons-hook.ts"');
    const twice = installHooks(once, COMMAND);
    expect(twice).not.toContain("/old/");
    expect(twice.split("lessons-hook.ts").length - 1).toBe(3);
  });

  it("creates a minimal file when there is none", () => {
    const text = installHooks(undefined, COMMAND);
    expect(text.endsWith("\n")).toBe(true);
    expect(Object.keys((JSON.parse(text) as { hooks: object }).hooks)).toEqual([
      "SessionStart",
      "PostToolUse",
      "PreToolUse",
    ]);
  });

  it("keeps the file's indentation and its lack of a trailing newline", () => {
    const tabs = installHooks('{\n\t"a": 1\n}', COMMAND);
    expect(tabs).toMatch(/^\{\n\t"a": 1,\n\t"hooks"/);
    expect(tabs.endsWith("\n")).toBe(false);
    const four = installHooks('{\n    "a": 1\n}\n', COMMAND);
    expect(four).toMatch(/\n {4}"hooks"/);
    expect(four.endsWith("}\n")).toBe(true);
  });

  it("throws InvalidSettings for non-JSON and for a non-object top level", () => {
    expect(() => installHooks("{nope", COMMAND)).toThrow(InvalidSettings);
    expect(() => installHooks("[]", COMMAND)).toThrow(InvalidSettings);
    expect(() => installHooks('{"hooks":[]}', COMMAND)).toThrow(InvalidSettings);
    expect(() => installHooks('{"hooks":{"Stop":{}}}', COMMAND)).not.toThrow();
  });
});

describe("uninstallHooks", () => {
  it("removes only our entries and the structures that removal emptied", () => {
    const user = { type: "command", command: "echo hi" };
    const installed = installHooks(
      JSON.stringify({ hooks: { PostToolUse: [{ matcher: "Read", hooks: [user] }] }, x: 1 }),
      COMMAND,
    );
    const back = JSON.parse(uninstallHooks(installed, COMMAND)) as Record<string, unknown>;
    expect(back).toEqual({ hooks: { PostToolUse: [{ matcher: "Read", hooks: [user] }] }, x: 1 });
  });

  it("drops the hooks key only when we emptied it, and leaves the user's own empty structures", () => {
    expect(JSON.parse(uninstallHooks(installHooks('{"x":1}', COMMAND), COMMAND))).toEqual({ x: 1 });
    const mine = JSON.stringify({ hooks: { Stop: [], Other: [{ hooks: [] }] } });
    expect(uninstallHooks(mine, COMMAND)).toBe(mine);
    const mixed = installHooks(mine, COMMAND);
    expect(JSON.parse(uninstallHooks(mixed, COMMAND))).toEqual({
      hooks: { Stop: [], Other: [{ hooks: [] }] },
    });
  });

  it("leaves unparseable settings to the caller", () => {
    expect(() => uninstallHooks("nope", COMMAND)).toThrow(InvalidSettings);
  });
});

describe("writeSettingsAtomic", () => {
  it("creates the folder and a 0600 file, and leaves no temp file", () => {
    const home = temp();
    const path = join(home, ".claude", "settings.json");
    writeSettingsAtomic(path, "{}\n");
    expect(statSync(path).mode & 0o777).toBe(0o600);
    expect(readdirSync(join(home, ".claude"))).toEqual(["settings.json"]);
  });

  it("keeps the mode of an existing file", () => {
    const home = temp();
    const path = join(home, "settings.json");
    writeFileSync(path, "{}");
    chmodSync(path, 0o644);
    writeSettingsAtomic(path, '{"a":1}');
    expect(statSync(path).mode & 0o777).toBe(0o644);
    expect(readFileSync(path, "utf8")).toBe('{"a":1}');
    expect(readdirSync(home)).toEqual(["settings.json"]);
  });
});

describe("applyInstall", () => {
  it("writes the hooks and registers with claude, and with codex only when installed", async () => {
    const home = temp();
    const { exec, calls } = recorder();
    const result = await applyInstall(
      home,
      exec,
      [cli("claude", true), cli("codex", false), cli("gemini", false)],
      paths,
    );
    expect(result).toMatchObject({
      status: "installed",
      changed: true,
      registered: ["claude"],
      skipped: ["codex"],
    });
    expect(calls.map((c) => [c.file, ...c.args])).toEqual([
      ["/bin/claude", "mcp", "remove", "--scope", "user", "suica-lessons"],
      [
        "/bin/claude",
        "mcp",
        "add",
        "--scope",
        "user",
        "suica-lessons",
        "--",
        "/n/node",
        "/i/src/cli.ts",
        "lessons",
        "mcp",
      ],
    ]);
    expect(calls.every((c) => c.timeoutMs === 30_000)).toBe(true);
    expect(existsSync(join(home, ".claude", "settings.json"))).toBe(true);

    const both = recorder((args) => args[1] === "remove");
    const second = await applyInstall(
      home,
      both.exec,
      [cli("claude", true), cli("codex", true)],
      paths,
    );
    expect(second).toMatchObject({ changed: false, registered: ["claude", "codex"] });
    expect(both.calls.map((c) => c.args.join(" "))).toContain(
      "mcp add suica-lessons -- /n/node /i/src/cli.ts lessons mcp",
    );
  });

  it("reports a CLI whose add failed", async () => {
    const { exec } = recorder((args) => args[1] === "add");
    const result = await applyInstall(temp(), exec, [cli("claude", true)], paths);
    expect(result.failed).toEqual(["claude"]);
    expect(result.status).toBe("partial");
    expect(existsSync(join(home0(result.settingsPath), "settings.json"))).toBe(true);
  });

  it("refuses settings that are not JSON, leaving the file and the CLIs untouched", async () => {
    const home = temp();
    mkdirSync(join(home, ".claude"));
    const file = join(home, ".claude", "settings.json");
    writeFileSync(file, "// comments\n{");
    const { exec, calls } = recorder();
    const result = await applyInstall(home, exec, [cli("claude", true)], paths);
    expect(result.status).toBe("invalid-settings");
    expect(readFileSync(file, "utf8")).toBe("// comments\n{");
    expect(calls).toEqual([]);
    writeFileSync(file, "[1]");
    expect((await applyInstall(home, exec, [], paths)).status).toBe("invalid-settings");
    expect(readFileSync(file, "utf8")).toBe("[1]");
  });

  it("does not write when the text would not change", async () => {
    const home = temp();
    await applyInstall(home, recorder().exec, [], paths);
    const file = join(home, ".claude", "settings.json");
    chmodSync(file, 0o400);
    const before = statSync(file).mtimeMs;
    const result = await applyInstall(home, recorder().exec, [], paths);
    expect(result.changed).toBe(false);
    expect(statSync(file).mtimeMs).toBe(before);
  });
});

describe("applyUninstall and lessonsStatus", () => {
  it("removes our entries and runs the matching removes", async () => {
    const home = temp();
    const file = join(home, ".claude", "settings.json");
    mkdirSync(join(home, ".claude"));
    writeFileSync(file, '{\n  "model": "opus"\n}\n');
    await applyInstall(home, recorder().exec, [], paths);
    const { exec, calls } = recorder((args) => args[0] === "mcp" && args[1] === "remove");
    const result = await applyUninstall(
      home,
      exec,
      [cli("claude", true), cli("codex", true)],
      paths,
    );
    expect(result).toMatchObject({ status: "uninstalled", hookRemoved: true, removed: [] });
    expect(readFileSync(file, "utf8")).toBe('{\n  "model": "opus"\n}\n');
    expect(calls.map((c) => c.args.join(" "))).toEqual([
      "mcp remove --scope user suica-lessons",
      "mcp remove suica-lessons",
    ]);
  });

  it("status reads the hooks and the CLIs' lists, treating failures as false", async () => {
    const home = temp();
    const clis = [cli("claude", true), cli("codex", true)];
    const list: Exec = (file) =>
      file === "/bin/claude"
        ? Promise.resolve({
            stdout: "other: x\nnot-suica-lessons: y\nsuica-lessons: /n/node - Connected\n",
            stderr: "",
          })
        : Promise.reject(new Error("boom"));
    expect(await lessonsStatus(home, list, clis, paths)).toEqual({
      hook: false,
      mcp: { claude: true, codex: false },
    });
    await applyInstall(home, recorder().exec, [], paths);
    expect((await lessonsStatus(home, list, [], paths)).hook).toBe(true);
    const moved = { ...paths, hook: "/elsewhere/src/lessons-hook.ts" };
    expect((await lessonsStatus(home, list, [], moved)).hook).toBe(false);
  });
});

describe("planInstall", () => {
  it("lists the three hooks and the CLIs that would be registered", () => {
    const plan = planInstall("/h", [cli("claude", true), cli("codex", false)], paths);
    expect(plan.settingsPath).toBe("/h/.claude/settings.json");
    expect(plan.hooks.map((h) => h.event)).toEqual(["SessionStart", "PostToolUse", "PreToolUse"]);
    expect(plan.mcp).toEqual(["claude"]);
  });
});

describe("suica lessons (CLI)", () => {
  function suica(home: string, ...args: string[]) {
    const bin = join(home, "bin");
    mkdirSync(bin, { recursive: true });
    const result = spawnSync(process.execPath, ["src/cli.ts", "lessons", ...args], {
      encoding: "utf8",
      env: { HOME: home, PATH: bin, SUICA_CLI_DIRS: bin, SUICA_CONFIG: join(home, "none.yaml") },
    });
    return { status: result.status, stdout: result.stdout };
  }

  it("install without --yes prints the plan, exits 1 and creates nothing", () => {
    const home = temp();
    const result = suica(home, "install", "--json");
    expect(result.status).toBe(1);
    const doc = JSON.parse(result.stdout) as {
      version: number;
      status: string;
      plan: { hooks: unknown[] };
    };
    expect(doc).toMatchObject({ version: 1, status: "needs-confirmation" });
    expect(doc.plan.hooks).toHaveLength(3);
    expect(existsSync(join(home, ".claude"))).toBe(false);
    const text = suica(home, "install");
    expect(text.status).toBe(1);
    expect(text.stdout).toContain("settings.json");
    expect(existsSync(join(home, ".claude"))).toBe(false);
  }, 20_000);

  it("install --yes reports invalid settings and leaves them alone", () => {
    const home = temp();
    mkdirSync(join(home, ".claude"));
    writeFileSync(join(home, ".claude", "settings.json"), "not json");
    const result = suica(home, "install", "--yes", "--json");
    expect(result.status).toBe(1);
    expect(JSON.parse(result.stdout)).toMatchObject({ status: "invalid-settings" });
    expect(readFileSync(join(home, ".claude", "settings.json"), "utf8")).toBe("not json");
  }, 20_000);

  it("a failed add exits 1 with status partial and the hooks still written", () => {
    const home = temp();
    const bin = join(home, "bin");
    mkdirSync(bin);
    writeFileSync(join(bin, "claude"), '#!/bin/sh\n[ "$2" = add ] && exit 3\nexit 0\n', {
      mode: 0o755,
    });
    const result = suica(home, "install", "--yes", "--json");
    expect(result.status).toBe(1);
    expect(JSON.parse(result.stdout)).toMatchObject({ status: "partial", failed: ["claude"] });
    expect(readFileSync(join(home, ".claude", "settings.json"), "utf8")).toContain(
      "lessons-hook.ts",
    );
  }, 20_000);

  it("uninstall exits 1 with status partial when a remove fails for another reason", () => {
    const home = temp();
    const bin = join(home, "bin");
    mkdirSync(bin);
    writeFileSync(join(bin, "claude"), "#!/bin/sh\necho 'permission denied' >&2\nexit 3\n", {
      mode: 0o755,
    });
    const result = suica(home, "uninstall", "--json");
    expect(result.status).toBe(1);
    expect(JSON.parse(result.stdout)).toMatchObject({ status: "partial", failed: ["claude"] });
  }, 20_000);

  it("install --yes then status and uninstall work against a temp home", () => {
    const home = temp();
    const installed = suica(home, "install", "--yes", "--json");
    expect(installed.status).toBe(0);
    expect(JSON.parse(installed.stdout)).toMatchObject({ version: 1, status: "installed" });
    expect(readFileSync(join(home, ".claude", "settings.json"), "utf8")).toContain(
      "lessons-hook.ts",
    );
    expect(JSON.parse(suica(home, "status", "--json").stdout)).toMatchObject({
      version: 1,
      hook: true,
      mcp: { claude: false, codex: false },
    });
    const removed = suica(home, "uninstall", "--json");
    expect(removed.status).toBe(0);
    expect(readFileSync(join(home, ".claude", "settings.json"), "utf8")).not.toContain(
      "lessons-hook.ts",
    );
  }, 20_000);
});

describe("fix round 1", () => {
  const mention = { type: "command", command: "grep -r lessons-hook.ts ~/notes" };

  it("a user hook that merely mentions the file name survives install and uninstall", () => {
    const before = JSON.stringify({ hooks: { SessionStart: [{ hooks: [mention] }] } });
    const installed = installHooks(before, COMMAND);
    expect(installed).toContain("grep -r lessons-hook.ts");
    const back = JSON.parse(uninstallHooks(installed, COMMAND)) as object;
    expect(back).toEqual({ hooks: { SessionStart: [{ hooks: [mention] }] } });
  });

  it("our previous entry with a different install path is replaced", () => {
    const old = installHooks(undefined, '"/old dir/node" "/old dir/src/lessons-hook.ts"');
    const text = installHooks(old, hookCommand(paths));
    expect(text).not.toContain("old dir");
    expect(text.split("lessons-hook.ts").length - 1).toBe(3);
    const gone = JSON.parse(uninstallHooks(old, hookCommand(paths))) as object;
    expect(gone).toEqual({});
  });

  it("never merges into a user's group, and uninstall leaves their empty structures alone", () => {
    const user = { type: "command", command: "echo hi" };
    const before = {
      hooks: {
        PostToolUse: [
          { matcher: "Read", hooks: [user] },
          { matcher: "Read", hooks: [] },
        ],
        Stop: [],
      },
      model: "opus",
    };
    const installed = JSON.parse(installHooks(JSON.stringify(before), COMMAND)) as typeof before;
    expect(installed.hooks.PostToolUse[0]).toEqual({ matcher: "Read", hooks: [user] });
    expect(installed.hooks.PostToolUse).toHaveLength(3);
    expect(JSON.parse(uninstallHooks(JSON.stringify(installed), COMMAND))).toEqual(before);
  });

  it("uninstall removes our entry from a mixed group left by an older install", () => {
    const user = { type: "command", command: "echo hi" };
    const text = JSON.stringify({ hooks: { SessionStart: [{ hooks: [user, ours] }] } });
    expect(JSON.parse(uninstallHooks(text, COMMAND))).toEqual({
      hooks: { SessionStart: [{ hooks: [user] }] },
    });
  });

  it("quotes paths with spaces, quotes, dollars and backticks so they round-trip", () => {
    const odd: LessonsPaths = {
      node: "/a b/it's/node",
      cli: "/c",
      hook: '/x "y" $HOME `z`/it\'s/src/lessons-hook.ts',
    };
    const command = hookCommand(odd);
    expect(command).toBe("'/a b/it'\\''s/node' '/x \"y\" $HOME `z`/it'\\''s/src/lessons-hook.ts'");
    const once = installHooks(undefined, command);
    expect(installHooks(once, command)).toBe(once);
    const moved = installHooks(once, hookCommand(paths));
    expect(moved.split("lessons-hook.ts").length - 1).toBe(3);
    expect(moved).not.toContain("$HOME");
    expect(JSON.parse(uninstallHooks(once, command))).toEqual({});
  });

  it("round-trips a typical file to the same JSON value", () => {
    const typical = {
      model: "opus",
      permissions: { allow: ["Bash(ls)"] },
      hooks: { Stop: [{ hooks: [{ type: "command", command: "x" }] }] },
    };
    const text = installHooks(JSON.stringify(typical, null, 2) + "\n", hookCommand(paths));
    expect(JSON.parse(uninstallHooks(text, hookCommand(paths)))).toEqual(typical);
  });

  it("writes through a symlinked settings.json and keeps the link", () => {
    const home = temp();
    mkdirSync(join(home, ".claude"));
    mkdirSync(join(home, "dotfiles"));
    const target = join(home, "dotfiles", "settings.json");
    writeFileSync(target, '{"model":"opus"}\n');
    chmodSync(target, 0o640);
    const link = join(home, ".claude", "settings.json");
    symlinkSync(target, link);
    writeSettingsAtomic(link, '{"new":1}\n');
    expect(lstatSync(link).isSymbolicLink()).toBe(true);
    expect(readlinkSync(link)).toBe(target);
    expect(readFileSync(target, "utf8")).toBe('{"new":1}\n');
    expect(statSync(target).mode & 0o777).toBe(0o640);
    expect(readdirSync(join(home, "dotfiles"))).toEqual(["settings.json"]);
  });

  it("treats a dangling symlink as an error and writes nothing", async () => {
    const home = temp();
    mkdirSync(join(home, ".claude"));
    const link = join(home, ".claude", "settings.json");
    symlinkSync(join(home, "missing.json"), link);
    const { exec, calls } = recorder();
    const result = await applyInstall(home, exec, [cli("claude", true)], paths);
    expect(result.status).toBe("invalid-settings");
    expect(existsSync(join(home, "missing.json"))).toBe(false);
    expect(calls).toEqual([]);
    expect((await applyUninstall(home, exec, [], paths)).status).toBe("invalid-settings");
  });

  it("an unreadable settings path (a folder) is an error result, not a crash", async () => {
    const home = temp();
    mkdirSync(join(home, ".claude", "settings.json"), { recursive: true });
    const result = await applyInstall(home, recorder().exec, [], paths);
    expect(result.status).toBe("unreadable-settings");
    expect((await applyUninstall(home, recorder().exec, [], paths)).status).toBe(
      "unreadable-settings",
    );
  });

  it("uninstall ignores not-found removes but reports other failures as partial", async () => {
    const home = temp();
    const notFound: Exec = () =>
      Promise.reject(
        Object.assign(new Error("Command failed"), {
          stderr: "No MCP server found with name: suica-lessons",
        }),
      );
    const clean = await applyUninstall(home, notFound, [cli("claude", true)], paths);
    expect(clean).toMatchObject({ status: "uninstalled", failed: [] });
    const broken: Exec = () =>
      Promise.reject(Object.assign(new Error("Command failed"), { stderr: "permission denied" }));
    const bad = await applyUninstall(
      home,
      broken,
      [cli("claude", true), cli("codex", true)],
      paths,
    );
    expect(bad).toMatchObject({ status: "partial", failed: ["claude", "codex"] });
  });

  it("the plan lists the removes before each add, the file and the reformatting note", () => {
    const plan = planInstall("/h", [cli("claude", true), cli("codex", true)], paths);
    expect(plan.commands).toEqual([
      "claude mcp remove --scope user suica-lessons",
      "claude mcp add --scope user suica-lessons -- /n/node /i/src/cli.ts lessons mcp",
      "codex mcp remove suica-lessons",
      "codex mcp add suica-lessons -- /n/node /i/src/cli.ts lessons mcp",
    ]);
    expect(plan.note).toMatch(/formatted JSON/);
  });

  it("status ignores a differently named server", async () => {
    const list: Exec = () => Promise.resolve({ stdout: "suica-lessons-old: x\n", stderr: "" });
    expect((await lessonsStatus(temp(), list, [cli("claude", true)], paths)).mcp.claude).toBe(
      false,
    );
  });
});
