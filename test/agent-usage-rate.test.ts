import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { loadRate } from "../src/agent-usage/rate.ts";

interface Saved {
  perUsd: number;
}
const URL = "https://api.frankfurter.dev/v1/latest?from=USD&to=IDR";
const NOW = Date.UTC(2026, 10, 4, 12);
const HOUR = 3_600_000;

const reply = (res: () => Response) => vi.fn<typeof fetch>(() => Promise.resolve(res()));
const ok = (body: unknown) => reply(() => new Response(JSON.stringify(body), { status: 200 }));
const offline = () => vi.fn<typeof fetch>(() => Promise.reject(new Error("offline")));
const good = { amount: 1, base: "USD", date: "2026-11-03", rates: { IDR: 16000 } };

async function setup(saved?: unknown): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "rate-"));
  const path = join(dir, "exchange-rate.json");
  if (saved !== undefined) {
    await writeFile(path, typeof saved === "string" ? saved : JSON.stringify(saved));
  }
  return path;
}

const save = (ageHours: number, perUsd = 15000) => ({
  perUsd,
  date: "2026-11-02",
  fetchedAt: NOW - ageHours * HOUR,
});

describe("loadRate", () => {
  it("uses a fresh save without fetching", async () => {
    const fetch = ok(good);
    const path = await setup(save(23));
    expect(await loadRate({ path, now: NOW, fetch })).toEqual({
      currency: "IDR",
      perUsd: 15000,
      date: "2026-11-02",
      stale: false,
    });
    expect(fetch).not.toHaveBeenCalled();
  });

  it("fetches when the save is old, and saves the new rate", async () => {
    const fetch = ok(good);
    const path = await setup(save(25));
    expect(await loadRate({ path, now: NOW, fetch })).toEqual({
      currency: "IDR",
      perUsd: 16000,
      date: "2026-11-03",
      stale: false,
    });
    expect(JSON.parse(await readFile(path, "utf8"))).toEqual({
      perUsd: 16000,
      date: "2026-11-03",
      fetchedAt: NOW,
    });
  });

  it("calls the constant URL with an abort signal", async () => {
    const fetch = ok(good);
    await loadRate({ path: await setup(), now: NOW, fetch });
    expect(fetch).toHaveBeenCalledWith(URL, { signal: expect.any(AbortSignal) as AbortSignal });
  });

  const failures: [string, typeof fetch][] = [
    ["a thrown error", offline()],
    ["HTTP 500", reply(() => new Response("{}", { status: 500 }))],
    ["non-JSON", reply(() => new Response("<html>", { status: 200 }))],
    ["rates.IDR missing", ok({ date: "2026-11-03", rates: {} })],
    ["rates missing", ok({ date: "2026-11-03" })],
    ["rates.IDR 0", ok({ date: "2026-11-03", rates: { IDR: 0 } })],
    ["rates.IDR -1", ok({ date: "2026-11-03", rates: { IDR: -1 } })],
    ["rates.IDR NaN", ok({ date: "2026-11-03", rates: { IDR: Number.NaN } })],
    ["rates.IDR a string", ok({ date: "2026-11-03", rates: { IDR: "16000" } })],
  ];

  it.each(failures)("falls back to the old save, stale, on %s", async (_name, fetch) => {
    const path = await setup(save(30));
    expect(await loadRate({ path, now: NOW, fetch })).toEqual({
      currency: "IDR",
      perUsd: 15000,
      date: "2026-11-02",
      stale: true,
    });
    // the bad response must not overwrite the save
    expect((JSON.parse(await readFile(path, "utf8")) as Saved).perUsd).toBe(15000);
  });

  it.each(failures)("returns null with no save, on %s", async (_name, fetch) => {
    expect(await loadRate({ path: await setup(), now: NOW, fetch })).toBeNull();
  });

  it.each([
    ["corrupt", "{not json"],
    ["perUsd 0", save(1, 0)],
    ["perUsd -5", save(1, -5)],
    ["perUsd a string", { ...save(1), perUsd: "15000" }],
    ["fetchedAt missing", { perUsd: 15000, date: "2026-11-02" }],
  ])("counts a %s save as no save", async (_name, saved) => {
    expect(await loadRate({ path: await setup(saved), now: NOW, fetch: offline() })).toBeNull();
    const fetch = ok(good);
    expect((await loadRate({ path: await setup(saved), now: NOW, fetch }))?.perUsd).toBe(16000);
    expect(fetch).toHaveBeenCalledOnce();
  });

  it("still returns the fetched rate when the save cannot be written", async () => {
    const dir = await mkdtemp(join(tmpdir(), "rate-"));
    const blocker = join(dir, "file");
    await writeFile(blocker, "x");
    // the parent is a file, so mkdir and write both fail
    const path = join(blocker, "exchange-rate.json");
    expect(await loadRate({ path, now: NOW, fetch: ok(good) })).toEqual({
      currency: "IDR",
      perUsd: 16000,
      date: "2026-11-03",
      stale: false,
    });
  });

  it("creates the directory for the save", async () => {
    const dir = await mkdtemp(join(tmpdir(), "rate-"));
    const path = join(dir, "nested", "exchange-rate.json");
    await loadRate({ path, now: NOW, fetch: ok(good) });
    expect((JSON.parse(await readFile(path, "utf8")) as Saved).perUsd).toBe(16000);
  });
});
