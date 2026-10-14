import type { ActivityEvent } from "./events.ts";
import type { MergeRequest, ReviewState } from "./domain.ts";

export interface Notification {
  readonly title: string;
  readonly body: string;
  readonly url?: string;
}

const TITLE_MAX = 80;
const NAME_MAX = 40;
const BODY_MAX = 160;
const SUMMARY_PREVIEW = 3;

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
  return pending === 0
    ? []
    : [{ title: "MR Review Assistant aktif", body: `${pending} MR menunggu review-mu` }];
}
