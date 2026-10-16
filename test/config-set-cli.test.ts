import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { SaveResultJson } from "../src/config-edit.ts";

const MINIMAL = "gitlab:\n  hostname: h\n";

let dir: string;
let path: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "suica-config-set-"));
  path = join(dir, "config.yaml");
  writeFileSync(path, MINIMAL);
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

function configSet(input: string): { status: number | null; stdout: string; stderr: string } {
  const result = spawnSync("node", ["src/cli.ts", "config", "set", "--json"], {
    input,
    encoding: "utf8",
    env: { ...process.env, SUICA_CONFIG: path },
  });
  return { status: result.status, stdout: result.stdout, stderr: result.stderr };
}

const parsed = (stdout: string): SaveResultJson => JSON.parse(stdout) as SaveResultJson;

describe("suica config set --json", () => {
  it("saves, prints one JSON line and exits 0", () => {
    const base = createHash("sha256").update(MINIMAL).digest("hex");
    const request = { baseSha256: base, edits: [{ path: ["polling", "idleSeconds"], value: 600 }] };
    const result = configSet(JSON.stringify(request));
    expect(result.status).toBe(0);
    expect(result.stdout.endsWith("\n")).toBe(true);
    expect(result.stdout.trim().split("\n")).toHaveLength(1);
    expect(parsed(result.stdout).status).toBe("saved");
    expect(readFileSync(path, "utf8")).toContain("idleSeconds: 600");
  });

  it("exits 1 with the status in the JSON when the request is rejected", () => {
    const request = { baseSha256: "0".repeat(64), edits: [] };
    const result = configSet(JSON.stringify(request));
    expect(result.status).toBe(1);
    expect(parsed(result.stdout).status).toBe("conflict");
    expect(readFileSync(path, "utf8")).toBe(MINIMAL);
  });

  it("answers bad-request for malformed input", () => {
    const result = configSet("not json");
    expect(result.status).toBe(1);
    expect(parsed(result.stdout).status).toBe("bad-request");
  });

  it("answers bad-request for more than 1 MiB on stdin, and writes nothing", () => {
    const filler = "x".repeat(1024 * 1024 + 1);
    const result = configSet(
      JSON.stringify({ baseSha256: null, edits: [{ path: ["statePath"], value: filler }] }),
    );
    expect(result.status).toBe(1);
    expect(parsed(result.stdout).status).toBe("bad-request");
    expect(readFileSync(path, "utf8")).toBe(MINIMAL);
  });

  it("accepts a request just under the limit", () => {
    const base = createHash("sha256").update(MINIMAL).digest("hex");
    const body = JSON.stringify({ baseSha256: base, edits: [] });
    const padded = `${body}${" ".repeat(1024 * 1024 - body.length)}`;
    expect(Buffer.byteLength(padded)).toBe(1024 * 1024);
    expect(parsed(configSet(padded).stdout).status).toBe("saved");
  });
});
