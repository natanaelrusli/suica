# Merged Nudge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Send one Teams chat, listing every MR, when several queued nudges, reminders or re-review nudges go to the same person for MRs with the same ticket key.

**Architecture:** Group at dispatch time. `planTeams`, the `nudge_state` ledger, dedupe keys, `stillNeeded` and the outbox schema stay as they are: one outbox row per MR still exists. `dispatchQueued` groups the rows that are due in one pass, renders one text (the template's `{{mr.link}}` becomes a bullet list), and `deliver` moves the lead row and every sibling row together.

**Tech Stack:** TypeScript on Node (`node:sqlite` store), vitest. Branch `feat/no-ticket-merged-nudge`, worktree `../suica-merged-nudge`; commit with `git -C ../suica-merged-nudge …`.

**Spec:** `docs/superpowers/specs/2026-11-03-merged-nudge-design.md`

## Global Constraints

- Ticket key: first match of `/\b[A-Z][A-Z0-9]+-\d+\b/` in the MR title; no key means no merge.
- A group shares recipient, `kind` and `variant`; `kind` is one of `YOUR_MR_KINDS` (`nudge`, `reminder`, `rereview`); manual rows (`dedupeKey` starting `manual:`) never merge.
- At most `MERGE_MAX = 10` MRs per chat; a bigger group is split in order.
- Only rows `queued` in the same `dispatchQueued` pass merge; later rows go alone.
- A merged row's sibling ends `sent` (or `dry-run`) with `detail = "merged into #<lead id>"`, never `skipped`: `loadTeams().undelivered` (`src/store.ts:1257`) reads the row's status, and a non-delivered sibling would suppress its reminder forever (`src/teams/plan.ts:187`).
- Templates, config, schema, contracts and the Swift app do not change. Code and docs are in English.
- Check command before the last commit: `npm run check`.

## Review Focus

- A sibling that is `skipped` or `queued` after the lead is sent keeps its reviewer in `undelivered` (reminder lost): test asserts `loadTeams().undelivered` is empty after a merged send. (Task 2)
- Teams down (`retry-later`) after grouping: lead and siblings all stay `queued`, nothing half sent. (Task 2)
- A sibling that stopped being needed (Reviewer reviewed it) must not appear in the chat, and a group left with one MR reads exactly like today's single message. (Task 2)
- Recipient not found: lead and siblings all become `unresolved`, so `suica retry <id>` works on each. (Task 2)
- Title with Markdown characters (`[ABC-1] Fix *x*`) is escaped in every bullet. (Task 2)
- Same ticket but different recipient, different variant, or no key: separate chats. (Task 1)
- Twelve MRs for one ticket: two chats of 10 and 2. (Task 1)

---

### Task 1: Group rows by ticket key

**Files:**
- Create: `src/teams/merge.ts`
- Test: `test/merge.test.ts`

**Interfaces:**
- Produces: `MERGE_MAX: number` (10); `ticketKey(title: string): string | null`; `groupForMerge(rows: readonly OutboxRow[]): OutboxRow[][]` — rows in order (the caller passes them ordered by id); returns groups in order of each group's first row, each group's rows in input order, the first row being the lead. A row with no ticket key, or a `kind` outside `YOUR_MR_KINDS`, is a group of one. Rows with equal `recipient`, `variant` and ticket key share a group, split into chunks of `MERGE_MAX`. The caller removes manual rows first.

- [ ] **Step 1: Write the failing tests in `test/merge.test.ts`**

Build rows with a small local `row(id, overrides)` returning an `OutboxRow` (all fields filled, `kind: "nudge"`, `variant: "nudge"`, `recipient: "bob"`, `mrTitle: "ABC-1 thing"`). Cases and assertions:
  - `ticketKey("[ABC-123] Add login")` is `"ABC-123"`; `ticketKey("feat(PAY-7): x")` is `"PAY-7"`; `ticketKey("Fix login")` and `ticketKey("abc-1 lower")` are `null`; `ticketKey("ABC-1 and DEF-2")` is `"ABC-1"`.
  - `it("merges rows of one recipient, variant and ticket")`: rows 1, 2 with `ABC-1` → `[[1, 2]]` (compare by `id`).
  - `it("keeps a different ticket, recipient or variant apart")`: rows 1 (`ABC-1`), 2 (`ABC-2`), 3 (`ABC-1`, recipient `carol`), 4 (`ABC-1`, variant `reminder`, kind `reminder`) → `[[1], [2], [3], [4]]`.
  - `it("never merges a row without a ticket key")`: rows 1, 2 titled `Fix login` → `[[1], [2]]`.
  - `it("never merges a notice")`: rows 1, 2 with `kind: "notice"`, variant `notice.approved`, `ABC-1` → `[[1], [2]]`.
  - `it("splits a group of twelve into 10 and 2")`: ids 1–12 → group lengths `[10, 2]`, ids kept in order.
  - `it("orders groups by their first row")`: rows 1 (`ABC-1`), 2 (`ABC-2`), 3 (`ABC-1`) → `[[1, 3], [2]]`.

- [ ] **Step 2: Run to verify failure**

Run: `npx vitest run test/merge.test.ts`
Expected: FAIL, cannot resolve `../src/teams/merge.ts`.

- [ ] **Step 3: Implement `src/teams/merge.ts`**

Group with a `Map` from `${recipient}|${variant}|${ticket}` to the open chunk; start a new chunk at `MERGE_MAX`. Keep output order by pushing a chunk into the result when it is created. Add `shortcut: a key-shaped word such as UTF-8 counts as a ticket, upgrade when a false merge is reported` above the regex.

- [ ] **Step 4: Run to verify pass**

Run: `npx vitest run test/merge.test.ts`
Expected: PASS, all cases.

- [ ] **Step 5: Commit**

```bash
git -C ../suica-merged-nudge add src/teams/merge.ts test/merge.test.ts
git -C ../suica-merged-nudge commit -m "feat(teams): group queued messages by ticket key"
```

---

### Task 2: Send a group as one message in `dispatchQueued`

**Files:**
- Modify: `src/teams/dispatch.ts` (`valuesFor` at 177, `deliver` at 205, `sendBatch` at 259, `dispatchQueued` at 289)
- Test: `test/dispatch.test.ts`

**Interfaces:**
- Consumes: `groupForMerge` from Task 1.
- Produces: `deliver(deps: DispatchDeps, api: TeamsApi, row: OutboxRow, text: string, mates: readonly OutboxRow[] = []): Promise<DeliverOutcome>` — `mates` are rows that share this text and currently have the same status as `row`; the existing callers keep working without the argument. `valuesFor(row, ownerName, agentName, nowMs, mates: readonly OutboxRow[] = [])`.

Behavior to implement, in `dispatchQueued`:
1. The existing loop first skips obsolete rows (`stillNeeded`) and leaves `pending` rows and out-of-hours passes untouched; it now only collects the remaining `queued` rows.
2. `groupForMerge` runs on the collected rows minus manual rows (manual rows are their own groups). For each group, `lead = group[0]`, `mates = group.slice(1)`; render once with `pickVariant(deps.templates[lead.variant], lead.dedupeKey)` and `valuesFor(lead, …, mates)`.
3. `valuesFor` with mates sets `mr.link` to `[lead, ...mates]` each as `- ${markdownLink(clean(title, TITLE_MAX), url)}` joined by `\n`; with no mates it stays the single link. Other placeholders come from the lead.
4. Mode comes from `modeFor(lead, deps.config)`. `dry-run`: every row of the group moves `queued → dry-run` with the text. `approval`: every row moves `queued → pending` with the text and only the lead goes into `held`. Template error: every row of the group moves `queued → failed` with detail `template`. Automatic: `automatic.push({ row: lead, mates, text })`; `sendBatch` passes `mates` to `deliver`.
5. In `deliver`, `mates` follow the lead: when the lead moves to `unresolved` (both places) every mate moves `from → unresolved` with the same `detail` and `text`; right after the lead's CAS to `sending` succeeds every mate moves `from → sending` (a failed CAS on a mate is ignored); after `failed` every mate moves `sending → failed` with the lead's failure kind; after `sent` every mate moves `sending → sent` with `detail: "merged into #<lead id>"` and `text`. Nothing is touched on `retry-later` or `busy`. Use one small private helper `moveMates(deps, mates, from, to, fields)`.

- [ ] **Step 1: Write the failing tests in `test/dispatch.test.ts`**

Add a `describe("merged messages")` with a local helper `enqueueMrs(store, specs: { iid: number; title: string; recipient?: string }[])` that applies one `teamsPlan` with an `intent` per spec (`dedupeKey: \`nudge:g/p!${iid}|bob:1\``, `mr` with `key: \`g/p!${iid}\``, `iid`, `projectPath: "g/p"`, `title`, `url: \`https://gitlab.example/g/p/-/merge_requests/${iid}\``) and a `nudgeUpdates` entry `{ key: \`g/p!${iid}|bob\`, record: { sentCount: 1, lastSentAt: NOW } }`, and a local `own2(...iids)` snapshot with one authored `mr(iid, { author: ME, title, reviewers: [reviewer("bob", "UNREVIEWED", "Bob")] })` per iid. Tests (each calls `dispatchQueued(h.deps, own2(5, 6))` with `setup()` unless noted):
  - `it("sends one message for two MRs of one ticket")`: titles `ABC-1 first`, `ABC-1 second`. `h.sent` has length 1 and `h.sent[0].text` equals `"Halo Bob, saya Bahlil, agen review-nya Nata. Boleh minta tolong review MR ini?\n- [ABC-1 first](https://gitlab.example/g/p/-/merge_requests/5)\n- [ABC-1 second](https://gitlab.example/g/p/-/merge_requests/6)\nTerima kasih!"`; the lead row is `sent` with `detail: ""`, the sibling is `sent` with `detail: "merged into #<lead id>"`; the result is `{ sent: 1, failure: undefined, held: [] }`; `h.store.loadTeams().undelivered.size` is `0`.
  - `it("escapes Markdown in every bullet")`: titles `[ABC-1] Fix *x*` and `ABC-1 b_c` → the text contains `- [\\[ABC-1\\] Fix \\*x\\*](` and `- [ABC-1 b\\_c](`.
  - `it("sends separate messages for different tickets or no ticket")`: titles `ABC-1 a`, `ABC-2 b`, `no key`, `no key either` → `h.sent` length 4.
  - `it("sends separate messages to different recipients")`: two rows, same ticket, recipients `bob` and `carol` (snapshot reviewers for both) → length 2.
  - `it("leaves out a sibling that is no longer needed, and the message reads like a single one")`: snapshot where MR 6's reviewer `bob` is `APPROVED` → the sibling row is `skipped` with `detail: "obsolete"` and `h.sent[0].text` contains `[ABC-1 first](https://gitlab.example/g/p/-/merge_requests/5)` and no `- ` bullet.
  - `it("sends twelve MRs of one ticket as 10 and 2")`: 12 MRs → `h.sent` length 2; the first text has 10 lines starting `- `, the second has 2.
  - `it("records a dry run for every row of the group")`: `setup({ mode: "dry-run" })` → both rows `dry-run` with the same `text`, `h.sent` empty.
  - `it("holds the group for approval and notifies once")`: `setup({ mode: "approval" })`, two nudge rows → both `pending` with identical `text`; `result.held` has length 1 and its `id` is the lead's.
  - `it("keeps the whole group queued while Teams is unreachable")`: `setup({ api: { searchUsers: () => Promise.reject(new TeamsFailure("unavailable", "down")) } })` → both rows still `queued`.
  - `it("marks the whole group failed when sending fails")`: `api.sendMessage` rejects `new TeamsFailure("error", "403")` → lead and sibling `failed` with `detail: "error"`.
  - `it("marks the whole group unresolved when the person is not found")`: `api.searchUsers: () => Promise.resolve([])` → both rows `unresolved`.
  - `it("does not wait for a sibling that arrives later")`: dispatch with MR 5 queued, then enqueue MR 6 and dispatch again → `h.sent` length 2.

- [ ] **Step 2: Run to verify failure**

Run: `npx vitest run test/dispatch.test.ts -t "merged messages"`
Expected: FAIL (two messages sent instead of one, assertion on `h.sent` length).

- [ ] **Step 3: Implement the behavior above in `src/teams/dispatch.ts`**

Import `groupForMerge` from `./merge.ts`. Reuse `markdownLink`, `clean`, `TITLE_MAX`. Keep `deliver`'s single-row path byte-for-byte when `mates` is empty.

- [ ] **Step 4: Run to verify pass**

Run: `npx vitest run test/dispatch.test.ts`
Expected: PASS, including every earlier dispatch test (a lone row renders exactly as before).

- [ ] **Step 5: Commit**

```bash
git -C ../suica-merged-nudge add src/teams/dispatch.ts test/dispatch.test.ts
git -C ../suica-merged-nudge commit -m "feat(teams): send queued nudges for one ticket as one message"
```

---

### Task 3: `suica send` sends a held group in one go

**Files:**
- Modify: `src/teams/dispatch.ts` (`sendPending` at 344)
- Test: `test/dispatch.test.ts`

**Interfaces:**
- Consumes: `deliver(..., mates)` from Task 2.
- Produces: `sendPending(deps, id)` unchanged in signature; it now passes `mates` to `deliver`: every other `pending` row (`deps.store.listOutbox(["pending"])`) that is not manual and has the same `recipient`, `kind`, `variant` and `text` as the row.

- [ ] **Step 1: Write the failing tests**

In `describe("merged messages")`, with `setup({ mode: "approval" })`, MRs 5 and 6 titled `ABC-1 first` / `ABC-1 second`, `h.store.commit(own2(5, 6))` and a dispatch so both rows are `pending`:
  - `it("sends the whole held group when one row is sent")`: `sendPending(h.deps, leadId)` returns `{ status: "sent" }`; `h.sent` has length 1; both rows are `sent` and `approved: true`; the sibling's `detail` is `"merged into #<leadId>"`.
  - `it("sends the group when the sibling is the one the Owner picks")`: `sendPending(h.deps, siblingId)` → one message, both `sent`.
  - `it("leaves a pending row with another text alone")`: add a third pending row for MR 7 titled `ABC-9 other` → after `sendPending` of the lead it is still `pending`.

- [ ] **Step 2: Run to verify failure**

Run: `npx vitest run test/dispatch.test.ts -t "held group"`
Expected: FAIL (the sibling stays `pending`).

- [ ] **Step 3: Implement in `sendPending`**

Compute `mates` after the `stillNeededInState` check and pass it to `deliver`.

- [ ] **Step 4: Run to verify pass**

Run: `npx vitest run test/dispatch.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -C ../suica-merged-nudge add src/teams/dispatch.ts test/dispatch.test.ts
git -C ../suica-merged-nudge commit -m "feat(teams): send a held merged group with one approval"
```

---

### Task 4: Docs

**Files:**
- Modify: `README.md` (Teams section after the paragraph ending "A reminder is due 24 hours after the nudge was actually delivered, never before.", line 308; the limits list near line 429)
- Modify: `CONTEXT.md` (after **Re-review Nudge**, line 29)

- [ ] **Step 1: Add the glossary term to `CONTEXT.md`**

`**Merged Nudge**:` — A single Teams chat that carries the Reviewer Nudges, Reminders or Re-review Nudges due to one Reviewer for several of the Owner's MRs with the same ticket key, so the Reviewer gets one chat instead of one per MR. `_Avoid_: Batch, digest`.

- [ ] **Step 2: Describe it in `README.md`**

One paragraph: what merges (same person, same kind, same ticket key in the title, due in the same pass), the bullet list in place of `{{mr.link}}` (templates unchanged), the cap of 10, that Messages and Statistics keep one row per MR (`merged into #<id>`), that `approval` mode sends the group with one `suica send`, and the design link. Add one line to the limits list: MRs queued by different polls are not merged, and an MR without a ticket key in its title never is.

- [ ] **Step 3: Run the full check**

Run: `npm run check` (in `../suica-merged-nudge`)
Expected: typecheck, lint, prettier and vitest all pass. A spawned-CLI test (`review-cli`, `fix-cli`, `office-cli`) that times out under the parallel run is rerun alone before it is blamed on this change.

- [ ] **Step 4: Commit**

```bash
git -C ../suica-merged-nudge add README.md CONTEXT.md
git -C ../suica-merged-nudge commit -m "docs: describe the Merged Nudge"
```
