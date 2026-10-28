import { generateKeyPairSync, sign } from "node:crypto";
import { spawn } from "node:child_process";
import { readFileSync, existsSync, mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import type { Server } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { VERSION } from "../src/version.ts";

type Golden = { check: Record<string, object>; apply: Record<string, object> };
const golden = JSON.parse(readFileSync("contracts/update.v1.json", "utf8")) as Golden;

const { publicKey, privateKey } = generateKeyPairSync("ed25519");
let server: Server;
// Far ahead of the real version, so a version bump of the package never turns this fixture into "up to date".
const LATEST = "99.0.0";
let home: string;
let base: string;

beforeEach(async () => {
  home = mkdtempSync(join(tmpdir(), "suica-update-cli-"));
  server = createServer();
  await new Promise<void>((done) => server.listen(0, "127.0.0.1", done));
  base = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
  const manifest = JSON.stringify({
    version: LATEST,
    arch: process.arch,
    url: `${base}/download/v${LATEST}/suica.tar.gz`,
    sha256: "0".repeat(64),
  });
  server.on("request", (req, res) => {
    if (req.url?.endsWith("latest.json")) res.end(manifest);
    else if (req.url?.endsWith("latest.json.sig"))
      res.end(sign(null, Buffer.from(manifest), privateKey).toString("base64"));
    else res.end("not the tarball the manifest promised");
  });
});
afterEach(() => {
  server.close();
  rmSync(home, { recursive: true, force: true });
});

// Async spawn: the local server lives in this process, so a sync spawn would deadlock it.
function suica(...args: string[]): Promise<{ status: number | null; stdout: string }> {
  return new Promise((done) => {
    const child = spawn("node", ["src/cli.ts", ...args], {
      env: {
        ...process.env,
        HOME: home,
        NODE_ENV: "test",
        SUICA_UPDATE_BASE_URL: base,
        SUICA_UPDATE_PUBLIC_KEY: publicKey.export({ type: "spki", format: "pem" }).toString(),
      },
    });
    let stdout = "";
    child.stdout.on("data", (chunk: Buffer) => (stdout += chunk.toString()));
    child.on("close", (status) => done({ status, stdout }));
  });
}

describe("suica update --json", () => {
  it("check prints the golden available document", async () => {
    const out = await suica("update", "check", "--json");
    expect(out.status).toBe(0);
    expect(JSON.parse(out.stdout)).toEqual({
      ...golden.check["available"],
      current: VERSION,
      latest: LATEST,
    });
  }, 20_000);

  it("apply fails cleanly for a tampered tarball and stages nothing", async () => {
    const out = await suica("update", "apply", "--json");
    expect(out.status).toBe(0);
    const doc = JSON.parse(out.stdout) as { version: number; status: string; message: string };
    expect(doc).toEqual({ ...golden.apply["failed"], message: doc.message });
    expect(doc.message).toContain("sha256");
    expect(
      existsSync(join(home, "Library", "Application Support", "Suica", "update", "staged")),
    ).toBe(false);
  }, 20_000);
});
