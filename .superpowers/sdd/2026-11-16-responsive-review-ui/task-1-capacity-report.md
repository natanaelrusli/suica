# Task 1: detail request capacity

- Checkout: `/Users/anb-0826009/.t3/worktrees/suica/t3-2b3ecc28`
- Base HEAD: `e771937b9b061de922884cfd71daae88b594532c`
- Changes: replaced `Task.yield()` capacity polling and the extra queued-task spawn with a single latest queued request carrying key, notice/force flags, and continuations. Displaced callers are resumed. Completion releases its slot and drains at most one queued request by reserving the slot and creating its task synchronously before resuming waiters. `stopRefreshing()` drops queued work and resumes its waiters; refresh follow-on detail loading now checks `stopped`.
- Verification: `git diff --check` passed. No tests, builds, or type checks run. No gated concurrency test added.
- Remaining risk: the separate force-pending behavior was intentionally left unchanged and has not been validated as part of this capacity fix.
