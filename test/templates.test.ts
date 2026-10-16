import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  DEFAULT_TEMPLATES,
  TemplateError,
  loadTemplates,
  renderTemplate,
  validateTemplate,
} from "../src/teams/templates.ts";
import { TEMPLATE_NAMES } from "../src/teams/types.ts";

const folders: string[] = [];
afterEach(() => {
  for (const folder of folders.splice(0)) rmSync(folder, { recursive: true, force: true });
});
function tempDir(): string {
  const folder = mkdtempSync(join(tmpdir(), "suica-tpl-"));
  folders.push(folder);
  return folder;
}

const values = {
  "mr.title": "Add thing",
  "mr.url": "https://gitlab.example/g/p/-/merge_requests/7",
  "mr.iid": "7",
  "mr.project": "g/p",
  "person.name": "Alice",
  "owner.name": "Nata",
};

describe("validateTemplate", () => {
  it("accepts known placeholders with or without spaces", () => {
    expect(() => validateTemplate("x", "Halo {{person.name}} {{ mr.url }}")).not.toThrow();
  });

  it("rejects an unknown placeholder and names it with the template", () => {
    expect(() => validateTemplate("nudge.txt", "Halo {{person.nmae}}")).toThrow(
      /nudge\.txt.*person\.nmae/,
    );
  });

  it("rejects an empty template", () => {
    expect(() => validateTemplate("x", "  \n ")).toThrow(TemplateError);
  });

  it("accepts every built-in template", () => {
    for (const name of TEMPLATE_NAMES) {
      expect(() => validateTemplate(name, DEFAULT_TEMPLATES[name])).not.toThrow();
    }
  });
});

describe("renderTemplate", () => {
  it("replaces every occurrence and trims the result", () => {
    expect(renderTemplate("\nHalo {{person.name}}, {{ person.name }}!\n{{mr.url}}\n", values)).toBe(
      "Halo Alice, Alice!\nhttps://gitlab.example/g/p/-/merge_requests/7",
    );
  });

  it("does not expand placeholders that appear inside a substituted value", () => {
    const tricky = { ...values, "mr.title": "{{owner.name}}" };
    expect(renderTemplate("{{mr.title}}", tricky)).toBe("{{owner.name}}");
  });

  it("refuses an unknown placeholder at render time too", () => {
    expect(() => renderTemplate("{{nope}}", values)).toThrow(TemplateError);
  });
});

describe("loadTemplates", () => {
  it("uses the built-in Indonesian defaults when the folder does not exist", () => {
    expect(loadTemplates(join(tempDir(), "missing"))).toEqual(DEFAULT_TEMPLATES);
    expect(DEFAULT_TEMPLATES.nudge).toContain("boleh minta tolong review");
  });

  it("lets a file replace one template and keeps the others", () => {
    const directory = tempDir();
    writeFileSync(join(directory, "reminder.txt"), "Ping {{person.name}}: {{mr.url}}\n");
    const loaded = loadTemplates(directory);
    expect(loaded.reminder).toBe("Ping {{person.name}}: {{mr.url}}\n");
    expect(loaded.nudge).toBe(DEFAULT_TEMPLATES.nudge);
  });

  it("stops with the file name when a template file has an unknown placeholder", () => {
    const directory = tempDir();
    mkdirSync(directory, { recursive: true });
    writeFileSync(join(directory, "nudge.txt"), "Halo {{who}}");
    expect(() => loadTemplates(directory)).toThrow(/nudge\.txt.*who/);
  });
});
