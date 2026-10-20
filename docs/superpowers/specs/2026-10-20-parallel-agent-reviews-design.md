# Parallel Agent Reviews — design

Status: from the Owner's request on 2026-10-20 ("make suica able to spawn more than 1 llm agent at the same time"). Choices marked _my call_ are the builder's.

## Intent

The review worker ran one Agent Review at a time, so a burst of review requests or re-reviews waited in a queue behind one CLI run.

## Behaviour

1. **Key.** `review.concurrency` (new, integer 1 to 4, default `2`). _My call_: 2 halves the wait for a burst without opening many model sessions against the same plan's rate limits; 4 is the ceiling because each run holds a shallow clone and a CLI process.
2. **Worker.** Each tick starts the oldest queued reviews until `review.concurrency` are running. A finished run ticks again, so the next one starts at once. Pausing stops new starts; running ones finish. `idle()` waits for all of them, so a shutdown still requeues every interrupted run.
3. **No two runs of one MR.** Unchanged: `queueAgentReview` refuses an MR with a queued or running review, and `runAgentReview` marks its row running before its first await, so one tick never starts the same row twice.
4. **Daily cap, timeout, cancel.** Unchanged and per run: `review.maxPerDay` counts queued reviews, `review.timeoutMinutes` stops each run, and **Cancel review** stops the run whose row it names.
5. **Status.** `suica status --json` and `suica state` add `agentReview.runningReviews`, every running review oldest first. `running` stays (the oldest) for an older app. The menu bar panel and the Overview's Agent Review card list each running review with its own **Cancel review** button.

## Constraints

- Contracts `config.v1.json`, `agent-state.v1.json` and `status.v1.json`, the Swift decoders and their tests change together. An older agent without `runningReviews` decodes as its one `running` review.
