import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { showConfig } from "../src/config-edit.ts";
import type { ConfigDocJson } from "../src/config-edit.ts";

const MINIMAL = "gitlab:\n  hostname: repo.example\n";

let dir: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "suica-config-show-"));
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

function field(doc: ConfigDocJson, path: string) {
  const found = doc.fields.find((candidate) => candidate.path.join(".") === path);
  if (found === undefined) throw new Error(`no field ${path}`);
  return found;
}

describe("showConfig", () => {
  it("matches the golden contract file for the minimal config", () => {
    const path = join(dir, "config.yaml");
    writeFileSync(path, MINIMAL);
    const golden = JSON.parse(readFileSync("contracts/config.v1.json", "utf8")) as ConfigDocJson;
    const sha256 = createHash("sha256").update(MINIMAL).digest("hex");
    expect(JSON.parse(JSON.stringify(showConfig(path)))).toEqual({ ...golden, path, sha256 });
  });

  it("reports a missing file with exists false, sha256 null and effective null", () => {
    const doc = showConfig(join(dir, "absent.yaml"));
    expect(doc.exists).toBe(false);
    expect(doc.sha256).toBeNull();
    expect(doc.fields).toHaveLength(52);
    for (const each of doc.fields) {
      expect(each.value).toBeNull();
      expect(each.effective).toBeNull();
    }
  });

  it("reports schema issues per path and keeps the file values", () => {
    const path = join(dir, "config.yaml");
    writeFileSync(path, `${MINIMAL}polling:\n  activeSeconds: 0\n`);
    const doc = showConfig(path);
    expect(doc.issues).toHaveLength(1);
    expect(doc.issues[0]?.path).toBe("polling.activeSeconds");
    const active = field(doc, "polling.activeSeconds");
    expect(active.value).toBe(0);
    expect(active.effective).toBeNull();
    expect(field(doc, "gitlab.hostname").value).toBe("repo.example");
    expect(field(doc, "gitlab.hostname").effective).toBeNull();
  });

  it("reports a YAML syntax error at (root)", () => {
    const path = join(dir, "config.yaml");
    writeFileSync(path, "gitlab: [unclosed\n");
    const doc = showConfig(path);
    expect(doc.exists).toBe(true);
    expect(doc.sha256).toBe(createHash("sha256").update("gitlab: [unclosed\n").digest("hex"));
    expect(doc.issues).toHaveLength(1);
    expect(doc.issues[0]?.path).toBe("(root)");
    for (const each of doc.fields) {
      expect(each.value).toBeNull();
      expect(each.effective).toBeNull();
    }
  });
});
