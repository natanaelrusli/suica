import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

// A constant: nothing from input goes into the URL.
const RATE_URL = "https://api.frankfurter.dev/v1/latest?from=USD&to=IDR";
const MAX_AGE_MS = 24 * 3_600_000;
const TIMEOUT_MS = 5_000;

export interface RateJson {
  readonly currency: "IDR";
  readonly perUsd: number;
  readonly date: string;
  readonly stale: boolean;
}

export interface RateDeps {
  readonly path: string;
  readonly now: number;
  readonly fetch: typeof fetch;
}

interface Saved {
  perUsd: number;
  date: string;
  fetchedAt: number;
}

const validRate = (r: unknown): r is number => typeof r === "number" && Number.isFinite(r) && r > 0;

/** The saved rate, or null when missing, corrupt or not a usable rate. */
async function readSaved(path: string): Promise<Saved | null> {
  try {
    const s = JSON.parse(await readFile(path, "utf8")) as Partial<Saved> | null;
    if (s && validRate(s.perUsd) && typeof s.date === "string" && Number.isFinite(s.fetchedAt)) {
      return s as Saved;
    }
  } catch {
    // missing or corrupt: counts as no save
  }
  return null;
}

/** One attempt, no retry; any bad response (HTTP error, non-JSON, unusable rate) throws. */
async function fetchRate(f: typeof fetch): Promise<{ perUsd: number; date: string }> {
  const res = await f(RATE_URL, { signal: AbortSignal.timeout(TIMEOUT_MS) });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const body = (await res.json()) as { date?: unknown; rates?: { IDR?: unknown } } | null;
  const perUsd = body?.rates?.IDR;
  if (!validRate(perUsd) || typeof body?.date !== "string") throw new Error("bad rate response");
  return { perUsd, date: body.date };
}

/** Best effort: an unwritable save must not lose the fetched rate, so a failure is swallowed. */
async function save(path: string, s: Saved): Promise<void> {
  const tmp = `${path}.${process.pid}.tmp`;
  try {
    await mkdir(dirname(path), { recursive: true });
    await writeFile(tmp, JSON.stringify(s));
    await rename(tmp, path);
  } catch {
    await rm(tmp, { force: true }).catch(() => undefined);
  }
}

/**
 * USD to IDR from the saved rate when under 24 h old, else fetched. A failed fetch falls back to the
 * saved rate marked stale; with no usable save it returns null.
 */
export async function loadRate(deps: RateDeps): Promise<RateJson | null> {
  const saved = await readSaved(deps.path);
  const age = saved ? deps.now - saved.fetchedAt : Number.POSITIVE_INFINITY;
  if (saved && age >= 0 && age < MAX_AGE_MS) {
    return { currency: "IDR", perUsd: saved.perUsd, date: saved.date, stale: false };
  }
  try {
    const { perUsd, date } = await fetchRate(deps.fetch);
    await save(deps.path, { perUsd, date, fetchedAt: deps.now });
    return { currency: "IDR", perUsd, date, stale: false };
  } catch {
    return saved ? { currency: "IDR", perUsd: saved.perUsd, date: saved.date, stale: true } : null;
  }
}
