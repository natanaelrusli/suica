import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import type { Exec } from "../src/exec.ts";
import { checkGitlab } from "../src/gitlab-check.ts";
import type { GitlabCheckJson } from "../src/gitlab-check.ts";

function replying(stdout: string): { exec: Exec; calls: string[][] } {
  const calls: string[][] = [];
  const exec: Exec = (file, args, options) => {
    calls.push([file, ...args, String(options.timeoutMs)]);
    return Promise.resolve({ stdout, stderr: "" });
  };
  return { exec, calls };
}

function failing(error: Record<string, unknown>): Exec {
  return () => Promise.reject(Object.assign(new Error("exec failed"), error));
}

describe("checkGitlab", () => {
  it("asks glab for the signed-in user on the host, with a 30 s timeout", async () => {
    const { exec, calls } = replying(JSON.stringify({ username: "owner", id: 1 }));
    expect(await checkGitlab("repo.example:8443", exec)).toEqual({
      status: "ok",
      username: "owner",
    });
    expect(calls).toEqual([["glab", "api", "user", "--hostname", "repo.example:8443", "30000"]]);
  });

  it.each(["", "https://repo.example", "repo.example/group", "repo example", "-x", "a;b"])(
    "refuses %j as a host without running glab",
    async (host) => {
      const { exec, calls } = replying("{}");
      expect(await checkGitlab(host, exec)).toEqual({ status: "bad-host", username: null });
      expect(calls).toEqual([]);
    },
  );

  it.each([
    [{ code: "ENOENT" }, "glab-missing"],
    [{ code: 1, stderr: "401 Unauthorized" }, "gitlab-auth"],
    [{ code: 1, stderr: "dial tcp: lookup repo.example: no such host" }, "gitlab-unreachable"],
    [{ code: 1, stderr: "boom" }, "gitlab-error"],
  ])("reports %j as %s", async (error, status) => {
    expect(await checkGitlab("repo.example", failing(error))).toEqual({ status, username: null });
  });

  it("reports an unexpected reply as gitlab-error", async () => {
    const { exec } = replying(JSON.stringify({ nope: true }));
    expect((await checkGitlab("repo.example", exec)).status).toBe("gitlab-error");
  });

  it("matches the golden contract's shape", () => {
    const golden = JSON.parse(readFileSync("contracts/gitlab-check.v1.json", "utf8")) as object;
    const sample: GitlabCheckJson = { status: "ok", username: "owner" };
    expect(Object.keys(golden).sort()).toEqual(Object.keys(sample).sort());
  });
});

const folders: string[] = [];
afterEach(() => {
  for (const folder of folders.splice(0)) rmSync(folder, { recursive: true, force: true });
});

describe("suica gitlab check --json", () => {
  it("prints one JSON line and exits 1 for a bad host, without a config file", () => {
    const folder = mkdtempSync(join(tmpdir(), "suica-gitlab-check-"));
    folders.push(folder);
    const result = spawnSync("node", ["src/cli.ts", "gitlab", "check", "not a host", "--json"], {
      encoding: "utf8",
      env: { ...process.env, SUICA_CONFIG: join(folder, "missing.yaml") },
    });
    expect(result.status).toBe(1);
    expect(JSON.parse(result.stdout)).toEqual({ status: "bad-host", username: null });
  });
});

describe("suica agent install --json", () => {
  it("prints no-config and exits 1 when there is no config file, installing nothing", () => {
    const folder = mkdtempSync(join(tmpdir(), "suica-install-json-"));
    folders.push(folder);
    const result = spawnSync("node", ["src/cli.ts", "agent", "install", "--json"], {
      encoding: "utf8",
      env: { ...process.env, SUICA_CONFIG: join(folder, "missing.yaml") },
    });
    expect(result.status).toBe(1);
    expect(JSON.parse(result.stdout)).toEqual({ status: "no-config" });
  });
});
