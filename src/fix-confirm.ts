import { rmSync } from "node:fs";
import { z } from "zod";
import { DEFAULT_ALERTS } from "./alerts.ts";
import { execFailure } from "./exec.ts";
import { NOT_YOURS, fixDir, fixPaths, gitAt } from "./fix-runner.ts";
import type { FixDeps } from "./fix-runner.ts";
import type { FixPipeline, FixRow, FixThread } from "./fix-store.ts";
import { clean, renderAlert } from "./format.ts";
import type { PostRunner } from "./gitlab.ts";
import type { ActivityLine } from "./sql-row.ts";
import { fetchMrDetail, parseMrKey } from "./reviews.ts";
import type { Store } from "./store.ts";

export interface ConfirmDeps extends Pick<
  FixDeps,
  | "store"
  | "exec"
  | "graphql"
  | "rest"
  | "notifier"
  | "log"
  | "now"
  | "statePath"
  | "alerts"
  | "owner"
> {
  readonly config: Pick<FixDeps["config"], "gitlab">;
  readonly post: PostRunner;
}

/** What the Owner changed before confirming: the commit message, and each reply and whether to post it. */
export interface ConfirmEdits {
  readonly commitMessage: string;
  readonly threads: readonly { id: string; reply: string; post: boolean }[];
}

export type ConfirmOutcome =
  "pushed" | "partial" | "branch-moved" | "push-failed" | "not-yours" | "bad-request" | "nothing";

const PUSH_TIMEOUT_MS = 5 * 60_000;
const GIT_TIMEOUT_MS = 60_000;
/** Longer than any live confirm: the app stops `suica fix confirm` after 10 minutes. */
const CONFIRM_STALE_MS = 15 * 60_000;
const DISCUSSION_ID = /^gid:\/\/gitlab\/Discussion\/([0-9a-f]+)$/;
const BRANCH_MOVED =
  "The branch moved since the fix was made; retry to redo it on the new commits.";

const editsSchema = z.object({
  commitMessage: z.string(),
  threads: z.array(z.object({ id: z.string(), reply: z.string(), post: z.boolean() })),
});

export function parseConfirmEdits(text: string): ConfirmEdits | undefined {
  try {
    const parsed = editsSchema.safeParse(JSON.parse(text));
    return parsed.success ? parsed.data : undefined;
  } catch {
    return undefined;
  }
}

/** The fix's threads with the Owner's edits; undefined when an edit names a thread the fix does not have. */
function applyEdits(row: FixRow, edits: ConfirmEdits): FixThread[] | undefined {
  const known = new Set(row.threads.map((each) => each.id));
  if (edits.threads.some((each) => !known.has(each.id))) return undefined;
  const byId = new Map(edits.threads.map((each) => [each.id, each]));
  return row.threads.map((thread): FixThread => {
    const edit = byId.get(thread.id);
    if (edit === undefined) return thread;
    const reply = edit.reply.trim();
    return { ...thread, reply, post: edit.post && reply !== "" };
  });
}

function pushFailure(stderr: string, code: string): string {
  if (/rejected|non-fast-forward|fetch first/.test(stderr)) {
    return "GitLab refused the push because the branch has newer commits; retry to redo the fix on them.";
  }
  if (stderr.includes("Permission denied")) return "SSH access to GitLab was refused.";
  return `the push failed (code ${code})`;
}

function removeCheckout(deps: Pick<ConfirmDeps, "statePath">, id: number): void {
  rmSync(fixDir(deps.statePath, id), { recursive: true, force: true });
}

/** Posts each reply still to post, one by one; returns the threads with `posted` set. */
/**
 * GitLab runs a line that starts with `/` in a note as a quick action (`/merge`, `/close`, …) as
 * the poster; a backslash keeps it text, so a reply never acts as the Owner.
 */
export function escapeQuickActions(text: string): string {
  return text.replace(/^(\s*)\//gm, "$1\\/");
}

/**
 * Posts each reply still to post, one by one, and stores each as posted as soon as GitLab took
 * it, so a confirm cut off halfway never posts that reply again. Returns the threads.
 */
async function postReplies(
  deps: ConfirmDeps,
  row: FixRow,
  threads: readonly FixThread[],
  sha: string | null,
): Promise<FixThread[]> {
  const parts = parseMrKey(row.mrKey);
  const out = [...threads];
  for (const [index, thread] of threads.entries()) {
    const discussion = DISCUSSION_ID.exec(thread.id)?.[1];
    if (!thread.post || thread.posted || parts === undefined || discussion === undefined) continue;
    const body = escapeQuickActions(
      thread.reply.replaceAll("{{sha}}", sha === null ? "" : sha.slice(0, 8)),
    );
    try {
      await deps.post(
        `projects/${encodeURIComponent(parts.projectPath)}/merge_requests/${parts.iid}/discussions/${discussion}/notes`,
        { body },
      );
      out[index] = { ...thread, posted: true };
      deps.store.fixes.transition(
        row.id,
        ["confirming"],
        "confirming",
        { threads: out },
        deps.now(),
      );
    } catch (error) {
      deps.log.warn("fix reply failed", {
        id: row.id,
        mr_key: row.mrKey,
        reason: error instanceof Error ? error.name : "unknown",
      });
    }
  }
  return out;
}

function replyDetail(threads: readonly FixThread[]): { detail: string; complete: boolean } {
  const wanted = threads.filter((each) => each.post);
  const posted = wanted.filter((each) => each.posted).length;
  return posted === wanted.length
    ? { detail: "", complete: true }
    : { detail: `${posted} of ${wanted.length} replies posted.`, complete: false };
}

async function notifyPartial(deps: ConfirmDeps, row: FixRow): Promise<void> {
  try {
    await deps.notifier.notify(
      renderAlert(deps.alerts ?? DEFAULT_ALERTS, "alert.fix-pushed", {
        "mr.title": clean(row.mrTitle ?? row.mrKey, 80),
      }),
    );
  } catch (error) {
    deps.log.warn("agent fix notification failed", {
      code: String(execFailure(error).code ?? "unknown"),
    });
  }
}

/**
 * Commits the ready fix with the Owner's edits, pushes it as a fast-forward and posts one reply per
 * thread the Owner kept. Nothing reaches GitLab when the branch moved since the fix was made. A
 * reply that fails never undoes the push: the fix is pushed with the replies still to post.
 */
export async function confirmFix(
  deps: ConfirmDeps,
  id: number,
  edits: ConfirmEdits,
): Promise<ConfirmOutcome> {
  const { store, log } = deps;
  const row = store.fixes.get(id);
  if (row?.status !== "ready") return "nothing";
  const threads = applyEdits(row, edits);
  if (threads === undefined) return "bad-request";
  const commitMessage = edits.commitMessage.trim() || row.commitMessage;
  if (
    !store.fixes.transition(id, ["ready"], "confirming", { threads, commitMessage }, deps.now())
  ) {
    return "nothing";
  }
  // A fix that could not be pushed keeps its threads quiet: Retry redoes it, no automatic fix
  // runs beside it.
  const fail = (detail: string): void => {
    store.fixes.transition(id, ["confirming"], "push-failed", { detail }, deps.now());
    store.fixes.markHandled(row.mrKey, row.threads);
    removeCheckout(deps, id);
  };
  try {
    const detail = await fetchMrDetail(deps.graphql, deps.rest, row.mrKey);
    if (detail.author.username !== (await deps.owner())) {
      fail(NOT_YOURS);
      log.warn("fix push failed", { id, mr_key: row.mrKey, reason: "not-yours" });
      return "not-yours";
    }
    if (detail.headSha !== row.baseSha) {
      fail(BRANCH_MOVED);
      log.info("fix push failed", { id, mr_key: row.mrKey, reason: "branch-moved" });
      return "branch-moved";
    }
    let sha: string | null = null;
    if ((row.diff ?? "") !== "") {
      const at = gitAt(fixPaths(deps.statePath, id));
      try {
        await deps.exec("git", [...at, "commit", "-q", "-m", commitMessage], {
          timeoutMs: GIT_TIMEOUT_MS,
        });
      } catch (error) {
        const code = String(execFailure(error).code ?? "unknown");
        fail(`the commit failed (code ${code}); check that git has your user.name and user.email`);
        log.warn("fix push failed", { id, mr_key: row.mrKey, reason: "commit" });
        return "push-failed";
      }
      try {
        // The branch name comes from GitLab and travels inside one refspec argument.
        await deps.exec(
          "git",
          [...at, "push", "origin", `HEAD:refs/heads/${detail.sourceBranch}`],
          {
            timeoutMs: PUSH_TIMEOUT_MS,
          },
        );
      } catch (error) {
        const failure = execFailure(error);
        fail(pushFailure(failure.stderr ?? "", String(failure.code ?? "unknown")));
        log.warn("fix push failed", { id, mr_key: row.mrKey, reason: "push" });
        return "push-failed";
      }
      const { stdout } = await deps.exec("git", [...at, "rev-parse", "HEAD"], {
        timeoutMs: GIT_TIMEOUT_MS,
      });
      sha = stdout.trim();
      store.fixes.transition(id, ["confirming"], "confirming", { pushedSha: sha }, deps.now());
    }
    const posted = await postReplies(deps, row, threads, sha);
    const { detail: note, complete } = replyDetail(posted);
    store.fixes.transition(
      id,
      ["confirming"],
      "pushed",
      { threads: posted, detail: note },
      deps.now(),
    );
    store.fixes.markHandled(row.mrKey, posted);
    removeCheckout(deps, id);
    log.info("fix pushed", {
      id,
      mr_key: row.mrKey,
      ...(sha === null ? {} : { pushed_sha: sha }),
      replies: posted.filter((each) => each.posted).length,
      replies_wanted: posted.filter((each) => each.post).length,
    });
    if (!complete) await notifyPartial(deps, row);
    return complete ? "pushed" : "partial";
  } catch (error) {
    fail(`the confirm failed (${error instanceof Error ? error.name : "unknown"}); check GitLab`);
    log.warn("fix push failed", {
      id,
      mr_key: row.mrKey,
      reason: error instanceof Error ? error.name : "unknown",
    });
    return "push-failed";
  }
}

/** Posts the replies a pushed fix could not post before. */
export async function postMissingReplies(
  deps: ConfirmDeps,
  id: number,
): Promise<"pushed" | "partial" | "nothing"> {
  const row = deps.store.fixes.get(id);
  if (row?.status !== "pushed" || !row.threads.some((each) => each.post && !each.posted)) {
    return "nothing";
  }
  // confirming keeps a second click from posting the same replies twice.
  if (!deps.store.fixes.transition(id, ["pushed"], "confirming", {}, deps.now())) return "nothing";
  const posted = await postReplies(deps, row, row.threads, row.pushedSha);
  const { detail, complete } = replyDetail(posted);
  deps.store.fixes.transition(
    id,
    ["confirming"],
    "pushed",
    { threads: posted, detail },
    deps.now(),
  );
  return complete ? "pushed" : "partial";
}

const cleared = (thread: FixThread): FixThread => ({
  ...thread,
  action: null,
  reply: "",
  post: false,
  posted: false,
});

/**
 * Drops a ready, failed or push-failed fix and queues a new one by hand for the same threads and
 * pipeline, with the Owner's note; it checks out the branch afresh and reads the pipeline's jobs
 * again. Returns the new fix's id.
 */
export type RetryOutcome = { status: "queued"; id: number } | { status: "busy" | "nothing" };

export function retryFix(
  deps: Pick<ConfirmDeps, "store" | "statePath" | "now">,
  id: number,
  note: string,
): RetryOutcome {
  const row = deps.store.fixes.get(id);
  if (row === undefined || !["ready", "failed", "push-failed"].includes(row.status)) {
    return { status: "nothing" };
  }
  // Another fix of the MR is open: retrying now would drop this row and queue nothing.
  const open = deps.store.fixes.open(row.mrKey);
  if (open !== undefined && open.id !== id) return { status: "busy" };
  if (
    !deps.store.fixes.transition(
      id,
      ["ready", "failed", "push-failed"],
      "discarded",
      {},
      deps.now(),
    )
  ) {
    return { status: "nothing" };
  }
  removeCheckout(deps, id);
  const next = deps.store.fixes.queue(
    row.mrKey,
    "manual",
    row.threads.map(cleared),
    deps.now(),
    row.mrTitle ?? undefined,
    note.trim(),
    row.pipeline === null
      ? undefined
      : { iid: row.pipeline.iid, url: row.pipeline.url, sha: null, jobs: [], summary: "" },
  );
  return next === undefined ? { status: "busy" } : { status: "queued", id: next };
}

/** Drops a fix that waits for the Owner or could not be pushed; its threads stay quiet until someone writes. */
export function discardFix(
  deps: Pick<ConfirmDeps, "store" | "statePath" | "now">,
  id: number,
): boolean {
  const row = deps.store.fixes.get(id);
  if (row === undefined) return false;
  if (!deps.store.fixes.transition(id, ["ready", "push-failed"], "discarded", {}, deps.now())) {
    return false;
  }
  deps.store.fixes.markHandled(row.mrKey, row.threads);
  removeCheckout(deps, id);
  return true;
}

/**
 * Stops a queued or running fix; the background agent stops a running one within seconds. Its
 * threads stay quiet until someone writes on them, so the next poll does not queue them again.
 */
export function cancelFix(store: Store, id: number, now: number): boolean {
  const row = store.fixes.get(id);
  const done = store.fixes.transition(
    id,
    ["queued", "running"],
    "cancelled",
    { detail: "Cancelled by you." },
    now,
  );
  if (done && row !== undefined) store.fixes.markHandled(row.mrKey, row.threads);
  return done;
}

/** Ends confirms cut off by a crash: pushed when the push went out, else push-failed. */
export function recoverStaleConfirms(store: Store, now: number): number {
  let recovered = 0;
  for (const row of store.fixes.list(Number.MAX_SAFE_INTEGER)) {
    if (row.status !== "confirming" || row.updatedAt > now - CONFIRM_STALE_MS) continue;
    const done =
      // A fix with code to push that never recorded the push did not push; a reply-only fix
      // had nothing to push.
      row.pushedSha === null && (row.diff ?? "") !== ""
        ? store.fixes.transition(
            row.id,
            ["confirming"],
            "push-failed",
            { detail: "Suica stopped while pushing. Check the branch in GitLab before you retry." },
            now,
          )
        : store.fixes.transition(
            row.id,
            ["confirming"],
            "pushed",
            { detail: "Suica stopped while posting replies; post the missing ones." },
            now,
          );
    if (done) recovered += 1;
  }
  return recovered;
}

/** One fix in `suica fix list --json`. See contracts/fixes.v1.json. */
export interface FixJson {
  readonly id: number;
  readonly mrKey: string;
  readonly mrTitle: string | null;
  readonly status: FixRow["status"];
  readonly threads: readonly FixThread[];
  /** The failed pipeline it fixes; null for a fix of threads only. */
  readonly pipeline: FixPipeline | null;
  readonly note: string;
  readonly baseSha: string | null;
  readonly commitMessage: string;
  /** Only while the fix waits for the Owner. */
  readonly diff: string | null;
  readonly pushedSha: string | null;
  readonly cli: string | null;
  readonly model: string | null;
  readonly detail: string;
  readonly activity: readonly ActivityLine[];
  readonly createdAt: number;
  readonly updatedAt: number;
  readonly startedAt: number | null;
}

export interface FixListJson {
  readonly version: 1;
  readonly fixes: readonly FixJson[];
}

export function toFixJson(row: FixRow): FixJson {
  return {
    id: row.id,
    mrKey: row.mrKey,
    mrTitle: row.mrTitle,
    status: row.status,
    threads: row.threads,
    pipeline: row.pipeline,
    note: row.note,
    baseSha: row.baseSha,
    commitMessage: row.commitMessage,
    diff: row.status === "ready" ? row.diff : null,
    pushedSha: row.pushedSha,
    cli: row.cli,
    model: row.model,
    detail: row.detail,
    activity: row.activity,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    startedAt: row.startedAt,
  };
}

export function buildFixList(rows: readonly FixRow[]): FixListJson {
  return { version: 1, fixes: rows.map(toFixJson) };
}
