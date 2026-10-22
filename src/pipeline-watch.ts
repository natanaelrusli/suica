import { isWatched } from "./agent-fix.ts";
import { DEFAULT_ALERTS } from "./alerts.ts";
import type { AlertTemplates } from "./alerts.ts";
import type { Config } from "./config.ts";
import { PIPELINE_FAILED } from "./domain.ts";
import type { MergeRequest, Pipeline, Snapshot } from "./domain.ts";
import { execFailure } from "./exec.ts";
import type { FixPipeline, PipelineMark } from "./fix-store.ts";
import { clean, renderAlert } from "./format.ts";
import type { Logger } from "./log.ts";
import type { Notifier } from "./notifier.ts";
import type { HeadPipeline } from "./pipelines.ts";
import { parseMrKey } from "./reviews.ts";
import type { Store } from "./store.ts";

const DAY_MS = 86_400_000;
const ALERT_MR_TITLE_MAX = 80;

export interface PipelineWatchDeps {
  readonly store: Store;
  readonly config: Pick<Config, "fix">;
  readonly notifier: Notifier;
  readonly log: Logger;
  readonly now: () => number;
  /** The Owner's notification texts; the built-in ones when absent. */
  readonly alerts?: AlertTemplates;
}

/** What a Pipeline Fix starts from: the pipeline, before the run reads its jobs. */
function toFixPipeline(pipeline: Pipeline): FixPipeline {
  return { iid: pipeline.iid, url: pipeline.url, sha: null, jobs: [], summary: "" };
}

/**
 * The MRs whose head pipeline failed since the last poll: a new pipeline that failed, or the same
 * one that was not failed before. An MR without a mark counts as new, except on the first watch
 * (no marks at all), so the first poll after an upgrade does not flood the Owner.
 */
export function newlyFailed(
  authored: readonly MergeRequest[],
  before: ReadonlyMap<string, PipelineMark>,
): MergeRequest[] {
  return authored.filter((mr) => {
    if (mr.pipeline?.status !== PIPELINE_FAILED) return false;
    const was = before.get(mr.key);
    if (was === undefined) return before.size > 0;
    return was.iid !== mr.pipeline.iid || was.status !== PIPELINE_FAILED;
  });
}

/** Each open MR's head pipeline; an MR that shows none for now keeps the mark it had. */
function currentMarks(
  authored: readonly MergeRequest[],
  before: ReadonlyMap<string, PipelineMark>,
): Map<string, PipelineMark> {
  const marks = new Map<string, PipelineMark>();
  for (const mr of authored) {
    const was = before.get(mr.key);
    if (mr.pipeline !== null)
      marks.set(mr.key, { iid: mr.pipeline.iid, status: mr.pipeline.status });
    else if (was !== undefined) marks.set(mr.key, was);
  }
  return marks;
}

async function notifyFailed(deps: PipelineWatchDeps, mr: MergeRequest): Promise<void> {
  try {
    await deps.notifier.notify(
      renderAlert(deps.alerts ?? DEFAULT_ALERTS, "alert.pipeline-failed", {
        "mr.title": clean(mr.title, ALERT_MR_TITLE_MAX),
        "mr.iid": String(mr.iid),
        "mr.project": mr.projectPath,
        "mr.url": mr.url,
      }),
    );
  } catch (error) {
    // Never log the error message: process errors embed the notification text.
    deps.log.warn("pipeline notification failed", {
      code: String(execFailure(error).code ?? "unknown"),
    });
  }
}

/** Queues an automatic Pipeline Fix unless the MR has a fix running or waiting, or the daily cap is reached. */
function queueAutomatic(deps: PipelineWatchDeps, mr: MergeRequest, pipeline: Pipeline): void {
  const { store, log } = deps;
  const open = store.fixes.open(mr.key);
  if (open !== undefined && open.status !== "queued") {
    log.info("pipeline fix not queued", { mr_key: mr.key, reason: "busy" });
    return;
  }
  if (
    open === undefined &&
    store.fixes.countAuto(deps.now() - DAY_MS) >= deps.config.fix.maxPerDay
  ) {
    log.warn("agent fix daily cap reached", { mr_key: mr.key });
    return;
  }
  const id = store.fixes.queue(
    mr.key,
    "auto",
    [],
    deps.now(),
    mr.title,
    "",
    toFixPipeline(pipeline),
  );
  if (id !== undefined) {
    log.info("agent fix queued", { id, mr_key: mr.key, pipeline_iid: pipeline.iid });
  }
}

/**
 * After a poll: tells the Owner about each of their MRs whose head pipeline failed since the last
 * poll and, with `fix.auto` and `fix.pipelines`, queues a Pipeline Fix for it when it is watched.
 * Records every MR's head pipeline and forgets MRs that are no longer open. Never throws.
 */
export async function watchPipelines(deps: PipelineWatchDeps, snapshot: Snapshot): Promise<void> {
  let failed: MergeRequest[];
  try {
    const before = deps.store.fixes.pipelineMarks();
    failed = newlyFailed(snapshot.authored, before);
    deps.store.fixes.savePipelineMarks(currentMarks(snapshot.authored, before));
  } catch (error) {
    deps.log.warn("pipeline watch failed", {
      reason: error instanceof Error ? error.name : "unknown",
    });
    return;
  }
  for (const mr of failed) {
    if (mr.pipeline === null) continue;
    deps.log.info("pipeline failed", { mr_key: mr.key, pipeline_iid: mr.pipeline.iid });
    await notifyFailed(deps, mr);
    if (!deps.config.fix.auto || !deps.config.fix.pipelines) continue;
    try {
      if (!isWatched(mr.key, deps.store.fixes.watchChoices(), deps.config)) {
        deps.log.info("pipeline fix not queued", { mr_key: mr.key, reason: "unwatched" });
        continue;
      }
      queueAutomatic(deps, mr, mr.pipeline);
    } catch (error) {
      deps.log.warn("pipeline fix not queued", {
        mr_key: mr.key,
        reason: error instanceof Error ? error.name : "unknown",
      });
    }
  }
}

export type PipelineFixOutcome =
  "queued" | "added" | "busy" | "no-failed-pipeline" | "not-yours" | "bad-key";

/** Queues a Pipeline Fix the Owner asked for, on an MR the Owner (`me`) wrote whose head pipeline failed. */
export async function queuePipelineFix(
  deps: {
    readonly store: Store;
    readonly log: Logger;
    readonly now: () => number;
    /** The MR's title, author and head pipeline. May throw. */
    readonly head: (key: string) => Promise<HeadPipeline>;
  },
  key: string,
  me: string,
): Promise<PipelineFixOutcome> {
  if (parseMrKey(key) === undefined) return "bad-key";
  const head = await deps.head(key);
  if (head.author !== me) return "not-yours";
  if (head.pipeline?.status !== PIPELINE_FAILED) return "no-failed-pipeline";
  const open = deps.store.fixes.open(key);
  const id = deps.store.fixes.queue(
    key,
    "manual",
    [],
    deps.now(),
    head.title,
    "",
    toFixPipeline(head.pipeline),
  );
  if (id === undefined) return "busy";
  deps.log.info("agent fix queued", {
    id,
    mr_key: key,
    pipeline_iid: head.pipeline.iid,
    trigger: "manual",
  });
  return open === undefined ? "queued" : "added";
}
