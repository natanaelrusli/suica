import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { cleanUp } from "../src/cleanup.ts";
import { openStore } from "../src/store.ts";
import type { Store } from "../src/store.ts";

const golden = JSON.parse(readFileSync("contracts/cleanup.v1.json", "utf8")) as object;

let root: string;
let state: string;
let store: Store;
const paths = () => ({
  statePath: join(state, "state.db"),
  logsDir: join(root, "logs"),
  updateDir: join(state, "update"),
});
const put = (path: string, bytes = 1000): void => {
  mkdirSync(join(path, ".."), { recursive: true });
  writeFileSync(path, "x".repeat(bytes));
};

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "suica-cleanup-"));
  state = join(root, "state");
  store = openStore(join(state, "state.db"));
});
afterEach(() => {
  store.close();
  rmSync(root, { recursive: true, force: true });
});

describe("cleanUp", () => {
  it("removes caches, backups, update downloads, orphan fixes and log contents; keeps the rest", () => {
    put(join(state, "agent-usage-cache.json"));
    put(join(state, "exchange-rate.json"));
    put(join(state, "state.db.before-schema7"));
    put(join(state, "update", "staged", "swap-app.sh"));
    put(join(state, "update", "tmp-abc", "suica.tar.gz"));
    put(join(state, "fixes", "42", "file"));
    put(join(state, "lessons-usage", "2026-11-04.jsonl"));
    put(join(state, "lesson-scopes.json"));
    put(join(root, "logs", "stdout.log"));
    put(join(root, "logs", "stderr.log"));

    const result = cleanUp(store, paths());

    expect(Object.keys(result).sort()).toEqual(Object.keys(golden).sort());
    expect(result.status).toBe("cleaned");
    expect(result.freedBytes).toBeGreaterThanOrEqual(8000);
    for (const gone of [
      "agent-usage-cache.json",
      "exchange-rate.json",
      "state.db.before-schema7",
      "update",
      "fixes/42",
    ])
      expect(existsSync(join(state, gone)), gone).toBe(false);
    expect(existsSync(join(state, "lessons-usage", "2026-11-04.jsonl"))).toBe(true);
    expect(existsSync(join(state, "lesson-scopes.json"))).toBe(true);
    expect(statSync(join(root, "logs", "stdout.log")).size).toBe(0);
    expect(existsSync(join(state, "state.db"))).toBe(true);
  });

  it("keeps an update that waits to be swapped in", () => {
    put(join(state, "update", "staged", "Suica.app", "Contents", "Info.plist"));
    cleanUp(store, paths());
    expect(existsSync(join(state, "update", "staged", "Suica.app", "Contents", "Info.plist"))).toBe(
      true,
    );
  });

  it("works when nothing is there", () => {
    expect(cleanUp(store, paths()).status).toBe("cleaned");
  });
});
