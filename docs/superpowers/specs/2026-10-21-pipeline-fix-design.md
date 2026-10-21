# Pipeline watch and Pipeline Fix — design

Status: written from the Owner's request on 2026-10-21 ("a special feature to monitor my MRs pipelines and can trigger agents to fix it"). Choices marked _my call_ are the builder's. Builds on Agent Fix (`2026-10-21-agent-fix-comment-merge-design.md` and the Agent Fix section of the README).

## What it is

- **Pipeline watch**: every poll already reads the Owner's open MRs; it now reads each one's head pipeline too (`headPipeline { iid status path }`, one GraphQL query as before). When an MR's head pipeline becomes `FAILED` (a new pipeline that failed, or the same one going from running to failed), the Owner gets a macOS notification (`alert.pipeline-failed`). An MR seen for the first time, and every MR on the first poll after the upgrade, is recorded without a notification, so an upgrade does not flood the Owner (_my call_).
- **Pipeline Fix**: an Agent Fix whose input is a failed pipeline instead of (or as well as) Finding Threads. The agent fetches the pipeline's failed jobs and the tail of each job's log, the model reads them next to the checkout of the source branch, and changes the code. Like every Agent Fix it waits for the Owner: nothing is committed or pushed until the Owner confirms, never with force, and only on the Owner's own MR.
  - **By hand**: **Fix pipeline** on one of the Owner's MRs whose head pipeline failed (the app's MR page, beside **Fix findings now**), or `suica fix queue <key> --pipeline --json`.
  - **Automatically**: when the pipeline watch sees a new failure and both `fix.auto` and the new `fix.pipelines` (default `true`) are on. Automatic Pipeline Fixes count towards `fix.maxPerDay` with the thread fixes. A failure seen while a fix of that MR is running or waits for the Owner is not queued (it is logged): the Owner can press **Fix pipeline** after (_my call_: one open fix per MR, as before).
- A fix queued while another fix of the MR is queued joins it: one run then answers the threads and fixes the pipeline, and makes one commit.

## Details

- The jobs fixed are the pipeline's failed jobs that are not allowed to fail; when every failed job is allowed to fail, all failed jobs. At most 5 jobs, each with the last 300 lines and at most 20,000 characters of its log, cleaned of colour codes, GitLab's section markers and the per-line timestamps (_my call_: the end of a log is where the error is, and the budget keeps the prompt small).
- The model works in the same sandbox as a thread fix: it reads `./pipeline.md` (the jobs and their logs, marked as untrusted data like the MR and threads) beside `./repo`, cannot run commands, tests or the network, and answers with the same JSON block plus a `pipeline` sentence: why the jobs failed and what it changed, or why no code change fixes it (a flaky test, a runner or infrastructure problem). The checkout is the branch head; the prompt names the commit the pipeline ran on.
- A Pipeline Fix with no code change and no thread to answer ends as **skipped** with the model's sentence as its note, since there is nothing to confirm.
- Job logs never reach the state database or the agent's logs: the fix keeps only the pipeline's number, link and status, each failed job's name, stage and link, and the model's sentence.
- **Retry with a note** keeps the pipeline (and the threads) of the fix it replaces.
- `suica reviews --json` gives each of `yourMergeRequests` its `pipeline` (`iid`, `status`, `url`, or null); `suica fix list --json` gives each fix its `pipeline` (null for a thread-only fix). Both contracts stay version 1: the fields are additions.
- New alerts: `alert.pipeline-failed` (placeholders `mr.title`, `mr.iid`, `mr.project`, `mr.url`) and `alert.pipeline-fix-ready` (`mr.title`), used instead of `alert.fix-ready` when the fix has no threads, since "0 threads answered" says nothing.
- State: schema 16 adds `fix_run.pipeline` (JSON) and a `pipeline_watch` table (`mr_key`, `pipeline_iid`, `status`), whose rows of MRs that are no longer open are dropped each poll.

## App

- **Yours** rows show the pipeline: a red **Pipeline failed**, an orange **Pipeline running** (also pending and the other not-yet-finished states), or a green **Pipeline passed**; no mark without a pipeline.
- The MR page of one of your MRs offers **Fix pipeline** while its pipeline failed (`pipelineStatus` of the MR detail).
- The **Agent fix** tab shows the pipeline the fix works on: a link to it, each failed job with its stage and a link to its log, and once the model ran, its sentence.

## Not done

- No retrying of the pipeline or of a job from Suica, no watching of pipelines on MRs the Owner reviews, no running of the failing command in the sandbox. Each could come later; none was asked for.

## Tests

- Unit: log cleaning and tailing; failed-job selection (allowed failures); pipeline watch transitions (first sight silent, running→failed alerts, the same failed pipeline alerts once, a new failed pipeline alerts again, closed MRs dropped, automatic queue on and off, daily cap, busy MR); queueing a pipeline into a queued thread fix; the prompt with and without threads; the answer's `pipeline` sentence; a no-change Pipeline Fix ends skipped; retry keeps the pipeline; schema migration from 15; contract goldens for reviews and fixes (Node writes, Swift decodes).
