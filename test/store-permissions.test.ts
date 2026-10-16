import { chmodSync, existsSync, mkdirSync, mkdtempSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { openStore } from "../src/store.ts";
import { mr, reviewer, snapshot } from "./builders.ts";

const folders: string[] = [];
afterEach(() => {
  for (const folder of folders.splice(0)) rmSync(folder, { recursive: true, force: true });
});

const mode = (path: string): number => statSync(path).mode & 0o777;

describe("state file permissions", () => {
  it("restricts a pre-existing directory and every database file to the owner", () => {
    const root = mkdtempSync(join(tmpdir(), "suica-perm-"));
    folders.push(root);
    const directory = join(root, "state");
    mkdirSync(directory, { mode: 0o755 });
    chmodSync(directory, 0o755);
    const path = join(directory, "state.db");

    const store = openStore(path);
    store.commit(
      snapshot({ reviewRequested: [mr(1, { reviewers: [reviewer("me", "UNREVIEWED")] })] }),
    );

    expect(mode(directory)).toBe(0o700);
    for (const file of [path, `${path}-wal`, `${path}-shm`]) {
      if (existsSync(file)) expect(mode(file)).toBe(0o600);
    }
    expect(existsSync(path)).toBe(true);
    store.close();
  });
});
