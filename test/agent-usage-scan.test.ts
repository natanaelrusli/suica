import { mkdir, mkdtemp, readFile, rm, stat, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { zstdCompressSync } from "node:zlib";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { PRICES_AS_OF } from "../src/agent-usage/prices.ts";
import { scanAgentUsage } from "../src/agent-usage/scan.ts";

const now = Date.parse("2026-11-04T12:00:00Z");
const DAY = 86_400_000;
const iso = (ms: number) => new Date(ms).toISOString();

const claudeLine = (at: number, id: string, input: number) =>
  JSON.stringify({
    timestamp: iso(at),
    requestId: `r-${id}`,
    message: { id, model: "claude-sonnet-5-5", usage: { input_tokens: input, output_tokens: 0 } },
  });

const codexFile = (sessionId: string, at: number, input: number, pad = "") =>
  [
    JSON.stringify({ timestamp: iso(at), type: "session_meta", payload: { id: sessionId } }),
    JSON.stringify({
      timestamp: iso(at),
      type: "event_msg",
      payload: {
        type: "token_count",
        info: {
          total_token_usage: { input_tokens: input },
          last_token_usage: { input_tokens: input },
        },
      },
    }),
    pad,
  ].join("\n");

let home: string;
let cachePath: string;
const total = (bs: { input: number }[]) => bs.reduce((n, b) => n + b.input, 0);
const hourAgo = now - 3_600_000;

/** Writes a file and sets its mtime (default: an hour before `now`). */
async function put(rel: string, body: string | Buffer, mtime = hourAgo) {
  const p = join(home, rel);
  await mkdir(dirname(p), { recursive: true });
  await writeFile(p, body);
  await utimes(p, mtime / 1000, mtime / 1000);
  return p;
}
const savedFiles = async () =>
  (JSON.parse(await readFile(cachePath, "utf8")) as { files: object }).files;
const scan = (extra = {}) => scanAgentUsage({ home, cachePath, now, ...extra });

beforeEach(async () => {
  home = await mkdtemp(join(tmpdir(), "suica-scan-"));
  cachePath = join(home, "state", "agent-usage-cache.json");
});
afterEach(() => rm(home, { recursive: true, force: true }));

describe("scanAgentUsage", () => {
  it("returns nothing when neither agent is installed", async () => {
    expect(await scan()).toEqual([]);
  });

  it("reads claude jsonl and codex jsonl and jsonl.zst recursively, ignoring other files", async () => {
    await put(".claude/projects/a/b/s.jsonl", claudeLine(hourAgo, "m1", 5));
    await put(".claude/projects/a/notes.txt", claudeLine(hourAgo, "m2", 1000));
    await put(".codex/sessions/2026/11/04/x.jsonl", codexFile("s1", hourAgo, 7));
    await put(
      ".codex/archived_sessions/y.jsonl.zst",
      zstdCompressSync(codexFile("s2", hourAgo, 11)),
    );
    await put(".codex/sessions/z.jsonl.bak", codexFile("s3", hourAgo, 1000));
    const out = await scan();
    expect(total(out.filter((b) => b.agent === "claude"))).toBe(5);
    expect(total(out.filter((b) => b.agent === "codex"))).toBe(18);
  });

  it("skips a file whose mtime is older than 30 days, and drops buckets older than 30 days or in the future", async () => {
    await put(".claude/projects/old.jsonl", claudeLine(hourAgo, "m1", 1), now - 31 * DAY);
    await put(
      ".claude/projects/p/s.jsonl",
      [
        claudeLine(now - 31 * DAY, "m2", 100),
        claudeLine(now + 2 * 3_600_000, "m3", 200),
        claudeLine(hourAgo, "m4", 3),
      ].join("\n"),
    );
    expect(total(await scan())).toBe(3);
  });

  it("sums the same bucket across files", async () => {
    await put(".claude/projects/a.jsonl", claudeLine(hourAgo, "m1", 2));
    await put(".claude/projects/b.jsonl", claudeLine(hourAgo, "m2", 3));
    const out = await scan();
    expect(out).toHaveLength(1);
    expect(out[0]!.input).toBe(5);
  });

  it("does not parse an unchanged file again, but does when it changes", async () => {
    const p = await put(".claude/projects/a.jsonl", claudeLine(hourAgo, "m1", 5));
    expect(total(await scan())).toBe(5);
    let reads = 0;
    const read = (path: string) => {
      reads++;
      return readFile(path);
    };
    expect(total(await scan({ read }))).toBe(5);
    expect(reads).toBe(0);
    await writeFile(p, claudeLine(hourAgo, "m1", 9)); // new size/mtime
    expect(total(await scan({ read }))).toBe(9);
    expect(reads).toBe(1);
  });

  it("drops the cache entry of a deleted file", async () => {
    const p = await put(".claude/projects/a.jsonl", claudeLine(hourAgo, "m1", 5));
    await scan();
    await rm(p);
    expect(await scan()).toEqual([]);
    expect(Object.keys(await savedFiles())).toEqual([]);
  });

  it.each([
    [
      "version 0",
      (f: object) => JSON.stringify({ version: 0, pricesAsOf: PRICES_AS_OF, files: f }),
    ],
    [
      "a different pricesAsOf",
      (f: object) => JSON.stringify({ version: 1, pricesAsOf: "2000-01-01", files: f }),
    ],
    ["invalid json", () => "{not json"],
  ])("rebuilds a cache with %s", async (_name, body) => {
    const p = await put(".claude/projects/a.jsonl", claudeLine(hourAgo, "m1", 5));
    const s = await stat(p);
    await mkdir(dirname(cachePath), { recursive: true });
    // an entry matching the file's size and mtime would win (as zero tokens) if the cache were trusted
    await writeFile(cachePath, body({ [p]: { size: s.size, mtimeMs: s.mtimeMs, buckets: [] } }));
    expect(total(await scan())).toBe(5);
    expect(JSON.parse(await readFile(cachePath, "utf8"))).toMatchObject({
      version: 1,
      pricesAsOf: PRICES_AS_OF,
    });
  });

  it("counts two codex files with the same session id once, keeping the larger", async () => {
    await put(".codex/sessions/small.jsonl", codexFile("same", hourAgo, 7));
    await put(
      ".codex/archived_sessions/big.jsonl",
      codexFile("same", hourAgo, 40, "x".repeat(500)),
    );
    await put(".codex/sessions/other.jsonl", codexFile("other", hourAgo, 1));
    expect(total(await scan())).toBe(41);
  });

  it("writes the cache after the first parsed file with saveEvery 1", async () => {
    await put(".claude/projects/a.jsonl", claudeLine(hourAgo, "m1", 1));
    await put(".claude/projects/b.jsonl", claudeLine(hourAgo, "m2", 1));
    const exists = () =>
      stat(cachePath).then(
        () => true,
        () => false,
      );
    const before: boolean[] = [];
    await scan({
      saveEvery: 1,
      read: async (path: string) => {
        before.push(await exists());
        return readFile(path);
      },
    });
    expect(before).toEqual([false, true]); // saved between file 1 and file 2, not only at the end
  });

  it("skips an unreadable zst file without caching it", async () => {
    await put(".codex/sessions/bad.jsonl.zst", "not zstd");
    expect(await scan()).toEqual([]);
    expect(await savedFiles()).toEqual({});
  });
});
