import { mkdir, readdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { zstdDecompressSync } from "node:zlib";
import { addTo, type Bucket } from "./bucket.ts";
import { readClaudeLines } from "./claude.ts";
import { readCodexLines } from "./codex.ts";
import { PRICES_AS_OF } from "./prices.ts";

export interface ScanDeps {
  readonly home: string;
  readonly cachePath: string;
  readonly now: number;
  /** Save the cache after this many newly parsed files (default 300). */
  readonly saveEvery?: number;
  /** Reads a file's bytes; defaults to `readFile`. Injected by tests to see what gets parsed. */
  readonly read?: (path: string) => Promise<Buffer>;
}

interface Entry {
  size: number;
  mtimeMs: number;
  sessionId?: string | undefined;
  buckets: Bucket[];
}

// `pricesAsOf` is part of the key because each bucket's `long` flag depends on the price table.
interface Cache {
  version: 2;
  pricesAsOf: string;
  files: Record<string, Entry>;
}

const WINDOW_MS = 30 * 86_400_000;

async function loadCache(path: string): Promise<Cache> {
  try {
    const c = JSON.parse(await readFile(path, "utf8")) as Partial<Cache> | null;
    if (
      c?.version === 2 &&
      c.pricesAsOf === PRICES_AS_OF &&
      c.files &&
      typeof c.files === "object"
    ) {
      return c as Cache;
    }
  } catch {
    // missing or corrupt: rebuild
  }
  return { version: 2, pricesAsOf: PRICES_AS_OF, files: {} };
}

/** Best effort: an unwritable cache must not lose the result, so a failure is swallowed. */
async function saveCache(path: string, cache: Cache): Promise<void> {
  const tmp = `${path}.${process.pid}.tmp`;
  try {
    await mkdir(dirname(path), { recursive: true });
    await writeFile(tmp, JSON.stringify(cache));
    await rename(tmp, path);
  } catch {
    await rm(tmp, { force: true }).catch(() => undefined);
  }
}

/** Paths under `root` ending in one of `exts`; a missing root is empty. */
async function list(root: string, exts: string[]): Promise<string[]> {
  try {
    const all = await readdir(root, { recursive: true });
    return all.filter((f) => exts.some((e) => f.endsWith(e))).map((f) => join(root, f));
  } catch {
    return [];
  }
}

/**
 * Hourly buckets for the last 30 days from Claude Code and Codex logs. Each file's buckets are cached by
 * path, size and mtime, so only new or changed files are parsed again.
 */
export async function scanAgentUsage(deps: ScanDeps): Promise<Bucket[]> {
  const { home, cachePath, now, saveEvery = 300, read = readFile } = deps;
  const cache = await loadCache(cachePath);
  const found = [
    ...(await list(join(home, ".claude", "projects"), [".jsonl"])).map((p) => ({
      p,
      claude: true,
    })),
    ...(
      await Promise.all(
        [".codex/sessions", ".codex/archived_sessions"].map((d) =>
          list(join(home, d), [".jsonl", ".jsonl.zst"]),
        ),
      )
    )
      .flat()
      .map((p) => ({ p, claude: false })),
  ].sort((a, b) => (a.p < b.p ? -1 : 1));

  const files: Record<string, Entry> = {};
  let parsed = 0;
  for (const { p, claude } of found) {
    let st;
    try {
      st = await stat(p);
    } catch {
      continue;
    }
    if (st.mtimeMs < now - WINDOW_MS) continue;
    const hit = cache.files[p];
    // a malformed entry (no buckets array) counts as a miss and is parsed again
    if (hit && hit.size === st.size && hit.mtimeMs === st.mtimeMs && Array.isArray(hit.buckets)) {
      files[p] = hit;
      continue;
    }
    try {
      const raw = await read(p);
      const lines = (p.endsWith(".zst") ? zstdDecompressSync(raw) : raw)
        .toString("utf8")
        .split("\n");
      files[p] = {
        size: st.size,
        mtimeMs: st.mtimeMs,
        ...(claude ? { buckets: readClaudeLines(lines) } : readCodexLines(lines)),
      };
    } catch {
      continue; // unreadable now; retried next run
    }
    if (++parsed % saveEvery === 0)
      await saveCache(cachePath, { ...cache, files: { ...cache.files, ...files } });
  }
  await saveCache(cachePath, { ...cache, files });

  // one Codex session can appear in several files; keep the largest (ties: the later path)
  const best = new Map<string, { p: string; size: number }>();
  for (const [p, e] of Object.entries(files)) {
    if (e.sessionId && e.size >= (best.get(e.sessionId)?.size ?? 0))
      best.set(e.sessionId, { p, size: e.size });
  }
  const merged = new Map<string, Bucket>();
  for (const [p, e] of Object.entries(files)) {
    if (e.sessionId && best.get(e.sessionId)?.p !== p) continue;
    for (const b of e.buckets) if (b.hour >= now - WINDOW_MS && b.hour <= now) addTo(merged, b);
  }
  return [...merged.values()];
}
