import { DEFAULT_ALERTS, splitAlert } from "./alerts.ts";
import type { AlertName, AlertTemplates } from "./alerts.ts";
import type { ActivityEvent } from "./events.ts";
import type { MergeRequest, ReviewState } from "./domain.ts";
import { fillText } from "./teams/templates.ts";
import type { HeldMessage } from "./teams/types.ts";

export interface Notification {
  readonly title: string;
  readonly body: string;
  readonly url?: string;
}

const TITLE_MAX = 80;
const NAME_MAX = 40;
const BODY_MAX = 160;
const ALERT_TITLE_MAX = 120;
// A rendered body may be longer than the values it holds: a failure reason runs to 120.
const ALERT_BODY_MAX = 200;
const SUMMARY_BODY_MAX = 400;
const SUMMARY_PREVIEW = 3;
// "Kamu push ke … setelah … review. Kirim pesan Teams?" plus these two stays within BODY_MAX.
const REREVIEW_TITLE_MAX = 50;
const REREVIEW_NAMES_MAX = 60;
const MESSAGE_URL = "suica://message";
const MESSAGES_URL = "suica://messages";

const STATE_PHRASES: Readonly<Record<string, string>> = {
  APPROVED: "menyetujui",
  UNAPPROVED: "membatalkan persetujuan",
  REQUESTED_CHANGES: "meminta perubahan",
  REVIEWED: "memberi review",
};

// Control and format characters, except a zero-width joiner between two emoji, which is part of
// one (👩‍💻).
const INVISIBLE =
  /(?:(?!(?<=\p{Extended_Pictographic}(?:\u{FE0F}|\p{Emoji_Modifier})?)\u200D(?=\p{Extended_Pictographic}))[\p{Cc}\p{Cf}])+/gu;

/**
 * Single line, no control or invisible formatting characters (bidi overrides, zero-width), never
 * starting with `-`, at most `maxLength` code points.
 */
export function clean(text: string, maxLength = 120): string {
  const flat = text
    .replace(INVISIBLE, " ")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/^-+\s*/, "");
  const characters = [...flat];
  return characters.length <= maxLength ? flat : `${characters.slice(0, maxLength - 1).join("")}…`;
}

function describeState(state: ReviewState): string {
  return STATE_PHRASES[state] ?? `mengubah status review ke ${state}`;
}

/**
 * The alert `name` with `values` filled in, title and body each cleaned to one line. Values are
 * plain text: a notification shows no Markdown.
 */
export function renderAlert(
  alerts: AlertTemplates,
  name: AlertName,
  values: Readonly<Record<string, string>>,
  bodyMax = ALERT_BODY_MAX,
): Notification {
  const { title, body } = splitAlert(alerts[name]);
  return {
    title: clean(fillText(title, values), ALERT_TITLE_MAX),
    body: clean(fillText(body, values), bodyMax),
  };
}

function mrValues(mr: MergeRequest): Record<string, string> {
  return {
    "mr.title": clean(mr.title, TITLE_MAX),
    "mr.iid": String(mr.iid),
    "mr.project": clean(mr.projectPath),
    "mr.url": mr.url,
  };
}

function reviewRequestNotifications(
  events: readonly ActivityEvent[],
  alerts: AlertTemplates,
): Notification[] {
  const result: Notification[] = [];
  for (const event of events) {
    if (event.kind !== "review-requested") continue;
    const values = { ...mrValues(event.mr), "author.name": clean(event.mr.author.name) };
    result.push({
      ...renderAlert(alerts, "alert.review-requested", values, BODY_MAX),
      url: event.mr.url,
    });
  }
  return result;
}

interface AuthoredGroup {
  readonly mr: MergeRequest;
  readonly stateChanges: string[];
  readonly commenters: Set<string>;
  comments: number;
}

function authoredNotifications(
  events: readonly ActivityEvent[],
  alerts: AlertTemplates,
): Notification[] {
  const groups = new Map<string, AuthoredGroup>();
  const groupFor = (mr: MergeRequest): AuthoredGroup => {
    const existing = groups.get(mr.key);
    if (existing !== undefined) return existing;
    const created: AuthoredGroup = { mr, stateChanges: [], commenters: new Set(), comments: 0 };
    groups.set(mr.key, created);
    return created;
  };
  for (const event of events) {
    if (event.kind === "reviewer-state") {
      groupFor(event.mr).stateChanges.push(
        `${clean(event.reviewer.name, NAME_MAX)} ${describeState(event.to)}`,
      );
    } else if (event.kind === "comment") {
      const group = groupFor(event.mr);
      group.comments += 1;
      group.commenters.add(clean(event.author.name, NAME_MAX));
    }
  }
  return [...groups.values()].map((group) => {
    const parts = [...group.stateChanges];
    if (group.comments > 0) {
      parts.push(`${group.comments} komentar baru dari ${[...group.commenters].join(", ")}`);
    }
    const values = { ...mrValues(group.mr), "activity.summary": parts.join("; ") };
    return { ...renderAlert(alerts, "alert.activity", values, BODY_MAX), url: group.mr.url };
  });
}

function summarise(notifications: readonly Notification[], alerts: AlertTemplates): Notification {
  const shown = notifications
    .slice(0, SUMMARY_PREVIEW)
    .map((notification) => notification.title)
    .join(" | ");
  const rest = notifications.length - SUMMARY_PREVIEW;
  const values = {
    "alert.count": String(notifications.length),
    "alert.titles": rest > 0 ? `${shown} +${rest} lainnya` : shown,
  };
  return renderAlert(alerts, "alert.summary", values, SUMMARY_BODY_MAX);
}

export function buildNotifications(
  events: readonly ActivityEvent[],
  summaryThreshold: number,
  alerts: AlertTemplates = DEFAULT_ALERTS,
): Notification[] {
  const notifications = [
    ...reviewRequestNotifications(events, alerts),
    ...authoredNotifications(events, alerts),
  ];
  return notifications.length > summaryThreshold
    ? [summarise(notifications, alerts)]
    : notifications;
}

export function baselineNotifications(
  pending: number,
  alerts: AlertTemplates = DEFAULT_ALERTS,
): Notification[] {
  return pending === 0
    ? []
    : [renderAlert(alerts, "alert.baseline", { "alert.count": String(pending) })];
}

function joinNames(names: readonly string[]): string {
  const rest = names.slice(0, -1);
  const last = names.at(-1) ?? "";
  return rest.length === 0 ? last : `${rest.join(", ")} dan ${last}`;
}

/**
 * One notification per MR for Re-review Nudges that now wait for the Owner. A click opens the
 * message in the app, or the message list when several Reviewers are waiting on the same MR.
 */
export function rereviewNotifications(
  held: readonly HeldMessage[],
  alerts: AlertTemplates = DEFAULT_ALERTS,
): Notification[] {
  const byMr = new Map<string, HeldMessage[]>();
  for (const message of held) {
    if (message.kind !== "rereview") continue;
    byMr.set(message.mrKey, [...(byMr.get(message.mrKey) ?? []), message]);
  }
  const notifications: Notification[] = [];
  for (const messages of byMr.values()) {
    const [first] = messages;
    if (first === undefined) continue;
    const names = joinNames(messages.map((message) => clean(message.recipientName, NAME_MAX)));
    const values = {
      "mr.title": clean(first.mrTitle, REREVIEW_TITLE_MAX),
      "reviewers.names": clean(names, REREVIEW_NAMES_MAX),
    };
    notifications.push({
      ...renderAlert(alerts, "alert.rereview", values),
      url: messages.length === 1 ? `${MESSAGE_URL}/${first.id}` : MESSAGES_URL,
    });
  }
  return notifications;
}
