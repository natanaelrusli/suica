import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { verifyManifest } from "../src/update.ts";

const REPO = join(import.meta.dirname, "..");
const dirs: string[] = [];
function tmp(): string {
  const d = mkdtempSync(join(tmpdir(), "suica-release-"));
  dirs.push(d);
  return d;
}
afterEach(() => {
  for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true });
});

function node(script: string, args: string[], key: string) {
  return spawnSync("node", [join(REPO, "scripts", script), ...args], {
    encoding: "utf8",
    env: { ...process.env, SUICA_RELEASE_KEY: key },
  });
}

function keygen(): { key: string; pem: string } {
  const key = join(tmp(), "cfg", "release-key.pem");
  const r = node("release-keygen.ts", [], key);
  expect(r.status).toBe(0);
  return { key, pem: r.stdout };
}

describe("release-keygen", () => {
  it("writes a 0600 key in a 0700 dir, prints the public key, never overwrites", () => {
    const { key, pem } = keygen();
    expect(pem).toContain("BEGIN PUBLIC KEY");
    expect(statSync(key).mode & 0o777).toBe(0o600);
    expect(statSync(join(key, "..")).mode & 0o777).toBe(0o700);
    const before = readFileSync(key, "utf8");
    const again = node("release-keygen.ts", [], key);
    expect(again.status).toBe(1);
    expect(again.stdout).toBe("");
    expect(readFileSync(key, "utf8")).toBe(before);
  });
});

describe("release-sign", () => {
  it("signs a manifest that verifyManifest accepts, and rejects a tampered one", () => {
    const { key, pem } = keygen();
    const dir = tmp();
    const tarball = join(dir, "suica-1.2.3-arm64.tar.gz");
    writeFileSync(tarball, "fake tarball bytes");
    expect(node("release-sign.ts", [tarball, "1.2.3", "arm64"], key).status).toBe(0);

    const text = readFileSync(join(dir, "latest.json"), "utf8");
    const sig = readFileSync(join(dir, "latest.json.sig"), "utf8");
    const m = verifyManifest(text, sig, pem);
    expect(m).toEqual({
      version: "1.2.3",
      arch: "arm64",
      url: "https://github.com/natanaelrusli/suica/releases/download/v1.2.3/suica-1.2.3-arm64.tar.gz",
      sha256: createHash("sha256").update(readFileSync(tarball)).digest("hex"),
    });
    expect(() => verifyManifest(text.replace("1.2.3", "9.9.9"), sig, pem)).toThrow(/signature/);
  });
});

describe("pack-release", () => {
  it("lays out exactly what applyUpdate unpacks", () => {
    const app = join(tmp(), "Whatever.app");
    mkdirSync(join(app, "Contents"), { recursive: true });
    writeFileSync(join(app, "Contents", "Info.plist"), "x");
    const tarball = join(tmp(), "out.tar.gz");
    execFileSync(join(REPO, "scripts", "pack-release.sh"), [app, tarball]);
    const list = execFileSync("tar", ["-tzf", tarball], { encoding: "utf8" }).split("\n");
    const top = new Set(list.filter(Boolean).map((p) => p.replace(/^\.\//, "").split("/")[0]));
    expect([...top].sort()).toEqual(
      ["Suica.app", "package-lock.json", "package.json", "scripts", "src"].sort(),
    );
    for (const f of ["install-cli", "finish-app", "swap-app"])
      expect(list).toContain(`scripts/${f}.sh`);
    expect(list).toContain("Suica.app/Contents/Info.plist");
  });
});

describe("release.sh", { timeout: 20_000 }, () => {
  // A throwaway repo holding copies of the release scripts and a fake build-app.sh (no swift).
  function throwaway(): string {
    const repo = tmp();
    mkdirSync(join(repo, "scripts"));
    for (const f of ["release.sh", "pack-release.sh", "release-sign.ts", "release-verify.ts"])
      copyFileSync(join(REPO, "scripts", f), join(repo, "scripts", f));
    writeFileSync(
      join(repo, "scripts", "build-app.sh"),
      '#!/bin/sh\nmkdir -p "$OUT_APP/Contents" && echo x > "$OUT_APP/Contents/Info.plist"\n',
    );
    for (const f of ["release.sh", "pack-release.sh", "build-app.sh"])
      chmodSync(join(repo, "scripts", f), 0o755);
    mkdirSync(join(repo, "src"));
    writeFileSync(join(repo, "src", "a.ts"), "");
    for (const f of ["update.ts", "update-key.ts"])
      copyFileSync(join(REPO, "src", f), join(repo, "src", f));
    // The copied src/update.ts needs zod; the ignore keeps the symlink from dirtying the tree.
    symlinkSync(join(REPO, "node_modules"), join(repo, "node_modules"));
    writeFileSync(join(repo, ".gitignore"), "node_modules\n");
    writeFileSync(join(repo, "package.json"), '{"type":"module","version":"3.4.5"}');
    writeFileSync(join(repo, "package-lock.json"), "{}");
    const git = (...a: string[]) => execFileSync("git", ["-C", repo, ...a], { stdio: "pipe" });
    git("init", "-q");
    git("add", "-A");
    git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init");
    return repo;
  }
  const run = (repo: string, key: string, env: Record<string, string> = {}) =>
    spawnSync(join(repo, "scripts", "release.sh"), {
      encoding: "utf8",
      env: { ...process.env, SUICA_RELEASE_KEY: key, DRY_RUN: "1", ...env },
    });

  it("refuses a dirty worktree", () => {
    const repo = throwaway();
    writeFileSync(join(repo, "src", "a.ts"), "dirty");
    const r = run(repo, keygen().key);
    expect(r.status).toBe(1);
    expect(r.stderr).toContain("not clean");
  });

  it("refuses an existing tag", () => {
    const repo = throwaway();
    execFileSync("git", ["-C", repo, "tag", "v3.4.5"]);
    const r = run(repo, keygen().key);
    expect(r.status).toBe(1);
    expect(r.stderr).toContain("v3.4.5 already exists");
  });

  it("dry-runs build, pack and sign, and prints the gh command", () => {
    const repo = throwaway();
    const { key, pem } = keygen();
    const r = run(repo, key, { SUICA_RELEASE_VERIFY_KEY: pem });
    expect(r.status).toBe(0);
    const sha = execFileSync("git", ["-C", repo, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
    expect(r.stdout).toContain(`--target ${sha}`);
    const m =
      /DRY_RUN: gh release create v3\.4\.5 (\S+\.tar\.gz) (\S+latest\.json) (\S+\.sig)/.exec(
        r.stdout,
      );
    expect(m).not.toBeNull();
    const [, tarball = "", manifest = "", sig = ""] = m ?? [];
    dirs.push(join(tarball, ".."));
    expect(tarball).toContain("suica-3.4.5-arm64.tar.gz");
    const verified = verifyManifest(readFileSync(manifest, "utf8"), readFileSync(sig, "utf8"), pem);
    expect(verified.version).toBe("3.4.5");
    expect(verified.sha256).toBe(createHash("sha256").update(readFileSync(tarball)).digest("hex"));
  });

  it("aborts before publishing when the signing key does not match the verify key", () => {
    const r = run(throwaway(), keygen().key, { SUICA_RELEASE_VERIFY_KEY: keygen().pem });
    expect(r.status).not.toBe(0);
    expect(r.stderr).toContain("does not verify");
    expect(r.stdout).not.toContain("gh release create");
  });

  it("aborts with the embedded placeholder key", () => {
    const r = run(throwaway(), keygen().key);
    expect(r.status).not.toBe(0);
    expect(r.stdout).not.toContain("gh release create");
  });

  it("refuses an unpushed HEAD without calling gh", () => {
    const bin = tmp();
    writeFileSync(join(bin, "gh"), '#!/bin/sh\necho called > "$0.called"\nexit 99\n');
    chmodSync(join(bin, "gh"), 0o755);
    const r = run(throwaway(), keygen().key, {
      DRY_RUN: "",
      PATH: `${bin}:${process.env["PATH"] ?? ""}`,
    });
    expect(r.status).toBe(1);
    expect(r.stderr).toContain("not pushed");
    expect(existsSync(join(bin, "gh.called"))).toBe(false);
  });
});
