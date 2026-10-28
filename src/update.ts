import { verify } from "node:crypto";
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
  if (!manifest.url.startsWith(allowedPrefix))
    throw new Error("manifest url is outside the release host");
  return manifest;
}

export type CheckResult =
  | { status: "up-to-date"; current: string }
  | { status: "available"; current: string; latest: string }
  | { status: "unavailable"; message: string };

export async function checkForUpdate(deps: {
  fetch: typeof fetch;
  current: string;
  arch: string;
  publicKeyPem: string;
  baseUrl?: string;
}): Promise<CheckResult> {
  const baseUrl = deps.baseUrl ?? DEFAULT_BASE_URL;
  const get = async (url: string): Promise<string> => {
    const res = await deps.fetch(url, { signal: AbortSignal.timeout(15_000) });
    if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
    return res.text();
  };
  try {
    const [text, sig] = await Promise.all([
      get(`${baseUrl}/latest/download/latest.json`),
      get(`${baseUrl}/latest/download/latest.json.sig`),
    ]);
    const m = verifyManifest(text, sig.trim(), deps.publicKeyPem, `${baseUrl}/download/`);
    if (m.arch !== deps.arch) throw new Error(`no ${deps.arch} build in the latest release`);
    return isNewer(m.version, deps.current)
      ? { status: "available", current: deps.current, latest: m.version }
      : { status: "up-to-date", current: deps.current };
  } catch (e) {
    return { status: "unavailable", message: e instanceof Error ? e.message : String(e) };
  }
}
