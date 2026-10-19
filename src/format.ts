import type { ActivityEvent } from "./events.ts";
import type { MergeRequest, ReviewState } from "./domain.ts";
import type { HeldMessage } from "./teams/types.ts";

export interface Notification {
  readonly title: string;
  readonly body: string;
  readonly url?: string;
}

const TITLE_MAX = 80;
const NAME_MAX = 40;
const BODY_MAX = 160;
const SUMMARY_PREVIEW = 3;
// "Kamu push ke … setelah … review. Kirim pesan Teams?" plus these two stays within BODY_MAX.
const REREVIEW_TITLE_MAX = 50;
const REREVIEW_NAMES_MAX = 60;
const REREVIEW_TITLE = "Minta review ulang?";
const MESSAGE_URL = "suica://message";
const MESSAGES_URL = "suica://messages";

const STATE_PHRASES: Readonly<Record<string, string>> = {
  APPROVED: "menyetujui",
  UNAPPROVED: "membatalkan persetujuan",
  REQUESTED_CHANGES: "meminta perubahan",
  REVIEWED: "memberi review",
};

/**
 * Single line, no control or invisible formatting characters (bidi overrides, zero-width), never
 * starting with `-`, at most `maxLength` code points.
 */
export function clean(text: string, maxLength = 120): string {
  const flat = text
    .replace(/[\p{Cc}\p{Cf}]+/gu, " ")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/^-+\s*/, "");
  const characters = [...flat];
  return characters.length <= maxLength ? flat : `${characters.slice(0, maxLength - 1).join("")}…`;
}

function describeState(state: ReviewState): string {
  return STATE_PHRASES[state] ?? `mengubah status review ke ${state}`;
}

function reviewRequestNotifications(events: readonly ActivityEvent[]): Notification[] {
  const result: Notification[] = [];
  for (const event of events) {
    if (event.kind !== "review-requested") continue;
    result.push({
      title: `Diminta review: ${clean(event.mr.title, TITLE_MAX)}`,
      body: clean(`${event.mr.author.name} · ${event.mr.projectPath}`, BODY_MAX),
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

function authoredNotifications(events: readonly ActivityEvent[]): Notification[] {
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
    return {
      title: `!${group.mr.iid}: ${clean(group.mr.title, TITLE_MAX)}`,
      body: clean(parts.join("; "), BODY_MAX),
      url: group.mr.url,
    };
  });
}

function summarise(notifications: readonly Notification[]): Notification {
  const shown = notifications
    .slice(0, SUMMARY_PREVIEW)
    .map((notification) => notification.title)
    .join(" | ");
  const rest = notifications.length - SUMMARY_PREVIEW;
  return {
    title: `${notifications.length} aktivitas MR baru`,
    body: rest > 0 ? `${shown} +${rest} lainnya` : shown,
  };
}

export function buildNotifications(
  events: readonly ActivityEvent[],
  summaryThreshold: number,
): Notification[] {
  const notifications = [...reviewRequestNotifications(events), ...authoredNotifications(events)];
  return notifications.length > summaryThreshold ? [summarise(notifications)] : notifications;
}

export function baselineNotifications(pending: number): Notification[] {
  return pending === 0 ? [] : [{ title: "Suica aktif", body: `${pending} MR menunggu review-mu` }];
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
export function rereviewNotifications(held: readonly HeldMessage[]): Notification[] {
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
    notifications.push({
      title: REREVIEW_TITLE,
      body: `Kamu push ke ${clean(first.mrTitle, REREVIEW_TITLE_MAX)} setelah ${clean(names, REREVIEW_NAMES_MAX)} review. Kirim pesan Teams?`,
      url: messages.length === 1 ? `${MESSAGE_URL}/${first.id}` : MESSAGES_URL,
    });
  }
  return notifications;
}
