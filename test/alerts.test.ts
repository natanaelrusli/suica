import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  ALERT_NAMES,
  ALERT_PLACEHOLDERS,
  DEFAULT_ALERTS,
  loadAlerts,
  validateAlert,
} from "../src/alerts.ts";
import { clean, renderAlert } from "../src/format.ts";

const folders: string[] = [];
afterEach(() => {
  for (const folder of folders.splice(0)) rmSync(folder, { recursive: true, force: true });
});
function tempDir(): string {
  const folder = mkdtempSync(join(tmpdir(), "suica-alerts-"));
  folders.push(folder);
  return folder;
}

describe("alert templates", () => {
  it("has a valid built-in text for every alert, using only its own placeholders", () => {
    for (const name of ALERT_NAMES) {
      expect(() => validateAlert(name, name, DEFAULT_ALERTS[name])).not.toThrow();
      const values = Object.fromEntries(ALERT_PLACEHOLDERS[name].map((p) => [p, `<${p}>`]));
      const rendered = renderAlert(DEFAULT_ALERTS, name, values);
      expect(rendered.title.length).toBeGreaterThan(0);
      expect(rendered.body.length).toBeGreaterThan(0);
    }
  });

  it("lets a file replace one alert, with emoji, and keeps the others", () => {
    const dir = tempDir();
    writeFileSync(join(dir, "alert.review-ready.txt"), ":tada: Review siap\n{{mr.title}} :eyes:\n");
    const alerts = loadAlerts(dir);
    expect(renderAlert(alerts, "alert.review-ready", { "mr.title": "Add thing" })).toEqual({
      title: "🎉 Review siap",
      body: "Add thing 👀",
    });
    expect(alerts["alert.baseline"]).toBe(DEFAULT_ALERTS["alert.baseline"]);
  });

  it("stops startup with the file name for a bad alert", () => {
    const dir = tempDir();
    writeFileSync(join(dir, "alert.summary.txt"), "{{alert.count}} new\n{{mr.url}}");
    expect(() => loadAlerts(dir)).toThrow(/alert\.summary\.txt.*mr\.url/);
  });

  it("never expands a placeholder or shortcode found in a value", () => {
    const rendered = renderAlert(DEFAULT_ALERTS, "alert.review-failed", {
      "mr.title": "{{review.reason}} :tada:",
      "review.reason": "boom",
    });
    expect(rendered.body).toBe("{{review.reason}} :tada:: boom");
  });
});

describe("clean keeps emoji whole", () => {
  it("keeps a joiner inside an emoji and drops it elsewhere", () => {
    expect(clean("👩‍💻 dev")).toBe("👩‍💻 dev");
    expect(clean("🧑🏽‍💻")).toBe("🧑🏽‍💻");
    expect(clean("a‍b‮c")).toBe("a b c");
  });
});
