# Agent Usage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an Overall tab to the Token Usage page. It shows what Claude Code and Codex usage on this Mac would cost at API prices (tokens, daily average, cost per day and by model) in USD or IDR.

**Architecture:** A new Node module `src/agent-usage/` reads the agents' local session logs. It keeps a per-file cache of hourly totals by model, prices them with a built-in table, fetches a daily USD→IDR rate, and prints the `agent-usage.v1` document from a new `suica usage agents --json` command. The Swift app decodes the document and adds an Overall/MR reviews picker to `UsageView`; the existing view becomes the MR reviews tab.

**Tech Stack:** TypeScript on Node ≥24 (`node:zlib` zstd, `fetch`), vitest, SwiftUI with Swift Charts, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-04-agent-usage-design.md`

## Global Constraints

- No new npm or Swift dependency. Zstd uses `zlib.createZstdDecompress` (present on node v24.19.0).
- Read only token counts, model and timestamp from logs. Never store or print message content.
- Window: 30 days. Files with an mtime older than 30 days are skipped.
- Cache files go next to the state database (`dirname(config.statePath ?? defaultStatePath())`): `agent-usage-cache.json` and `exchange-rate.json`. A corrupt or missing file is rebuilt, never fatal.
- Rate URL constant: `https://api.frankfurter.app/latest?from=USD&to=IDR`. 5 s timeout (`AbortSignal.timeout`), no retry, refetch only when the saved rate is older than 24 h.
- The CLI call from the app uses a 120 s timeout. The cache is saved every 300 parsed files.
- Prices are copied from the official Anthropic and OpenAI pricing pages, never from memory. They are recorded with `PRICES_AS_OF`. A model with no public price is unpriced.
- `suica usage` and `contracts/usage.v1.json` must not change.
- Branch `feat/no-ticket-agent-usage` in worktree `../suica-agent-usage`. Commit with `git -C ../suica-agent-usage …`, with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Checks: `npm run typecheck && npm run lint && npm test`; Swift: `cd macos/Suica && swift test`.

## Review Focus

1. **A log line being written while it's read** (truncated JSON at the end of a file): skip that line, and parse it in full once the file changes. Test in Task 2 and Task 3.
2. **An agent that isn't installed** (`~/.codex` missing, empty `~/.claude/projects`): totals are zero and nothing throws. Test in Task 4.
3. **A file deleted, or a cache written by an older build**: entries for vanished paths are dropped; a cache with a different `version` is thrown away. Test in Task 4.
4. **A bad rate response** (HTTP 500, non-JSON, `rates.IDR` missing, zero or negative): treat it as a failed fetch and fall back to the saved rate marked stale. Test in Task 5.
5. **A Codex session whose totals go down** (a session reset or a new rollout file reusing the id): a negative change is counted as zero, never subtracted. Test in Task 3.

---

### Task 1: Price table

**Files:**
- Create: `src/agent-usage/prices.ts`
- Test: `test/agent-usage-prices.test.ts`

**Interfaces:**
- Produces:
  ```ts
  export interface TokenCounts { input: number; output: number; cacheRead: number; cacheWrite5m: number; cacheWrite1h: number }
  export interface ModelPrice { prefix: string; input: number; output: number; cacheRead: number; cacheWrite5m: number; cacheWrite1h: number; long?: { above: number; price: Omit<ModelPrice, "prefix" | "long"> } } // USD per 1M tokens
  export const PRICES_AS_OF: string; // "YYYY-MM-DD"
  export const PRICES: readonly ModelPrice[];
  export const LONG_CONTEXT_TOKENS = 200_000;
  export function priceOf(model: string): ModelPrice | undefined; // longest matching prefix
  export function costUsd(price: ModelPrice, counts: TokenCounts, long: boolean): number;
  ```

- [ ] **Step 1: List the models in use.** Run a one-off `rg -o '"model":"[^"]+"'` over the last 30 days of `~/.claude/projects` and `~/.codex/sessions` (zst files via `zstd -dc`). Record the distinct ids in the commit message body.
- [ ] **Step 2: Fill `PRICES` from the official pages.** Use the claude-api skill and the Anthropic pricing page for Claude models, and the OpenAI pricing page for GPT/Codex models. Add `long` only where the page gives a higher rate above a context size. Models with no public price (for example `codex-auto-review`) stay out of the table.
- [ ] **Step 3: Write failing tests.**
  - `priceOf("claude-opus-5-5-20261001")` returns the `claude-opus-5-5` entry; a longer prefix wins over a shorter one.
  - `priceOf("codex-auto-review")` is `undefined`.
  - `costUsd(p, {input:1e6, output:0, cacheRead:0, cacheWrite5m:0, cacheWrite1h:0}, false) === p.input`; each of the five counts maps to its own rate.
  - With `long: true` and `p.long` set, the long rates are used. With `long: true` and no `p.long`, the base rates are used.
- [ ] **Step 4: Run** `npx vitest run test/agent-usage-prices.test.ts` and confirm it fails, then implement and confirm it passes.
- [ ] **Step 5: Commit** `feat(usage): price table for coding agent models`.

### Task 2: Claude log reader

**Files:**
- Create: `src/agent-usage/claude.ts`
- Test: `test/agent-usage-claude.test.ts`, fixture `test/fixtures/agent-usage/claude.jsonl`

**Interfaces:**
- Consumes: `TokenCounts`, `LONG_CONTEXT_TOKENS` (Task 1).
- Produces (shared, put in `src/agent-usage/bucket.ts`):
  ```ts
  export interface Bucket extends TokenCounts { hour: number; agent: "claude" | "codex"; model: string; long: boolean }
  export function addTo(buckets: Map<string, Bucket>, b: Bucket): void; // key `${hour}|${agent}|${model}|${long}`
  ```
  and `export function readClaudeLines(lines: Iterable<string>): Bucket[]`.

- [ ] **Step 1: Write a fixture from real line shapes.** One reply split across 3 lines with the same `message.id` and `requestId`; a line with `cache_creation.{ephemeral_5m_input_tokens, ephemeral_1h_input_tokens}`; a line with only `cache_creation_input_tokens` (no split); a request with input + cacheRead + cacheWrite > 200,000; a user line; a truncated last line.
- [ ] **Step 2: Write failing tests.**
  - The 3 repeated lines count once.
  - The split goes to `cacheWrite5m` and `cacheWrite1h`; without a split, all of it goes to `cacheWrite5m`.
  - The large request has `long: true`, the others `false`.
  - `hour` is `Math.floor(Date.parse(timestamp) / 3_600_000) * 3_600_000`.
  - The truncated line and the user line add nothing, and nothing throws.
- [ ] **Step 3: Implement.** Use `JSON.parse` in try/catch per line, reading `message.usage`, `message.model`, `message.id`, `requestId` and `timestamp`. Dedupe with a `Set` of `` `${id}|${requestId}` ``.
- [ ] **Step 4: Run the tests and confirm they pass. Commit** `feat(usage): read Claude Code token usage`.

### Task 3: Codex log reader

**Files:**
- Create: `src/agent-usage/codex.ts`
- Test: `test/agent-usage-codex.test.ts`, fixtures `test/fixtures/agent-usage/codex.jsonl` and `codex.jsonl.zst` (made with `zstd`)

**Interfaces:**
- Consumes: `Bucket`, `addTo`, `LONG_CONTEXT_TOKENS`.
- Produces: `export function readCodexLines(lines: Iterable<string>): { sessionId: string | undefined; buckets: Bucket[] }`.

- [ ] **Step 1: Write a fixture from a real file's shapes** (check one with `turn_context` and one without). It needs `session_meta` with `payload.id`; a model-naming line; three `token_count` events (second one repeated, third one lower than the second); `cache_write_input_tokens` > 0; a truncated last line.
- [ ] **Step 2: Write failing tests.**
  - The counts are the change in `info.total_token_usage` between events; the repeated event adds 0; a lower total adds 0.
  - `input` = Δ`input_tokens` − Δ`cached_input_tokens`; `cacheRead` = Δ`cached_input_tokens`; `cacheWrite5m` = Δ`cache_write_input_tokens`.
  - Output uses `output_tokens` alone, or adds `reasoning_output_tokens`, whichever the OpenAI docs say. Note the source in a code comment.
  - The model comes from the latest model-naming line before the event; with none, the model is `"unknown"`.
  - `long` is true when `last_token_usage.input_tokens` > 200,000.
  - `sessionId` equals `session_meta.payload.id`.
- [ ] **Step 3: Implement**, then **run the tests, confirm they pass, and commit** `feat(usage): read Codex token usage`.

### Task 4: Scan and cache

**Files:**
- Create: `src/agent-usage/scan.ts`
- Test: `test/agent-usage-scan.test.ts` (temporary `home` and cache dirs)

**Interfaces:**
- Consumes: `readClaudeLines`, `readCodexLines`, `Bucket`.
- Produces:
  ```ts
  export interface ScanDeps { home: string; cachePath: string; now: number; saveEvery?: number /* default 300 */ }
  export async function scanAgentUsage(deps: ScanDeps): Promise<Bucket[]>; // merged buckets, hour >= now - 30d
  ```
  Cache file: `{ version: 1, files: { [path]: { size, mtimeMs, sessionId?, buckets: Bucket[] } } }`.

- [ ] **Step 1: Write failing tests.**
  - Missing `~/.claude` and `~/.codex` give `[]`.
  - It reads `.jsonl` recursively under `~/.claude/projects`, plus `.jsonl` and `.jsonl.zst` under `~/.codex/sessions` and `~/.codex/archived_sessions`.
  - A file with an mtime older than 30 days is not read (set it with `utimes`).
  - A second run with unchanged files does not parse again (spy on the readers via an injected `read` dep, or check that a corrupted file body is ignored while its size and mtime match).
  - A deleted file's entry is dropped from the cache.
  - A cache with `version: 0` or invalid JSON is rebuilt.
  - Two Codex files with the same `sessionId` count once (keep the larger file).
  - With `saveEvery: 1`, the cache file exists after the first file is parsed.
- [ ] **Step 2: Implement.** Use `fs.promises.readdir({ recursive: true })` and `stat`. Stream lines with `readline` over `createReadStream`, piped through `zlib.createZstdDecompress()` for `.zst`. Write the cache through a temp file plus `rename`.
- [ ] **Step 3: Run the tests, confirm they pass, and commit** `feat(usage): scan agent logs with a per-file cache`.

### Task 5: Exchange rate

**Files:**
- Create: `src/agent-usage/rate.ts`
- Test: `test/agent-usage-rate.test.ts`

**Interfaces:**
- Produces:
  ```ts
  export interface RateJson { currency: "IDR"; perUsd: number; date: string; stale: boolean }
  export async function loadRate(deps: { path: string; now: number; fetch: typeof fetch }): Promise<RateJson | null>;
  ```
  Saved file: `{ perUsd, date, fetchedAt }`.

- [ ] **Step 1: Write failing tests** with an injected `fetch`:
  - A fresh save (under 24 h old) does not call fetch and returns `stale: false`.
  - An old save plus a successful fetch saves the new rate, `stale: false`.
  - An old save plus a failed fetch (throw, 500, non-JSON, `rates.IDR` missing / `0` / `-1` / `NaN`) returns the saved rate with `stale: true`.
  - No save and a failed fetch returns `null`.
  - Fetch is called with the constant URL and a `signal`.
- [ ] **Step 2: Implement** with `AbortSignal.timeout(5_000)`. Validate with `Number.isFinite(r) && r > 0`. Store `date` from the response's `date` field.
- [ ] **Step 3: Run the tests, confirm they pass, and commit** `feat(usage): daily USD to IDR rate with offline fallback`.

### Task 6: Document, contract and CLI command

**Files:**
- Create: `src/agent-usage/document.ts`, `contracts/agent-usage.v1.json`
- Modify: `src/cli.ts` (usage string, `"usage"` dispatch near line 1426, a new `agentUsageJson()` beside `usageJson()` at line 272)
- Test: `test/agent-usage-document.test.ts`; extend the CLI help test if one checks the usage string.

**Interfaces:**
- Consumes: `Bucket`, `priceOf`, `costUsd`, `PRICES_AS_OF`, `scanAgentUsage`, `loadRate`, `localDayKey` (`src/stats.ts`).
- Produces:
  ```ts
  export interface CostTotalsJson { tokens: number; costUsd: number }
  export interface AgentUsageJson {
    version: 1; generatedAt: number; pricesAsOf: string;
    last24h: CostTotalsJson; last7d: CostTotalsJson; last30d: CostTotalsJson;
    avgPerDay7d: CostTotalsJson; avgPerDay30d: CostTotalsJson;   // window total / 7 or / 30
    days: readonly (CostTotalsJson & { day: string })[];        // 30 days, oldest first, every day present
    byModel: readonly { agent: "claude" | "codex"; model: string; tokens: number; costUsd: number | null }[]; // 30 days, costliest first, unpriced last by tokens
    unpriced: { tokens: number; models: readonly string[] };
    rate: RateJson | null;
  }
  export function buildAgentUsage(input: { buckets: readonly Bucket[]; now: number; dayKey: (ms: number) => string; rate: RateJson | null }): AgentUsageJson;
  ```
  `tokens` is the sum of all five counts. Unpriced buckets add to `tokens` but not to `costUsd`.

- [ ] **Step 1: Write failing tests.**
  - The golden check works like `test/usage.test.ts:34`: fixed buckets and `utcDay` must equal `contracts/agent-usage.v1.json`. The buckets cover a priced Claude model, a long-context bucket, an unpriced Codex model, a bucket 25 h old (in 7d, not in 24h), one 31 days old (excluded) and one in the future (excluded).
  - `days.length === 30`.
  - `avgPerDay30d.costUsd === last30d.costUsd / 30`.
- [ ] **Step 2: Implement `buildAgentUsage`, then write the golden from its output and check it by hand** against the test's arithmetic.
- [ ] **Step 3: Wire the CLI.** `suica usage agents --json` calls `scanAgentUsage({ home: homedir(), cachePath, now })`, `loadRate({ path, now, fetch })` and `buildAgentUsage`, then prints one JSON line. It is async, like the other async commands in `cli.ts`, and never creates the runtime. Add `usage agents --json` to the usage string.
- [ ] **Step 4: Run** `npm run typecheck && npm run lint && npm test` and confirm it passes. Then run `node src/cli.ts usage agents --json | head -c 600` against real data, and record the elapsed time of a cold run and a warm run in the commit body.
- [ ] **Step 5: Commit** `feat(usage): suica usage agents --json`.

### Task 7: Swift decoder and client

**Files:**
- Modify: `macos/Suica/Sources/SuicaCore/Dashboard.swift` (beside `UsageDocument`, line 253), `macos/Suica/Sources/SuicaCore/AgentClient.swift` (beside `usage()`, line 369; plus the protocol at `Dashboard.swift:407`), `macos/Suica/Sources/SuicaCore/WindowModel.swift`
- Test: `macos/Suica/Tests/SuicaCoreTests/DashboardContractTests.swift`

**Interfaces:**
- Produces: `public struct AgentUsageDocument: Codable, Equatable, Sendable`, which mirrors `AgentUsageJson` (with nested `CostTotals`, `AgentDayUsage`, `ModelUsage`, `Unpriced`, `ExchangeRate`); `func agentUsage() async throws(AgentError) -> AgentUsageDocument` using `document(AgentUsageDocument.self, ["usage", "agents", "--json"], timeout: 120)`; and on `WindowModel`, `public private(set) var agentUsage: AgentUsageDocument?` plus `public func loadAgentUsage() async`. It is called on demand, not in the 30 s refresh loop, because the scan is expensive. It keeps the last good value and sets `errorText` on failure, like `usage`.

- [ ] **Step 1: Write a failing test** `agentUsageMatchesTheGoldenFile`: decode `contract("agent-usage.v1.json")` and check `pricesAsOf`, `days.count == 30`, the first `byModel` entry, `unpriced.models`, and `rate` (and decode a copy with `"rate": null`). Update every test double of the client protocol.
- [ ] **Step 2: Implement, run** `cd macos/Suica && swift test` **and confirm it passes. Commit** `feat(app): decode agent usage`.

### Task 8: Overall tab UI and docs

**Files:**
- Create: `macos/Suica/Sources/Suica/Window/AgentUsageView.swift`
- Modify: `macos/Suica/Sources/Suica/Window/UsageView.swift` (wrap the body in a tab picker), `macos/Suica/Sources/SuicaCore/Copy.swift` (or wherever `Copy.tokenUsage` lives), `README.md:184` and `:382`, `CONTEXT.md` (if it defines Token usage)

**Interfaces:**
- Consumes: `WindowModel.agentUsage`, `loadAgentUsage()`.

- [ ] **Step 1: Add a segmented `Picker` at the top of `UsageView`** (`Copy.usageOverall` "Overall", `Copy.usageReviews` "MR reviews"; style as in `LogsView.swift:55`). The default tab is Overall, and the choice is kept in `@AppStorage("usage.tab")`. The existing body becomes the MR reviews tab unchanged.
- [ ] **Step 2: Build `AgentUsageView`, reusing `Card`, `NoticeBox`, the tiles and the `Chart` pattern from `UsageView`.**
  - It calls `loadAgentUsage()` in `.task` and has a refresh button.
  - Tiles: 24 h / 7 d / 30 d (cost large, tokens small) and average per day (7 d, 30 d).
  - A bar chart of cost per day over 30 days, and a by-model card.
  - A segmented currency switch, USD | IDR, in `@AppStorage("usage.currency")`. It is disabled when `rate == nil`.
  - Format amounts with `.formatted(.currency(code:))`: IDR with no decimals, USD with 2 decimals.
  - Notices: stale ("Rate from <date> (could not refresh)"), no rate ("IDR unavailable: no exchange rate fetched yet"), unpriced ("<n> tokens from unpriced models: <list>"), and a footnote "API list prices as of <date>. Cost is what this usage would cost on the API, not what you pay."
  - A loading state while the first scan runs.
- [ ] **Step 3: Check it visually** using the scratch NSHostingView harness from memory `suica-ui-screenshot-harness`. Render it with the golden document in USD, in IDR, with a stale rate, and with `rate: nil`, and show the user the screenshots.
- [ ] **Step 4: Update the docs.**
  - `README.md:184`: add `suica usage agents --json`.
  - `README.md:382`: describe the two tabs, the sources, API-price meaning, the rate source and fallback, and the cache files.
  - `CONTEXT.md`: add the term if Token usage is defined there.
- [ ] **Step 5: Run** `swift test` **and** `npm test`**, confirm both pass, and commit** `feat(app): Overall agent usage tab with USD and IDR`.
