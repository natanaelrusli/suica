import { createHash, verify } from "node:crypto";
import { cp, mkdir, mkdtemp, readFile, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { z } from "zod";

const ManifestSchema = z.object({
  version: z.string(),
  arch: z.string(),
  url: z.string(),
  sha256: z.string(),
});
export type Manifest = z.infer<typeof ManifestSchema>;

const DEFAULT_BASE_URL = "https://github.com/natanaelrusli/suica/releases";
const DEFAULT_PREFIX = `${DEFAULT_BASE_URL}/download/`;

/** Numeric x.y.z compare; a missing or non-numeric part counts as 0. */
export function isNewer(latest: string, current: string): boolean {
  const a = latest.split(".").map(Number);
  const b = current.split(".").map(Number);
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const d = (a[i] || 0) - (b[i] || 0);
    if (d !== 0) return d > 0;
  }
  return false;
}

export function verifyManifest(
  manifestText: string,
  signatureB64: string,
  publicKeyPem: string,
  allowedPrefix: string = DEFAULT_PREFIX,
): Manifest {
  const ok = verify(
    null,
    Buffer.from(manifestText),
    publicKeyPem,
    Buffer.from(signatureB64, "base64"),
  );
  if (!ok) throw new Error("manifest signature is invalid");
  const manifest = ManifestSchema.parse(JSON.parse(manifestText));
  // The normalized href, so `..` and `%2e%2e` segments cannot climb out of the prefix.
  if (!URL.canParse(manifest.url) || !new URL(manifest.url).href.startsWith(allowedPrefix))
    throw new Error("manifest url is outside the release host");
  return manifest;
}

export type CheckResult =
  | { status: "up-to-date"; current: string }
  | { status: "available"; current: string; latest: string }
  | { status: "unavailable"; message: string };

type CheckDeps = {
  fetch: typeof fetch;
  current: string;
  arch: string;
  publicKeyPem: string;
  baseUrl?: string;
};

async function fetchOk(deps: CheckDeps, url: string, timeoutMs: number): Promise<Response> {
  const res = await deps.fetch(url, { signal: AbortSignal.timeout(timeoutMs) });
  if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
  return res;
}

/** The verified manifest of the latest release for this arch; throws if it cannot be trusted. */
async function latestManifest(deps: CheckDeps): Promise<Manifest> {
  const baseUrl = deps.baseUrl ?? DEFAULT_BASE_URL;
  const get = async (url: string): Promise<string> => (await fetchOk(deps, url, 15_000)).text();
  const [text, sig] = await Promise.all([
    get(`${baseUrl}/latest/download/latest.json`),
    get(`${baseUrl}/latest/download/latest.json.sig`),
  ]);
  const m = verifyManifest(text, sig.trim(), deps.publicKeyPem, `${baseUrl}/download/`);
  if (m.arch !== deps.arch) throw new Error(`no ${deps.arch} build in the latest release`);
  return m;
}

export async function checkForUpdate(deps: CheckDeps): Promise<CheckResult> {
  try {
    const m = await latestManifest(deps);
    return isNewer(m.version, deps.current)
      ? { status: "available", current: deps.current, latest: m.version }
      : { status: "up-to-date", current: deps.current };
  } catch (e) {
    return { status: "unavailable", message: e instanceof Error ? e.message : String(e) };
  }
}

export type ApplyResult =
  | { status: "staged"; release: string; staged: string; target: string; swapScript: string }
  | { status: "up-to-date" }
  | { status: "failed"; message: string };

type Run = (cmd: string, args: string[], env?: Record<string, string>) => Promise<void>;

/**
 * Downloads and verifies the latest release, installs its CLI (atomic, so a failure before that
 * step changes nothing) and stages the new app next to a copy of swap-app.sh. The caller then runs
 * the swap script detached and quits; see scripts/swap-app.sh.
 */
export async function applyUpdate(
  deps: CheckDeps & { run: Run; home: string; execPath: string; prefix: string },
): Promise<ApplyResult> {
  const updateDir = join(deps.home, "Library", "Application Support", "Suica", "update");
  const stagedDir = join(updateDir, "staged");
  let tmp: string | undefined;
  try {
    const m = await latestManifest(deps);
    const result = (): ApplyResult => ({
      status: "staged",
      release: m.version,
      staged: join(stagedDir, "Suica.app"),
      target: join(deps.home, "Applications", "Suica.app"),
      swapScript: join(stagedDir, "swap-app.sh"),
    });
    if (!isNewer(m.version, deps.current)) {
      // The CLI is replaced last, so a staged app of the current version means the swap never
      // happened: offer it again. Any other staged app is stale.
      const plist = await readFile(
        join(stagedDir, "Suica.app", "Contents", "Info.plist"),
        "utf8",
      ).catch(() => "");
      const staged = /CFBundleShortVersionString<\/key>\s*<string>([^<]*)</.exec(plist)?.[1];
      if (staged === deps.current) return result();
      await rm(stagedDir, { recursive: true, force: true });
      return { status: "up-to-date" };
    }
    const bytes = Buffer.from(await (await fetchOk(deps, m.url, 120_000)).arrayBuffer());
    if (createHash("sha256").update(bytes).digest("hex") !== m.sha256.toLowerCase())
      throw new Error("downloaded release does not match its sha256");

    await mkdir(updateDir, { recursive: true });
    tmp = await mkdtemp(join(updateDir, "tmp-"));
    const archive = join(tmp, "suica.tar.gz");
    const out = join(tmp, "release");
    await mkdir(out);
    await writeFile(archive, bytes);
    await deps.run("tar", ["-xzf", archive, "-C", out]);

    // The CLI goes last: it is the one step that changes the machine, so a failure before it
    // leaves the old CLI and old app together. finish-app.sh only needs the CLI's path.
    const app = join(out, "Suica.app");
    await deps.run("sh", [
      join(out, "scripts", "finish-app.sh"),
      app,
      join(deps.prefix, "bin", "suica"),
    ]);

    // The swap script outlives the temp dir, so it is staged beside the app.
    await rm(stagedDir, { recursive: true, force: true });
    await mkdir(stagedDir);
    await cp(join(out, "scripts", "swap-app.sh"), join(stagedDir, "swap-app.sh"));
    await rename(app, join(stagedDir, "Suica.app"));
    await deps.run("sh", [join(out, "scripts", "install-cli.sh")], {
      SUICA_NODE: deps.execPath,
      SUICA_PREFIX: deps.prefix,
    });
    return result();
  } catch (e) {
    await rm(stagedDir, { recursive: true, force: true });
    return { status: "failed", message: e instanceof Error ? e.message : String(e) };
  } finally {
    if (tmp) await rm(tmp, { recursive: true, force: true });
  }
}
