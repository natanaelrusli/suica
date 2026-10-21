import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { TemplateError, validateText } from "./teams/templates.ts";

/**
 * The texts of the macOS notifications the agent shows the Owner. A file `<name>.txt` in the
 * templates folder replaces the built-in one: its first line is the title, the rest the body.
 * Values are plain text (a notification shows no Markdown); `:shortcode:` emoji work.
 */
export const ALERT_NAMES = [
  "alert.review-requested",
  "alert.activity",
  "alert.summary",
  "alert.baseline",
  "alert.rereview",
  "alert.review-ready",
  "alert.review-posted",
  "alert.review-approved",
  "alert.review-post-failed",
  "alert.review-failed",
  "alert.review-skipped",
  "alert.fix-ready",
  "alert.fix-failed",
  "alert.fix-pushed",
] as const;
export type AlertName = (typeof ALERT_NAMES)[number];
export type AlertTemplates = Readonly<Record<AlertName, string>>;

const MR = ["mr.title", "mr.iid", "mr.project", "mr.url"] as const;

/** What each alert may use; any other placeholder is refused like an unknown one. */
export const ALERT_PLACEHOLDERS: Readonly<Record<AlertName, readonly string[]>> = {
  "alert.review-requested": [...MR, "author.name"],
  "alert.activity": [...MR, "activity.summary"],
  "alert.summary": ["alert.count", "alert.titles"],
  "alert.baseline": ["alert.count"],
  "alert.rereview": ["mr.title", "reviewers.names"],
  "alert.review-ready": ["mr.title"],
  "alert.review-posted": ["mr.title"],
  "alert.review-approved": ["mr.title"],
  "alert.review-post-failed": ["mr.title"],
  "alert.review-failed": ["mr.title", "review.reason"],
  "alert.review-skipped": ["mr.title", "review.reason"],
  "alert.fix-ready": ["mr.title", "fix.threads"],
  "alert.fix-failed": ["mr.title", "fix.reason"],
  "alert.fix-pushed": ["mr.title"],
};

/** Today's texts, title and body on separate lines. */
export const DEFAULT_ALERTS: AlertTemplates = {
  "alert.review-requested": "Diminta review: {{mr.title}}\n{{author.name}} · {{mr.project}}",
  "alert.activity": "!{{mr.iid}}: {{mr.title}}\n{{activity.summary}}",
  "alert.summary": "{{alert.count}} aktivitas MR baru\n{{alert.titles}}",
  "alert.baseline": "Suica aktif\n{{alert.count}} MR menunggu review-mu",
  "alert.rereview":
    "Minta review ulang?\nKamu push ke {{mr.title}} setelah {{reviewers.names}} review. Kirim pesan Teams?",
  "alert.review-ready": "Review agen siap\n{{mr.title}}: periksa di Suica, lalu posting ke GitLab.",
  "alert.review-posted": "Review agen diposting\n{{mr.title}}: sudah diposting ke GitLab.",
  "alert.review-approved":
    "Review agen diposting\n{{mr.title}}: sudah diposting ke GitLab dan MR di-approve.",
  "alert.review-post-failed":
    "Review agen gagal diposting\n{{mr.title}}: periksa GitLab, lalu posting dari Suica.",
  "alert.review-failed": "Review agen gagal\n{{mr.title}}: {{review.reason}}",
  "alert.review-skipped": "Review agen dilewati\n{{mr.title}}: {{review.reason}}",
  "alert.fix-ready":
    "Perbaikan agen siap\n{{mr.title}}: {{fix.threads}} thread dijawab. Periksa di Suica, lalu push.",
  "alert.fix-failed": "Perbaikan agen gagal\n{{mr.title}}: {{fix.reason}}",
  "alert.fix-pushed":
    "Perbaikan agen di-push\n{{mr.title}}: sebagian balasan gagal diposting. Kirim ulang dari Suica.",
};

export function isAlertName(value: string): value is AlertName {
  return (ALERT_NAMES as readonly string[]).includes(value);
}

/** The title (first line) and the body (the rest, trimmed). */
export function splitAlert(text: string): { title: string; body: string } {
  const end = text.indexOf("\n");
  return end < 0
    ? { title: text.trim(), body: "" }
    : { title: text.slice(0, end).trim(), body: text.slice(end + 1).trim() };
}

/** Throws a `TemplateError` naming `label` unless both title and body are there and valid. */
export function validateAlert(label: string, name: AlertName, text: string): void {
  const { title, body } = splitAlert(text);
  if (title.length === 0)
    throw new TemplateError(`template ${label} has no title on its first line`);
  if (body.length === 0) throw new TemplateError(`template ${label} has no body after its title`);
  validateText(label, text, ALERT_PLACEHOLDERS[name]);
}

export function loadAlerts(directory: string): AlertTemplates {
  const loaded: Record<AlertName, string> = { ...DEFAULT_ALERTS };
  for (const name of ALERT_NAMES) {
    const file = join(directory, `${name}.txt`);
    if (!existsSync(file)) continue;
    const text = readFileSync(file, "utf8");
    validateAlert(`${name}.txt`, name, text);
    loaded[name] = text;
  }
  return loaded;
}
