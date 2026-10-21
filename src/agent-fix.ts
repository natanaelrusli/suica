import type { Config } from "./config.ts";
import { APPROVED } from "./domain.ts";
import type { MergeRequest, Snapshot } from "./domain.ts";
import type { FixRow, FixStatus, FixThread } from "./fix-store.ts";
import type { Logger } from "./log.ts";
import { parseMrKey } from "./reviews.ts";
import type { MrDetailJson } from "./reviews.ts";
import type { Store } from "./store.ts";

const DAY_MS = 86_400_000;
const OPEN: readonly FixStatus[] = ["queued", "running", "ready", "confirming"];
const GONE = "The MR is no longer open.";

export interface FixQueueDeps {
  readonly store: Store;
  readonly config: Pick<Config, "fix">;
  readonly log: Logger;
  readonly now: () => number;
  /** The MR's detail, with its discussions. May throw. */
  readonly detail: (key: string) => Promise<MrDetailJson>;
}

/** Watching stops once the MR has Reviewers and every one of them approved. */
export function isApprovedByAll(mr: MergeRequest): boolean {
  return mr.reviewers.length > 0 && mr.reviewers.every((each) => each.state === APPROVED);
}

/**
 * The Finding Threads of an MR: resolvable, unresolved, and newest note written by someone other
 * than `me` (bots too). A thread handled at its newest note is left out, unless the Owner asks by
 * hand (`"manual"`).
 */
export function findingThreads(
  detail: MrDetailJson,
  me: string,
  handled: ReadonlyMap<string, string> | "manual",
): FixThread[] {
  return detail.discussions.flatMap((discussion): FixThread[] => {
    const notes = discussion.notes.filter((each) => !each.system);
    const first = notes[0];
    const newest = notes.at(-1);
    if (!discussion.resolvable || discussion.resolved || first === undefined) return [];
    if (newest === undefined || newest.author.username === me) return [];
    if (handled !== "manual" && handled.get(discussion.id) === newest.id) return [];
    return [
      {
        id: discussion.id,
        noteId: newest.id,
        author: first.author,
        filePath: first.filePath,
        line: first.line,
        notes: notes.map((each) => ({
          author: each.author,
          body: each.body,
          createdAt: each.createdAt,
        })),
        action: null,
        reply: "",
        post: false,
        posted: false,
      },
    ];
  });
}

function errorName(error: unknown): string {
  return error instanceof Error ? error.name : "unknown";
}

/** True when the MR should be read again: someone else wrote, it was never read, or its fix ended since. */
function needsLook(
  mr: MergeRequest,
  me: string,
  seenNotes: ReadonlySet<string>,
  checkedAt: number | undefined,
  latest: FixRow | undefined,
): boolean {
  if (checkedAt === undefined) return true;
  if (
    mr.notes.some((each) => !each.system && each.author.username !== me && !seenNotes.has(each.id))
  )
    return true;
  return latest !== undefined && !OPEN.includes(latest.status) && latest.updatedAt >= checkedAt;
}

/** Ends the fixes of MRs that left the snapshot: merged or closed. */
function dropGone(
  deps: FixQueueDeps,
  open: readonly FixRow[],
  authored: ReadonlySet<string>,
): void {
  for (const row of open.filter((each) => !authored.has(each.mrKey))) {
    const now = deps.now();
    const dropped =
      deps.store.fixes.transition(
        row.id,
        ["queued", "running"],
        "cancelled",
        { detail: GONE },
        now,
      ) || deps.store.fixes.transition(row.id, ["ready"], "discarded", { detail: GONE }, now);
    if (dropped)
      deps.log.info("agent fix cancelled", { id: row.id, mr_key: row.mrKey, reason: "closed" });
  }
}

/**
 * After a poll: queues an Agent Fix for each of the Owner's open, not yet approved MRs that has new
 * Finding Threads. An MR is read only when someone else wrote since the last poll, it was never
 * read, or its last fix ended since it was read (threads that waited behind it). Threads join a
 * fix that is still queued; an MR whose fix runs or waits for the Owner is read once that fix ends.
 * Never throws for one MR's sake.
 */
export async function queueAutomaticFixes(
  deps: FixQueueDeps,
  snapshot: Snapshot,
  seenNotes: ReadonlySet<string>,
): Promise<void> {
  const { store, log } = deps;
  dropGone(
    deps,
    store.fixes.list(Number.MAX_SAFE_INTEGER),
    new Set(snapshot.authored.map((mr) => mr.key)),
  );
  if (!deps.config.fix.auto) return;
  const me = snapshot.me.username;
  const marks = store.fixes.watchMarks();
  const latest = store.fixes.latestByMr();
  for (const mr of snapshot.authored) {
    const open = store.fixes.open(mr.key);
    if (isApprovedByAll(mr)) {
      // Read again once it is watched again: threads written while approved are seen by then.
      store.fixes.unwatch(mr.key);
      if (
        open?.status === "queued" &&
        store.fixes.transition(
          open.id,
          ["queued"],
          "cancelled",
          { detail: "The MR was approved." },
          deps.now(),
        )
      ) {
        log.info("agent fix cancelled", { id: open.id, mr_key: mr.key, reason: "approved" });
      }
      continue;
    }
    if (open !== undefined && open.status !== "queued") continue;
    if (!needsLook(mr, me, seenNotes, marks.get(mr.key), latest.get(mr.key))) continue;
    if (
      open === undefined &&
      store.fixes.countAuto(deps.now() - DAY_MS) >= deps.config.fix.maxPerDay
    ) {
      // Read again once the limit allows, so the threads are not lost.
      store.fixes.unwatch(mr.key);
      log.warn("agent fix daily cap reached", { mr_key: mr.key });
      continue;
    }
    let detail: MrDetailJson;
    try {
      detail = await deps.detail(mr.key);
    } catch (error) {
      store.fixes.unwatch(mr.key);
      log.warn("agent fix detail failed", { mr_key: mr.key, reason: errorName(error) });
      continue;
    }
    const now = deps.now();
    store.fixes.markWatched(mr.key, now);
    const threads = findingThreads(detail, me, store.fixes.handledNotes(mr.key));
    if (threads.length === 0) continue;
    const id = store.fixes.queue(mr.key, "auto", threads, now, mr.title);
    if (id !== undefined)
      log.info("agent fix queued", { id, mr_key: mr.key, threads: threads.length });
  }
}

export type ManualFixOutcome =
  "queued" | "added" | "busy" | "nothing-to-fix" | "not-yours" | "bad-key";

/**
 * Queues a fix the Owner asked for, of every open thread whose newest note is someone else's,
 * handled before or not. Only on an MR the Owner (`me`) wrote.
 */
export async function queueManualFix(
  deps: Pick<FixQueueDeps, "store" | "log" | "now" | "detail">,
  key: string,
  me: string,
): Promise<ManualFixOutcome> {
  if (parseMrKey(key) === undefined) return "bad-key";
  const detail = await deps.detail(key);
  if (detail.author.username !== me) return "not-yours";
  const threads = findingThreads(detail, me, "manual");
  if (threads.length === 0) return "nothing-to-fix";
  const open = deps.store.fixes.open(key);
  const id = deps.store.fixes.queue(key, "manual", threads, deps.now(), detail.title);
  if (id === undefined) return "busy";
  deps.log.info("agent fix queued", {
    id,
    mr_key: key,
    threads: threads.length,
    trigger: "manual",
  });
  return open === undefined ? "queued" : "added";
}
