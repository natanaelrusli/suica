import { execFile, execFileSync } from "node:child_process";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { describe, expect, it } from "vitest";
import { applyUpdate } from "../src/update.ts";

const exec = promisify(execFile);
const BASE = "https://example.test/releases";
const TAR_URL = `${BASE}/download/v0.2.0/suica.tar.gz`;
const { publicKey, privateKey } = generateKeyPairSync("ed25519");
const pem = publicKey.export({ type: "spki", format: "pem" }).toString();

/** A release tarball whose scripts only record that they ran, in order, in $MARKS. */
function tarball(root: string): Buffer {
  const src = join(root, "src");
  mkdirSync(join(src, "Suica.app", "Contents"), { recursive: true });
  mkdirSync(join(src, "scripts"));
  const stub = (name: string, body: string) =>
    writeFileSync(join(src, "scripts", name), `#!/bin/sh\n${body}\n`, { mode: 0o755 });
  stub("install-cli.sh", 'echo "install-cli $SUICA_NODE $SUICA_PREFIX" >> "$MARKS"');
  stub("finish-app.sh", 'echo "finish-app $1 $2" >> "$MARKS"');
  stub("swap-app.sh", "true");
  const out = join(root, "suica.tar.gz");
  execFileSync("tar", ["-czf", out, "-C", src, "Suica.app", "scripts"]);
  return readFileSync(out);
}

function setup(over: { sha?: string; failCli?: boolean; url?: string } = {}) {
  const root = mkdtempSync(join(tmpdir(), "apply test-"));
  const home = join(root, "home dir");
  mkdirSync(home);
  const marks = join(root, "marks");
  const bytes = tarball(root);
  const manifest = JSON.stringify({
    version: "0.2.0",
    arch: "arm64",
    url: over.url ?? TAR_URL,
    sha256: over.sha ?? createHash("sha256").update(bytes).digest("hex"),
  });
  const sig = sign(null, Buffer.from(manifest), privateKey).toString("base64");
  const fetched: string[] = [];
  const fetchStub: typeof fetch = (input) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    fetched.push(url);
    if (url.endsWith("latest.json")) return Promise.resolve(new Response(manifest));
    if (url.endsWith(".sig")) return Promise.resolve(new Response(sig));
    return Promise.resolve(new Response(bytes));
  };
  const run = async (cmd: string, args: string[], env?: Record<string, string>) => {
    if (over.failCli && args[0]?.endsWith("install-cli.sh")) throw new Error("cli failed");
    await exec(cmd, args, { env: { ...process.env, ...env, MARKS: marks } });
  };
  const deps = {
    fetch: fetchStub,
    current: "0.1.0",
    arch: "arm64",
    publicKeyPem: pem,
    baseUrl: BASE,
    run,
    home,
    execPath: "/opt/node",
    prefix: join(home, ".local"),
  };
  return {
    deps,
    home,
    marks,
    fetched,
    stagedDir: join(home, "Library/Application Support/Suica/update/staged"),
  };
}

describe("applyUpdate", () => {
  it("stages a verified release after installing the CLI, in order", async () => {
    const { deps, home, marks, stagedDir } = setup();
    const r = await applyUpdate(deps);
    expect(r).toEqual({
      status: "staged",
      release: "0.2.0",
      staged: join(stagedDir, "Suica.app"),
      target: join(home, "Applications", "Suica.app"),
      swapScript: join(stagedDir, "swap-app.sh"),
    });
    expect(existsSync(join(stagedDir, "Suica.app", "Contents"))).toBe(true);
    expect(existsSync(r.status === "staged" ? r.swapScript : "")).toBe(true);
    const lines = readFileSync(marks, "utf8").trim().split("\n");
    expect(lines).toHaveLength(2);
    expect(lines[0]).toBe(`install-cli /opt/node ${deps.prefix}`);
    expect(lines[1]).toMatch(/^finish-app .*Suica\.app .*\/\.local\/bin\/suica$/);
    const left = readdirSync(join(home, "Library/Application Support/Suica/update"));
    expect(left).toEqual(["staged"]);
  });

  it("fails on a sha256 mismatch before running anything", async () => {
    const { deps, marks, stagedDir } = setup({ sha: "0".repeat(64) });
    const r = await applyUpdate(deps);
    expect(r.status).toBe("failed");
    expect(existsSync(marks)).toBe(false);
    expect(existsSync(stagedDir)).toBe(false);
  });

  it("leaves no staged app when the CLI install fails", async () => {
    const { deps, home, stagedDir } = setup({ failCli: true });
    const r = await applyUpdate(deps);
    expect(r).toEqual({ status: "failed", message: "cli failed" });
    expect(existsSync(stagedDir)).toBe(false);
    expect(readdirSync(join(home, "Library/Application Support/Suica/update"))).toEqual([]);
  });

  it("is up to date when the release is not newer", async () => {
    const { deps, fetched } = setup();
    expect(await applyUpdate({ ...deps, current: "0.2.0" })).toEqual({ status: "up-to-date" });
    expect(fetched.some((u) => u.endsWith("suica.tar.gz"))).toBe(false);
  });

  it("refuses a manifest url that dot-segments out of the release prefix", async () => {
    for (const url of [
      `${BASE}/download/v1/../../evil.tgz`,
      `${BASE}/download/v1/%2E%2e/%2e%2E/evil.tgz`,
    ]) {
      const { deps, fetched } = setup({ url });
      const r = await applyUpdate(deps);
      expect(r.status).toBe("failed");
      expect(fetched.some((u) => u.includes("evil"))).toBe(false);
    }
  });
});
