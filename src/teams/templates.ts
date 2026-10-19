import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { FindingCount } from "../inline-review.ts";
import { TEMPLATE_NAMES } from "./types.ts";
import type { TemplateName } from "./types.ts";

export const PLACEHOLDERS = [
  "mr.title",
  "mr.url",
  "mr.link",
  "mr.iid",
  "mr.project",
  "person.name",
  "owner.name",
  /** What an Agent Review found, such as "ada 8 findings (7 Minor, 1 Nit)"; empty elsewhere. */
  "review.findings",
] as const;
export type Placeholder = (typeof PLACEHOLDERS)[number];
export type Templates = Readonly<Record<TemplateName, string>>;

export const DEFAULT_TEMPLATES: Templates = {
  nudge: "Halo {{person.name}}, boleh minta tolong review MR ini?\n{{mr.link}}\nTerima kasih!",
  reminder:
    "Halo {{person.name}}, mengingatkan kembali soal review MR ini ya:\n{{mr.link}}\nTerima kasih!",
  "notice.approved":
    "Halo {{person.name}}, MR kamu sudah saya review dan saya approve:\n{{mr.link}}",
  "notice.changes":
    "Halo {{person.name}}, saya sudah review MR kamu dan ada perubahan yang perlu dilihat:\n{{mr.link}}",
  "notice.comments":
    "Halo {{person.name}}, saya sudah review MR kamu dan meninggalkan beberapa komentar:\n{{mr.link}}",
  "notice.findings":
    "Halo {{person.name}}, saya sudah review MR kamu: {{review.findings}}.\n{{mr.link}}\nDetailnya ada di komentar MR.",
  rereview:
    "Halo {{person.name}}, MR ini sudah saya update sesuai review-mu. Boleh minta tolong dicek lagi?\n{{mr.link}}\nTerima kasih!",
};

/**
 * Messages go to Teams as Markdown: a value written into a template is escaped, so a title with
 * `*`, `_` or brackets reads as written instead of turning into formatting or a link.
 */
export function escapeMarkdown(text: string): string {
  return text.replace(/[\\`*_[\]<>~#|]/g, "\\$&");
}

/** `[title](url)`, a link Teams shows as the title; the URL is http(s) from GitLab. */
export function markdownLink(title: string, url: string): string {
  const target = url.replace(/[ ()<>]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);
  return `[${escapeMarkdown(title)}](${target})`;
}

/** The `review.findings` value: "tidak ada findings", or the total and each severity in order. */
export function describeFindings(counts: readonly FindingCount[]): string {
  const total = counts.reduce((sum, each) => sum + each.count, 0);
  if (total === 0) return "tidak ada findings";
  const head = `ada ${total} ${total === 1 ? "finding" : "findings"}`;
  if (counts.every((each) => each.severity === "")) return head;
  const parts = counts.map(
    (each) =>
      `${each.count} ${each.severity === "" ? "tanpa severity" : escapeMarkdown(each.severity)}`,
  );
  return `${head} (${parts.join(", ")})`;
}

export class TemplateError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "TemplateError";
  }
}

const PLACEHOLDER_PATTERN = /\{\{\s*([\w.]+)\s*\}\}/g;

function isPlaceholder(name: string): name is Placeholder {
  return (PLACEHOLDERS as readonly string[]).includes(name);
}

/** Throws a `TemplateError` naming `label` when the text is empty or uses an unknown placeholder. */
export function validateTemplate(label: string, text: string): void {
  if (text.trim().length === 0) throw new TemplateError(`template ${label} is empty`);
  for (const match of text.matchAll(PLACEHOLDER_PATTERN)) {
    const name = match[1] ?? "";
    if (!isPlaceholder(name)) {
      throw new TemplateError(`template ${label} uses an unknown placeholder: ${name}`);
    }
  }
}

/** One pass over the template, so a value that looks like a placeholder is never expanded. */
export function renderTemplate(
  text: string,
  values: Readonly<Record<Placeholder, string>>,
): string {
  return text
    .replace(PLACEHOLDER_PATTERN, (_whole, name: string) => {
      if (!isPlaceholder(name)) throw new TemplateError(`unknown placeholder: ${name}`);
      return values[name];
    })
    .trim();
}

export function defaultTemplatesPath(): string {
  return join(homedir(), ".config", "suica", "templates");
}

/** A file `<name>.txt` in `directory` replaces the built-in template of the same name. */
export function loadTemplates(directory: string): Templates {
  const loaded: Record<TemplateName, string> = { ...DEFAULT_TEMPLATES };
  for (const name of TEMPLATE_NAMES) {
    const file = join(directory, `${name}.txt`);
    if (!existsSync(file)) continue;
    const text = readFileSync(file, "utf8");
    validateTemplate(`${name}.txt`, text);
    loaded[name] = text;
  }
  return loaded;
}
