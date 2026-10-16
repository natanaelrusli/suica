import { createHash } from "node:crypto";
import * as fs from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { applyConfigEdits } from "../src/config-edit.ts";

vi.mock("node:fs", async (importOriginal) => {
  const actual = await importOriginal<typeof fs>();
  return { ...actual, fsyncSync: vi.fn(actual.fsyncSync) };
});

const MINIMAL = "gitlab:\n  hostname: h\n";
let dir: string;
beforeEach(() => {
  dir = fs.mkdtempSync(join(tmpdir(), "suica-config-sync-"));
});
afterEach(() => {
  fs.rmSync(dir, { recursive: true, force: true });
});

describe("the atomic config write", () => {
  it("flushes the temp file to disk before it replaces the config", () => {
    const path = join(dir, "config.yaml");
    fs.writeFileSync(path, MINIMAL);
    const fsync = vi.mocked(fs.fsyncSync);
    fsync.mockClear();
    const result = applyConfigEdits(path, {
      baseSha256: createHash("sha256").update(MINIMAL).digest("hex"),
      edits: [{ path: ["polling", "activeSeconds"], value: 60 }],
    });
    expect(result.status).toBe("saved");
    expect(fsync).toHaveBeenCalledTimes(1);
    expect(fs.statSync(path).mode & 0o777).toBe(0o600);
    expect(fs.readdirSync(dir)).toEqual(["config.yaml"]);
  });
});
