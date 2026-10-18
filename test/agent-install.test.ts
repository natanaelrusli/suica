import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { installAgent, plistPath, renderPlist, uninstallAgent } from "../src/agent-install.ts";
import { AGENT_LABEL } from "../src/agent-status.ts";
import type { Exec } from "../src/exec.ts";

const folders: string[] = [];
afterEach(() => {
  for (const folder of folders.splice(0)) rmSync(folder, { recursive: true, force: true });
});

function home(): string {
  const folder = mkdtempSync(join(tmpdir(), "suica-agent-"));
  folders.push(folder);
  return folder;
}

/** Records every launchctl call; the subcommands in `failing` throw. */
function fakeExec(failing: readonly string[] = []): { exec: Exec; calls: string[][] } {
  const calls: string[][] = [];
  const exec: Exec = (file, args) => {
    calls.push([file, ...args]);
    if (failing.includes(args[0] ?? "")) return Promise.reject(new Error("exit 5"));
    return Promise.resolve({ stdout: "", stderr: "" });
  };
  return { exec, calls };
}

const paths = (homePath: string) => ({
  node: "/opt/homebrew/bin/node",
  main: `${homePath}/.local/lib/suica/src/main.ts`,
  home: homePath,
});

describe("renderPlist", () => {
  it("runs this installation's main.ts with its node, from the installation folder", () => {
    const plist = renderPlist(paths("/Users/me"));
    expect(plist).toContain("<string>/opt/homebrew/bin/node</string>");
    expect(plist).toContain("<string>/Users/me/.local/lib/suica/src/main.ts</string>");
    expect(plist).toContain(
      "<key>WorkingDirectory</key><string>/Users/me/.local/lib/suica</string>",
    );
    expect(plist).toContain("<string>/Users/me/Library/Logs/suica/stderr.log</string>");
    expect(plist).toContain(`<key>Label</key><string>${AGENT_LABEL}</string>`);
  });

  it("escapes paths so the plist stays valid XML", () => {
    const plist = renderPlist({ ...paths("/Users/a&b"), main: "/opt/<x>/src/main.ts" });
    expect(plist).toContain("/Users/a&amp;b/Library/Logs");
    expect(plist).toContain("/opt/&lt;x&gt;/src/main.ts");
    expect(plist).not.toContain("a&b");
  });

  it("is a property list plutil accepts", () => {
    const folder = home();
    const file = join(folder, "agent.plist");
    writeFileSync(file, renderPlist(paths("/Users/a&b c")));
    const lint = spawnSync("plutil", ["-lint", file], { encoding: "utf8" });
    // plutil exists only on macOS; elsewhere the XML checks above are all there is.
    if (lint.error === undefined) expect(lint.status, lint.stdout).toBe(0);
  });
});

describe("installAgent", () => {
  it("refuses without a config file and touches nothing", async () => {
    const folder = home();
    const { exec, calls } = fakeExec();
    expect(await installAgent(exec, 501, paths(folder), join(folder, "missing.yaml"))).toBe(
      "no-config",
    );
    expect(calls).toEqual([]);
    expect(existsSync(plistPath(folder))).toBe(false);
  });

  it("writes the plist, then reloads it; RunAtLoad starts it, so there is no kickstart", async () => {
    const folder = home();
    const config = join(folder, "config.yaml");
    writeFileSync(config, "gitlab:\n  hostname: x\n");
    const { exec, calls } = fakeExec(["bootout"]);
    expect(await installAgent(exec, 501, paths(folder), config)).toBe("installed");
    expect(readFileSync(plistPath(folder), "utf8")).toBe(renderPlist(paths(folder)));
    expect(existsSync(join(folder, "Library", "Logs", "suica"))).toBe(true);
    expect(calls).toEqual([
      ["launchctl", "bootout", `gui/501/${AGENT_LABEL}`],
      ["launchctl", "bootstrap", "gui/501", plistPath(folder)],
    ]);
  });

  it("waits for a loaded agent to be gone before loading it again", async () => {
    const folder = home();
    const config = join(folder, "config.yaml");
    writeFileSync(config, "");
    // bootout returns at once, but launchd still lists the old agent for two more checks.
    const calls: string[] = [];
    let listed = 2;
    const exec: Exec = (_file, args) => {
      calls.push(args[0] ?? "");
      if (args[0] === "print" && listed-- <= 0) return Promise.reject(new Error("exit 113"));
      if (args[0] === "bootstrap" && listed >= 0) return Promise.reject(new Error("exit 5"));
      return Promise.resolve({ stdout: "", stderr: "" });
    };
    const naps: number[] = [];
    const nap = (ms: number) => {
      naps.push(ms);
      return Promise.resolve();
    };
    expect(await installAgent(exec, 501, paths(folder), config, nap)).toBe("installed");
    expect(calls).toEqual(["bootout", "print", "print", "print", "bootstrap"]);
    expect(naps).toEqual([200, 200]);
  });

  it("gives up waiting after about five seconds and still tries to load it", async () => {
    const folder = home();
    const config = join(folder, "config.yaml");
    writeFileSync(config, "");
    const { exec, calls } = fakeExec(["bootstrap"]);
    const nap = () => Promise.resolve();
    expect(await installAgent(exec, 501, paths(folder), config, nap)).toBe("failed");
    expect(calls.filter((call) => call[1] === "print")).toHaveLength(25);
    expect(calls.at(-1)?.[1]).toBe("bootstrap");
  });

  it("reports failed when launchctl cannot load it", async () => {
    const folder = home();
    const config = join(folder, "config.yaml");
    writeFileSync(config, "");
    const { exec } = fakeExec(["print", "bootstrap"]);
    expect(await installAgent(exec, 501, paths(folder), config)).toBe("failed");
  });
});

describe("uninstallAgent", () => {
  it("unloads and removes the plist, and says when there was none", async () => {
    const folder = home();
    const config = join(folder, "config.yaml");
    writeFileSync(config, "");
    await installAgent(fakeExec(["print"]).exec, 501, paths(folder), config);
    const { exec, calls } = fakeExec(["bootout"]);
    expect(await uninstallAgent(exec, 501, folder)).toBe(true);
    expect(calls).toEqual([["launchctl", "bootout", `gui/501/${AGENT_LABEL}`]]);
    expect(existsSync(plistPath(folder))).toBe(false);
    expect(await uninstallAgent(exec, 501, folder)).toBe(false);
  });
});
