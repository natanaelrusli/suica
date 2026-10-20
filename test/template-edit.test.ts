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
import { ALERT_NAMES, ALERT_PLACEHOLDERS, DEFAULT_ALERTS, loadAlerts } from "../src/alerts.ts";
import { DEFAULT_TEMPLATES, PLACEHOLDERS, loadTemplates } from "../src/teams/templates.ts";

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
      ...ALERT_NAMES,
    ]);
    expect(doc.templates[0]).toEqual({
      name: "nudge",
      group: "teams",
      placeholders: PLACEHOLDERS,
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
    expect(showTemplates(dir).templates.find((t) => t.name === "rereview")).toMatchObject({
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

/** The refusal's message, so a test can match it. */
function refusal(result: ReturnType<typeof saveTemplate>): string {
  return "message" in result ? `${result.status}: ${result.message}` : result.status;
}

describe("notification templates in the editor", () => {
  it("lists each alert with its own placeholders, and the emoji table", () => {
    const doc = showTemplates(tempDir());
    expect(doc.templates.find((t) => t.name === "alert.review-failed")).toEqual({
      name: "alert.review-failed",
      group: "alert",
      placeholders: ALERT_PLACEHOLDERS["alert.review-failed"],
      text: DEFAULT_ALERTS["alert.review-failed"],
      custom: false,
      defaultText: DEFAULT_ALERTS["alert.review-failed"],
    });
    expect(doc.emoji["tada"]).toBe("🎉");
  });

  it("saves an alert the agent then loads", () => {
    const dir = tempDir();
    const text = ":tada: Review {{mr.title}}\nSiap dicek";
    expect(saveTemplate(dir, { name: "alert.review-ready", text })).toEqual({ status: "saved" });
    expect(loadAlerts(dir)["alert.review-ready"]).toBe(text);
  });

  it("refuses an alert without a body, or with another alert's placeholder", () => {
    const dir = tempDir();
    expect(refusal(saveTemplate(dir, { name: "alert.baseline", text: "Only a title" }))).toMatch(
      /^invalid: .*no body/,
    );
    expect(
      refusal(saveTemplate(dir, { name: "alert.baseline", text: "Hi\n{{mr.title}}" })),
    ).toMatch(/^invalid: .*mr\.title/);
    expect(existsSync(join(dir, "alert.baseline.txt"))).toBe(false);
  });

  it("refuses a Teams template with an http image or an empty variant", () => {
    const dir = tempDir();
    expect(
      refusal(saveTemplate(dir, { name: "nudge", text: "Hi ![gif](http://x.example/a.gif)" })),
    ).toMatch(/^invalid: .*https/);
    expect(refusal(saveTemplate(dir, { name: "nudge", text: "Hi\n--- or ---\n" }))).toMatch(
      /^invalid: .*empty/,
    );
  });
});
