import { findingThreads } from "../agent-fix.ts";
import type { Snapshot } from "../domain.ts";
import type { FixThread } from "../fix-store.ts";
import { extractFindings } from "../inline-review.ts";
import type { NewOccurrence, Outcome } from "../lesson-store.ts";
import type { Logger } from "../log.ts";
import type { MrDetailJson } from "../reviews.ts";
import type { AgentReviewRow, AgentReviewStatus, Store } from "../store.ts";
import { projectOfMrKey, scopeForProject } from "./scopes.ts";
import type { ScopeMap } from "./scopes.ts";

/**
 * Where Lessons come from: the findings of Agent Reviews and the Finding Threads of the Owner's
 * own MRs, each stored once as an occurrence keyed by its source.
 */

const TITLE_MAX = 120;
const REVIEW_CURSOR = "lessons.reviewCursor";
const THREADS_BACKFILLED = "lessons.threadsBackfilled";
/** Reviews whose findings are learned; a skipped or discarded review's findings still teach. */
const COLLECTED: readonly AgentReviewStatus[] = ["ready", "posted", "discarded"];
/** Reviews that may still become ready: the cursor waits for them. */
const UNSETTLED: readonly AgentReviewStatus[] = ["queued", "running", "posting"];

export interface CollectOptions {
  /** `gitlab.hostname`, for the MR links; the links stay empty without it. */
  readonly hostname?: string;
  /** Fills each occurrence's repository checkout. */
  readonly scopes?: ScopeMap;
}

/** The first line of a finding, without bold markers, at most TITLE_MAX characters. */
function titleOf(text: string): string {
  const line = (text.trim().split("\n")[0] ?? "").replace(/\*\*|__/g, "").trim();
  return line.length <= TITLE_MAX ? line : `${line.slice(0, TITLE_MAX - 1)}…`;
}

/** A severity a thread's first words name (`**Major**: …`), capitalised; "" when none. */
function severityOfText(text: string): string {
  const word = /^\W*(blocker|critical|major|minor|nit)\b/i.exec(text)?.[1];
  return word === undefined ? "" : word.charAt(0).toUpperCase() + word.slice(1).toLowerCase();
}

function mrUrlOf(hostname: string | undefined, key: string): string {
  const bang = key.lastIndexOf("!");
  if (hostname === undefined || bang < 0) return "";
  return `https://${hostname}/${key.slice(0, bang)}/-/merge_requests/${key.slice(bang + 1)}`;
}

function withRepo(rows: readonly NewOccurrence[], scopes: ScopeMap | undefined): NewOccurrence[] {
  return rows.map((row) => ({
    ...row,
    repoPath:
      scopes === undefined
        ? null
        : (scopeForProject(scopes, projectOfMrKey(row.mrKey))?.dir ?? null),
  }));
}

const HEADING = /^(#{1,6})\s+(.*)$/;
const FENCE = /^\s*(```|~~~)/;
const LIST_ITEM = /^( *)(?:\d+[.)]|[-*+])\s+(.*)$/;
const LOCATION = /`([^`\s]+):\d+(?:[-–]\d+)?`(.*)$/;
const VERDICTS = "not\\s+fixed|unfixed|(?:partly|partially)\\s+fixed|fixed";
/** The verdict after a separator (`title — fixed`), else the first one named. */
const VERDICT_AFTER_SEPARATOR = new RegExp(
  `\\s(?:[—–:]|-{1,2})\\s*(?:\\*\\*)?(${VERDICTS})\\b`,
  "i",
);
const VERDICT = new RegExp(`\\b(${VERDICTS})\\b`, "i");

function outcomeOf(verdict: string): Outcome {
  const word = verdict.toLowerCase();
  if (word.startsWith("not") || word === "unfixed") return "not-fixed";
  return word === "fixed" ? "fixed" : "partly-fixed";
}

/** `<severity> `path:line` title — fixed|not fixed|partly fixed` lines of a Previous review section. */
function previousVerdicts(markdown: string): { path: string; title: string; outcome: Outcome }[] {
  const verdicts: { path: string; title: string; outcome: Outcome }[] = [];
  let previousLevel: number | undefined;
  let itemIndent: number | undefined;
  let inFence = false;
  for (const line of markdown.replace(/\r\n/g, "\n").split("\n")) {
    if (FENCE.test(line)) inFence = !inFence;
    if (inFence) continue;
    const heading = HEADING.exec(line);
    if (heading !== null) {
      const level = heading[1]?.length ?? 1;
      if (previousLevel !== undefined && level > previousLevel) continue;
      previousLevel = /^\W*previous\b/i.test(heading[2] ?? "") ? level : undefined;
      itemIndent = undefined;
      continue;
    }
    const item = previousLevel === undefined ? null : LIST_ITEM.exec(line);
    if (item === null) continue;
    const indent = item[1]?.length ?? 0;
    itemIndent ??= indent;
    const located = indent === itemIndent ? LOCATION.exec(item[2] ?? "") : null;
    if (located === null) continue;
    const rest = located[2] ?? "";
    const verdict = VERDICT_AFTER_SEPARATOR.exec(rest) ?? VERDICT.exec(rest);
    if (verdict === null) continue;
    const title = rest
      .slice(0, verdict.index)
      .replace(/\*\*|__/g, "")
      .replace(/^[\s—–:-]+|[\s—–:,.-]+$/g, "");
    if (title !== "") {
      verdicts.push({ path: located[1] ?? "", title, outcome: outcomeOf(verdict[1] ?? "") });
    }
  }
  return verdicts;
}

/**
 * A review's own findings as occurrences, and the verdicts of its Previous review section, which
 * name an earlier occurrence by path and title and add none.
 */
export function occurrencesFromReview(
  row: AgentReviewRow,
  hostname?: string,
): {
  add: NewOccurrence[];
  outcomes: { mrKey: string; path: string; title: string; outcome: Outcome }[];
} {
  if (row.body === null) return { add: [], outcomes: [] };
  const used = new Set<string>();
  const add = extractFindings(row.body).map((finding, index): NewOccurrence => {
    // Numbered lists under each severity both start at 1: a repeated number takes its position.
    const number = used.has(finding.number)
      ? `${finding.number}#${String(index + 1)}`
      : finding.number;
    used.add(number);
    return {
      sourceKey: `review:${String(row.id)}:${number}`,
      source: "review",
      mrKey: row.mrKey,
      mrTitle: row.mrTitle ?? row.mrKey,
      mrUrl: mrUrlOf(hostname, row.mrKey),
      path: finding.path,
      line: finding.line,
      severity: finding.severity,
      title: titleOf(finding.text),
      text: finding.text,
      outcome: "open",
      at: row.updatedAt,
    };
  });
  const outcomes = previousVerdicts(row.body).map((verdict) => ({ mrKey: row.mrKey, ...verdict }));
  return { add, outcomes };
}

/** What the Agent Fix did for the thread. */
export function threadOutcome(thread: FixThread): Outcome {
  if (thread.action === "changed") return "changed";
  return thread.action === "reply" ? "replied" : "open";
}

function threadKey(mrKey: string, discussionId: string): string {
  return `thread:${mrKey}:${discussionId}`;
}

/** Each Finding Thread's first note as an occurrence. */
export function occurrencesFromThreads(
  mr: { key: string; title: string; url: string },
  threads: readonly FixThread[],
  at: number,
): NewOccurrence[] {
  return threads.flatMap((thread): NewOccurrence[] => {
    const first = thread.notes[0];
    if (first === undefined) return [];
    return [
      {
        sourceKey: threadKey(mr.key, thread.id),
        source: "thread",
        mrKey: mr.key,
        mrTitle: mr.title,
        mrUrl: mr.url,
        path: thread.filePath,
        line: thread.line,
        severity: severityOfText(first.body),
        title: titleOf(first.body),
        text: first.body,
        outcome: threadOutcome(thread),
        at,
      },
    ];
  });
}

/**
 * Collects the findings of ready and posted reviews after the cursor, oldest first, and applies
 * their verdicts on earlier findings. The cursor stops before a review that may still become
 * ready, so one finishing late is not skipped. Returns how many occurrences were added.
 */
export function collectReviews(store: Store, now: number, options: CollectOptions = {}): number {
  const stored = Number(store.lessons.meta(REVIEW_CURSOR) ?? "0");
  let cursor = Number.isSafeInteger(stored) ? stored : 0;
  let settled = true;
  let added = 0;
  for (const row of store.agentReviewsAfter(cursor)) {
    if (UNSETTLED.includes(row.status)) settled = false;
    if (COLLECTED.includes(row.status)) {
      const { add, outcomes } = occurrencesFromReview(row, options.hostname);
      added += store.lessons.addOccurrences(withRepo(add, options.scopes));
      for (const each of outcomes) {
        const found = store.lessons.findOccurrenceByLocation(each.mrKey, each.path, each.title);
        if (found !== undefined && found.outcome !== each.outcome) {
          store.lessons.setOutcome(found.sourceKey, each.outcome, now);
        }
      }
    }
    if (settled) cursor = row.id;
  }
  store.lessons.setMeta(REVIEW_CURSOR, String(cursor));
  return added;
}

/** The outcome each stored fix gave a thread: the newest fix that answered it wins. */
function fixOutcomes(store: Store): Map<string, Outcome> {
  const outcomes = new Map<string, Outcome>();
  for (const row of store.fixes.list(0).reverse()) {
    for (const thread of row.threads) {
      if (thread.action !== null)
        outcomes.set(threadKey(row.mrKey, thread.id), threadOutcome(thread));
    }
  }
  return outcomes;
}

/** Once: every thread stored with an Agent Fix. Returns how many occurrences were added. */
export function backfillThreads(store: Store, now: number, options: CollectOptions = {}): number {
  if (store.lessons.meta(THREADS_BACKFILLED) !== undefined) return 0;
  const outcomes = fixOutcomes(store);
  const latest = new Map<string, NewOccurrence>();
  for (const row of store.fixes.list(0).reverse()) {
    const mr = {
      key: row.mrKey,
      title: row.mrTitle ?? row.mrKey,
      url: mrUrlOf(options.hostname, row.mrKey),
    };
    for (const each of occurrencesFromThreads(mr, row.threads, row.createdAt)) {
      latest.set(each.sourceKey, {
        ...each,
        outcome: outcomes.get(each.sourceKey) ?? each.outcome,
      });
    }
  }
  const added = store.lessons.addOccurrences(withRepo([...latest.values()], options.scopes));
  store.lessons.setMeta(THREADS_BACKFILLED, String(now));
  return added;
}

export interface ThreadCollectDeps {
  readonly store: Store;
  readonly log: Logger;
  readonly now: () => number;
  /** The MR's detail, with every discussion. May throw. */
  readonly detail: (key: string) => Promise<MrDetailJson>;
}

/**
 * After a poll: reads the Finding Threads of each of the Owner's open MRs that `read` does not
 * hold yet or that has a note the previous poll did not see. A new thread is added; a stored one
 * only takes its outcome (resolved, or what a fix did). A failed read is tried at the next poll.
 */
export async function collectOpenThreads(
  deps: ThreadCollectDeps,
  options: CollectOptions,
  snapshot: Snapshot,
  seenNotes: ReadonlySet<string>,
  read: Set<string>,
): Promise<number> {
  const { store, log } = deps;
  const open = new Set(snapshot.authored.map((mr) => mr.key));
  for (const key of read) if (!open.has(key)) read.delete(key);
  const due = snapshot.authored.filter(
    (mr) => !read.has(mr.key) || mr.notes.some((each) => !seenNotes.has(each.id)),
  );
  if (due.length === 0) return 0;
  const fixed = fixOutcomes(store);
  let added = 0;
  for (const mr of due) {
    let detail: MrDetailJson;
    try {
      detail = await deps.detail(mr.key);
    } catch (error) {
      log.warn("lesson threads not read", {
        mr_key: mr.key,
        reason: error instanceof Error ? error.name : "unknown",
      });
      // The poll already counts its notes as seen: read it again at the next poll.
      read.delete(mr.key);
      continue;
    }
    read.add(mr.key);
    const now = deps.now();
    for (const discussion of detail.discussions) {
      const key = threadKey(mr.key, discussion.id);
      const stored = store.lessons.occurrenceBySource(key);
      if (stored === undefined) continue;
      const outcome = discussion.resolved ? "resolved" : (fixed.get(key) ?? stored.outcome);
      if (outcome !== stored.outcome) store.lessons.setOutcome(key, outcome, now);
    }
    const fresh = occurrencesFromThreads(
      { key: mr.key, title: mr.title, url: mr.url },
      findingThreads(detail, snapshot.me.username, "manual"),
      now,
    )
      .filter((each) => store.lessons.occurrenceBySource(each.sourceKey) === undefined)
      .map((each) => ({ ...each, outcome: fixed.get(each.sourceKey) ?? each.outcome }));
    added += store.lessons.addOccurrences(withRepo(fresh, options.scopes));
  }
  return added;
}
