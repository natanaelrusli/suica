# Task 1 fix round 2 report

Implemented the queued detail await-semantics fix from `task-1-rereview-1.md`.

Queued continuations now transfer to the started request's completion path. The completion path resumes them only after that read has applied its detail and loading cleanup; if the same key has a forced trailing read pending, the waiters remain attached through that trailing read. Capacity is still reserved synchronously when the queued operation starts, and a subsequent queued operation does not delay the completed operation's callers. Displaced requests and stop behavior retain their cancellation handling.

Added `queuedSelectionAwaitsItsDetailRead`: A and B occupy both slots, C queues, A is released to start C, and C remains gated. The test asserts C's selection is still pending while C is in flight and then completes with C selected, detail present, and loading cleared.

Focused verification only:

```text
swift test --filter 'SuicaCoreTests\\.(newestQueuedSelectionKeepsAtMostTwoDetailReads|threeForcedSameKeyJoinsProduceOneTrailingRead|stoppedListRefreshDoesNotStartNewDetailRead|queuedSelectionAwaitsItsDetailRead)'
```

Result: all four named tests passed. No full suite, push, or live calls were performed.
