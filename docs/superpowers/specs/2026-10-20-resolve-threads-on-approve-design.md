# Resolve your threads when approving — design

Status: written from the Owner's request on 2026-10-20 ("When approving MR we commented, resolve the threads also"). Choices marked _my call_ are the builder's and can be changed. Vocabulary is in `CONTEXT.md`.

## Intent

Once the Owner approves an MR, the threads the Owner opened on it are settled. Leaving them open makes the Author resolve them by hand or blocks a merge that needs every thread resolved.

## Behaviour

- After a successful approval, both from **Approve** in the app (`suica mr approve`) and from the approval after a clean Agent Re-review (`review.approve`), the agent resolves every **resolvable, unresolved** discussion whose **first note** was written by the Owner. That covers the Owner's own comments and an Agent Review's inline threads, which are posted as the Owner.
- Threads others started stay open, even where the Owner replied (_my call_: resolving someone else's question on approval would speak for them).
- Nothing is resolved when the approval was refused (head moved, GitLab error).
- GraphQL: `currentUser` and the MR's discussions, 100 a page, at most 20 pages; then `discussionToggleResolve(resolve: true)` per thread. Variables travel as `-f` fields, never inside the query.
- Never throws: a page that cannot be read resolves nothing; a refused thread is logged and the rest go on. The approval stays approved either way.
- The agent's approval note adds "Resolved N of your threads." or "…; check GitLab for the others." `suica mr approve` keeps printing only `{"status": …}` (_my call_: the app's message does not change).

## Tests

- `test/reviews.test.ts`: pagination with the cursor, the encoded project path, only open threads the Owner started; a failed lookup and a malformed key resolve nothing.
- `test/agent-review.test.ts`: approval after a clean re-review resolves the right threads and says how many; a refused thread asks to check GitLab; a refused approval resolves nothing.
