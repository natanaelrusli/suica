import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
  mkdirSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { parseTemplateRequest, saveTemplate, showTemplates } from "../src/template-edit.ts";
import { DEFAULT_TEMPLATES, loadTemplates } from "../src/teams/templates.ts";

const folders: string[] = [];
afterEach(() => {
  for (const folder of folders.splice(0)) rmSync(folder, { recursive: true, force: true });
});
function tempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), "suica-templates-"));
  folders.push(dir);
  return join(dir, "templates");
}

describe("showTemplates", () => {
  it("lists every template, the built-in text where there is no file, and the placeholders", () => {
    const dir = tempDir();
    mkdirSync(dir);
    writeFileSync(join(dir, "nudge.txt"), "Hi {{person.name}}\n{{mr.link}}");
    const doc = showTemplates(dir);
    expect(doc.path).toBe(dir);
    expect(doc.placeholders).toContain("mr.link");
    expect(doc.templates.map((t) => t.name)).toEqual([
      "nudge",
      "reminder",
      "notice.approved",
      "notice.changes",
      "notice.comments",
      "notice.findings",
      "notice.refindings",
      "notice.reapproved",
      "rereview",
    ]);
    expect(doc.templates[0]).toEqual({
      name: "nudge",
      text: "Hi {{person.name}}\n{{mr.link}}",
      custom: true,
      defaultText: DEFAULT_TEMPLATES.nudge,
    });
    expect(doc.templates[1]).toMatchObject({ custom: false, text: DEFAULT_TEMPLATES.reminder });
  });

  it("matches the golden contract", () => {
    const golden: unknown = JSON.parse(readFileSync("contracts/templates.v1.json", "utf8"));
    const doc = showTemplates("/tmp/suica-no-such-templates");
    expect(doc).toEqual(golden);
  });
});

describe("saveTemplate", () => {
  it("saves and resets the re-review template like any other", () => {
    const dir = tempDir();
    expect(saveTemplate(dir, { name: "rereview", text: "Cek lagi {{person.name}}" })).toEqual({
      status: "saved",
    });
    expect(readFileSync(join(dir, "rereview.txt"), "utf8")).toBe("Cek lagi {{person.name}}");
    expect(showTemplates(dir).templates.at(-1)).toMatchObject({
      name: "rereview",
      text: "Cek lagi {{person.name}}",
      custom: true,
      defaultText: DEFAULT_TEMPLATES.rereview,
    });
    expect(saveTemplate(dir, { name: "rereview", text: null })).toEqual({ status: "reset" });
    expect(existsSync(join(dir, "rereview.txt"))).toBe(false);
  });

  it("accepts a request that names the re-review template", () => {
    expect(parseTemplateRequest('{"name": "rereview", "text": null}')).toEqual({
      name: "rereview",
      text: null,
    });
  });

  it("writes a valid template privately, creating the folder, and the agent then loads it", () => {
    const dir = tempDir();
    expect(
      saveTemplate(dir, { name: "reminder", text: "Halo {{person.name}}\n{{mr.link}}" }),
    ).toEqual({
      status: "saved",
    });
    expect(readFileSync(join(dir, "reminder.txt"), "utf8")).toBe(
      "Halo {{person.name}}\n{{mr.link}}",
    );
    expect(statSync(join(dir, "reminder.txt")).mode & 0o777).toBe(0o600);
    expect(loadTemplates(dir).reminder).toBe("Halo {{person.name}}\n{{mr.link}}");
  });

  it("refuses a template the agent would refuse, and leaves the file alone", () => {
    const dir = tempDir();
    saveTemplate(dir, { name: "nudge", text: "ok {{mr.url}}" });
    expect(saveTemplate(dir, { name: "nudge", text: "Hi {{person.nmae}}" })).toEqual({
      status: "invalid",
      message: "template nudge.txt uses an unknown placeholder: person.nmae",
    });
    expect(saveTemplate(dir, { name: "nudge", text: "  " })).toMatchObject({ status: "invalid" });
    expect(readFileSync(join(dir, "nudge.txt"), "utf8")).toBe("ok {{mr.url}}");
  });

  it("resets to the built-in template by removing the file", () => {
    const dir = tempDir();
    saveTemplate(dir, { name: "nudge", text: "ok" });
    expect(saveTemplate(dir, { name: "nudge", text: null })).toEqual({ status: "reset" });
    expect(existsSync(join(dir, "nudge.txt"))).toBe(false);
    expect(saveTemplate(dir, { name: "nudge", text: null })).toEqual({ status: "reset" });
  });
});

describe("parseTemplateRequest", () => {
  it("takes only a known template name, text or null, and nothing else", () => {
    expect(parseTemplateRequest('{"name":"nudge","text":"x"}')).toEqual({
      name: "nudge",
      text: "x",
    });
    expect(parseTemplateRequest('{"name":"nudge","text":null}')).toEqual({
      name: "nudge",
      text: null,
    });
    for (const bad of [
      '{"name":"../config","text":"x"}',
      '{"name":"nudge"}',
      '{"name":"nudge","text":"x","extra":1}',
      `{"name":"nudge","text":"${"x".repeat(4001)}"}`,
      "not json",
    ]) {
      expect(parseTemplateRequest(bad)).toBeUndefined();
    }
  });
});
