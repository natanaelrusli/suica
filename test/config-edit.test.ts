import { createHash } from "node:crypto";
import {
  chmodSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parse } from "yaml";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { applyConfigEdits, parseSaveRequest, showConfig } from "../src/config-edit.ts";
import type { ConfigEdit } from "../src/config-edit.ts";
import { TEMPLATE_NAMES } from "../src/teams/types.ts";

const MINIMAL = "gitlab:\n  hostname: h\n";

let dir: string;
let path: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "suica-config-edit-"));
  path = join(dir, "config.yaml");
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

const sha = (text: string): string => createHash("sha256").update(text).digest("hex");
const edit = (field: string, value: unknown): ConfigEdit => ({ path: field.split("."), value });
const mode = (target: string): number => statSync(target).mode & 0o777;

function templatesFolder(): string {
  const folder = join(dir, "templates");
  mkdirSync(folder);
  for (const name of TEMPLATE_NAMES)
    writeFileSync(join(folder, `${name}.txt`), "Hi {{person.name}}");
  return folder;
}

describe("applyConfigEdits", () => {
  it("sets a value and keeps comments and other keys", () => {
    const original = "# mine\ngitlab:\n  hostname: h # host\n";
    writeFileSync(path, original);
    const result = applyConfigEdits(path, {
      baseSha256: sha(original),
      edits: [edit("polling.activeSeconds", 60)],
    });
    expect(result.status).toBe("saved");
    expect(result.issues).toEqual([]);
    const text = readFileSync(path, "utf8");
    expect(text).toContain("# mine");
    expect(text).toContain("# host");
    expect(text).toContain("hostname: h");
    expect(text).toContain("activeSeconds: 60");
    expect(result.sha256).toBe(sha(text));
    expect(result.sha256).not.toBe(sha(original));
    expect(showConfig(path).sha256).toBe(result.sha256);
    expect(readdirSync(dir)).toEqual(["config.yaml"]);
  });

  it("removes a key with null and drops the empty section", () => {
    const original = `${MINIMAL}polling:\n  activeSeconds: 60\n`;
    writeFileSync(path, original);
    const result = applyConfigEdits(path, {
      baseSha256: sha(original),
      edits: [edit("polling.activeSeconds", null)],
    });
    expect(result.status).toBe("saved");
    const text = readFileSync(path, "utf8");
    expect(text).not.toContain("polling");
    expect(text).toContain("hostname: h");
  });

  it("keeps a section that still has other keys when one key is removed", () => {
    const original = `${MINIMAL}polling:\n  activeSeconds: 60\n  idleSeconds: 600\n`;
    writeFileSync(path, original);
    applyConfigEdits(path, {
      baseSha256: sha(original),
      edits: [edit("polling.idleSeconds", null)],
    });
    expect(parse(readFileSync(path, "utf8"))).toEqual({
      gitlab: { hostname: "h" },
      polling: { activeSeconds: 60 },
    });
  });

  it("drops every mapping that became empty", () => {
    const original = `${MINIMAL}teams:\n  workingHours:\n    days: [1, 2]\n`;
    writeFileSync(path, original);
    const result = applyConfigEdits(path, {
      baseSha256: sha(original),
      edits: [edit("teams.workingHours.days", null)],
    });
    expect(result.status).toBe("saved");
    expect(parse(readFileSync(path, "utf8"))).toEqual({ gitlab: { hostname: "h" } });
  });

  it("creates the file with mode 0600 and the folder with 0700 when baseSha256 is null", () => {
    const nested = join(dir, "new", "config.yaml");
    const result = applyConfigEdits(nested, {
      baseSha256: null,
      edits: [edit("gitlab.hostname", "repo.example")],
    });
    expect(result.status).toBe("saved");
    expect(mode(nested)).toBe(0o600);
    expect(mode(join(dir, "new"))).toBe(0o700);
    expect(readFileSync(nested, "utf8")).toContain("hostname: repo.example");
  });

  it("conflict when the file changed", () => {
    writeFileSync(path, MINIMAL);
    const result = applyConfigEdits(path, {
      baseSha256: sha("something else"),
      edits: [edit("polling.activeSeconds", 60)],
    });
    expect(result).toEqual({ status: "conflict", issues: [], sha256: null });
    expect(readFileSync(path, "utf8")).toBe(MINIMAL);
  });

  it("conflict when baseSha256 is null but the file exists", () => {
    writeFileSync(path, MINIMAL);
    const result = applyConfigEdits(path, {
      baseSha256: null,
      edits: [edit("polling.activeSeconds", 60)],
    });
    expect(result.status).toBe("conflict");
    expect(readFileSync(path, "utf8")).toBe(MINIMAL);
  });

  it("conflict when a base is given but the file is gone", () => {
    const result = applyConfigEdits(path, {
      baseSha256: sha(MINIMAL),
      edits: [edit("gitlab.hostname", "h")],
    });
    expect(result.status).toBe("conflict");
    expect(readdirSync(dir)).toEqual([]);
  });

  it("rejects start after end", () => {
    writeFileSync(path, MINIMAL);
    const result = applyConfigEdits(path, {
      baseSha256: sha(MINIMAL),
      edits: [edit("teams.workingHours.start", "18:00")],
    });
    expect(result.status).toBe("invalid");
    expect(result.sha256).toBeNull();
    expect(result.issues.map((issue) => issue.path)).toContain("teams.workingHours");
    expect(readFileSync(path, "utf8")).toBe(MINIMAL);
    expect(readdirSync(dir)).toEqual(["config.yaml"]);
  });

  it("rejects Teams on when a template file is unusable", () => {
    writeFileSync(path, MINIMAL);
    const folder = templatesFolder();
    writeFileSync(join(folder, "nudge.txt"), "Hi {{who}}");
    const result = applyConfigEdits(path, {
      baseSha256: sha(MINIMAL),
      edits: [edit("teams.enabled", true), edit("teams.templatesPath", folder)],
    });
    expect(result.status).toBe("invalid");
    expect(result.issues.map((issue) => issue.path)).toEqual(["teams.templatesPath"]);
    expect(result.issues[0]?.message).toContain("nudge.txt");
    expect(readFileSync(path, "utf8")).toBe(MINIMAL);
  });

  it("rejects Teams on when the templates path cannot be read", () => {
    writeFileSync(path, MINIMAL);
    const folder = templatesFolder();
    rmSync(join(folder, "nudge.txt"));
    mkdirSync(join(folder, "nudge.txt"));
    const result = applyConfigEdits(path, {
      baseSha256: sha(MINIMAL),
      edits: [edit("teams.enabled", true), edit("teams.templatesPath", folder)],
    });
    expect(result.status).toBe("invalid");
    expect(result.issues.map((issue) => issue.path)).toEqual(["teams.templatesPath"]);
    expect(result.issues[0]?.message).not.toContain(dir);
    expect(readFileSync(path, "utf8")).toBe(MINIMAL);
  });

  it("saves Teams on with a valid templates folder, and does not look at templates when Teams is off", () => {
    writeFileSync(path, MINIMAL);
    const bad = join(dir, "bad-templates");
    mkdirSync(bad);
    writeFileSync(join(bad, "nudge.txt"), "Hi {{who}}");
    const off = applyConfigEdits(path, {
      baseSha256: sha(MINIMAL),
      edits: [edit("teams.templatesPath", bad)],
    });
    expect(off.status).toBe("saved");
    const on = applyConfigEdits(path, {
      baseSha256: off.sha256,
      edits: [edit("teams.enabled", true), edit("teams.templatesPath", templatesFolder())],
    });
    expect(on.status).toBe("saved");
    expect(showConfig(path).issues).toEqual([]);
  });

  it("rejects an unknown field path as bad-request", () => {
    writeFileSync(path, MINIMAL);
    for (const bad of ["polling", "polling.nope", "gitlab.hostname.x", "__proto__.x", ""]) {
      const result = applyConfigEdits(path, {
        baseSha256: sha(MINIMAL),
        edits: [edit("polling.activeSeconds", 60), { path: bad.split("."), value: 1 }],
      });
      expect(result.status).toBe("bad-request");
      expect(result.issues).toHaveLength(1);
      expect(result.issues[0]?.path).toBe(bad);
      expect(readFileSync(path, "utf8")).toBe(MINIMAL);
    }
  });

  it("answers bad-request before conflict", () => {
    writeFileSync(path, MINIMAL);
    const result = applyConfigEdits(path, {
      baseSha256: sha("different"),
      edits: [edit("nope", 1)],
    });
    expect(result.status).toBe("bad-request");
  });

  it("rejects a wrongly typed value", () => {
    writeFileSync(path, MINIMAL);
    const result = applyConfigEdits(path, {
      baseSha256: sha(MINIMAL),
      edits: [edit("polling.activeSeconds", "fast")],
    });
    expect(result.status).toBe("invalid");
    expect(result.issues.map((issue) => issue.path)).toContain("polling.activeSeconds");
    expect(readFileSync(path, "utf8")).toBe(MINIMAL);
  });

  it("writes emailMap and weekdays values", () => {
    writeFileSync(path, MINIMAL);
    const result = applyConfigEdits(path, {
      baseSha256: sha(MINIMAL),
      edits: [edit("teams.people", { e123: "a@b.co" }), edit("teams.workingHours.days", [1, 2, 3])],
    });
    expect(result.status).toBe("saved");
    const doc = showConfig(path);
    const effective = (name: string) =>
      doc.fields.find((field) => field.path.join(".") === name)?.effective;
    expect(effective("teams.people")).toEqual({ e123: "a@b.co" });
    expect(effective("teams.workingHours.days")).toEqual([1, 2, 3]);
  });

  it("does not fold long strings", () => {
    const long = `${"word ".repeat(40)}end`;
    writeFileSync(path, MINIMAL);
    applyConfigEdits(path, { baseSha256: sha(MINIMAL), edits: [edit("gitlab.glabPath", long)] });
    expect(readFileSync(path, "utf8")).toContain(`glabPath: ${long}\n`);
  });

  it("refuses to overwrite a config file it cannot read", () => {
    mkdirSync(path);
    const result = applyConfigEdits(path, {
      baseSha256: null,
      edits: [edit("gitlab.hostname", "h")],
    });
    expect(result).toEqual({
      status: "invalid",
      issues: [{ path: "(root)", message: "cannot read the config file" }],
      sha256: null,
    });
    expect(lstatSync(path).isDirectory()).toBe(true);
    expect(readdirSync(dir)).toEqual(["config.yaml"]);
    expect(readdirSync(path)).toEqual([]);
  });

  it("refuses a config file with a YAML syntax error and leaves it alone", () => {
    const broken = "gitlab: [unclosed\n";
    writeFileSync(path, broken);
    const result = applyConfigEdits(path, {
      baseSha256: sha(broken),
      edits: [edit("gitlab.hostname", "h")],
    });
    expect(result.status).toBe("invalid");
    expect(result.issues.map((issue) => issue.path)).toEqual(["(root)"]);
    expect(readFileSync(path, "utf8")).toBe(broken);
  });

  it("refuses a config whose root or section is not a mapping", () => {
    for (const odd of ["- a\n- b\n", "just text\n", "gitlab: 5\n"]) {
      writeFileSync(path, odd);
      const result = applyConfigEdits(path, {
        baseSha256: sha(odd),
        edits: [edit("gitlab.hostname", "h")],
      });
      expect(result.status).toBe("invalid");
      expect(readFileSync(path, "utf8")).toBe(odd);
    }
  });

  it("treats an empty existing file like a new one", () => {
    writeFileSync(path, "");
    const result = applyConfigEdits(path, {
      baseSha256: sha(""),
      edits: [edit("gitlab.hostname", "h")],
    });
    expect(result.status).toBe("saved");
    expect(parse(readFileSync(path, "utf8"))).toEqual({ gitlab: { hostname: "h" } });
  });

  it("writes through a symlink and keeps the link", () => {
    const real = join(dir, "real.yaml");
    writeFileSync(real, MINIMAL);
    symlinkSync(real, path);
    const result = applyConfigEdits(path, {
      baseSha256: sha(MINIMAL),
      edits: [edit("polling.activeSeconds", 60)],
    });
    expect(result.status).toBe("saved");
    expect(lstatSync(path).isSymbolicLink()).toBe(true);
    expect(readFileSync(real, "utf8")).toContain("activeSeconds: 60");
  });

  it("throws a message without the path when the folder cannot be created", () => {
    chmodSync(dir, 0o500);
    const target = join(dir, "sub", "config.yaml");
    try {
      applyConfigEdits(target, { baseSha256: null, edits: [edit("gitlab.hostname", "h")] });
      expect.unreachable("should have thrown");
    } catch (error) {
      expect((error as Error).message).toBe("cannot write the config file");
    } finally {
      chmodSync(dir, 0o700);
    }
    expect(readdirSync(dir)).toEqual([]);
  });

  it("refuses a config path whose parent is a file", () => {
    const blocker = join(dir, "blocker");
    writeFileSync(blocker, "x");
    const result = applyConfigEdits(join(blocker, "config.yaml"), {
      baseSha256: null,
      edits: [edit("gitlab.hostname", "h")],
    });
    expect(result.status).toBe("invalid");
    expect(readFileSync(blocker, "utf8")).toBe("x");
  });

  it("leaves no temp file and keeps the original when the folder is read-only", () => {
    writeFileSync(path, MINIMAL);
    chmodSync(dir, 0o500);
    try {
      expect(() =>
        applyConfigEdits(path, {
          baseSha256: sha(MINIMAL),
          edits: [edit("polling.activeSeconds", 60)],
        }),
      ).toThrow("cannot write the config file");
    } finally {
      chmodSync(dir, 0o700);
    }
    expect(readFileSync(path, "utf8")).toBe(MINIMAL);
    expect(readdirSync(dir)).toEqual(["config.yaml"]);
  });
});

describe("parseSaveRequest", () => {
  const good = { baseSha256: null, edits: [{ path: ["polling", "activeSeconds"], value: 60 }] };

  it("accepts a well-formed request, with a null base or a hex digest", () => {
    expect(parseSaveRequest(JSON.stringify(good))).toEqual(good);
    const digest = sha("x");
    expect(parseSaveRequest(JSON.stringify({ ...good, baseSha256: digest }))?.baseSha256).toBe(
      digest,
    );
    expect(parseSaveRequest('{"baseSha256":null,"edits":[]}')?.edits).toEqual([]);
  });

  it("keeps a null value, which removes the key", () => {
    const request = parseSaveRequest('{"baseSha256":null,"edits":[{"path":["a"],"value":null}]}');
    expect(request?.edits[0]).toEqual({ path: ["a"], value: null });
  });

  it("rejects garbage and missing fields", () => {
    const bad = [
      "",
      "not json",
      "null",
      "[]",
      "{}",
      '{"edits":[]}',
      '{"baseSha256":null}',
      '{"baseSha256":null,"edits":"x"}',
      '{"baseSha256":5,"edits":[]}',
      '{"baseSha256":"abc","edits":[]}',
      '{"baseSha256":null,"edits":[{"path":["a"]}]}',
      '{"baseSha256":null,"edits":[{"value":1}]}',
      '{"baseSha256":null,"edits":[{"path":[],"value":1}]}',
      '{"baseSha256":null,"edits":[{"path":[1],"value":1}]}',
      '{"baseSha256":null,"edits":[{"path":"a.b","value":1}]}',
      '{"baseSha256":null,"edits":[],"extra":1}',
      '{"baseSha256":null,"edits":[{"path":["a"],"value":1,"extra":1}]}',
    ];
    for (const text of bad) expect(parseSaveRequest(text), text).toBeUndefined();
  });
});
