# Agent Usage

## Why

The Owner uses several coding agents (Claude Code, Codex) on this Mac and wants to know what that use would cost at API prices: total tokens, the average per day, and the dollar cost, with the option to show it in IDR. The goal is to see overall spending and how it changes over time, not to compare agents. Both agents run on subscriptions (the Codex logs show the Plus plan), so the figure means "what this would have cost on the API", not money that was charged.

## What the Owner sees

The existing **Token Usage** page (below Statistics in the sidebar) gets a segmented picker at the top with two tabs:

- **Overall:** every supported coding agent on this Mac. This tab is new.
- **MR reviews:** the current page, unchanged (Suica's own review and reply runs, from `suica usage`).

The Overall tab shows:

- tokens and cost for the last 24 hours, 7 days and 30 days
- the average cost and tokens per day over the last 7 and 30 days (calendar days, so idle days count as zero; my call)
- a bar chart of cost per day for the last 30 days
- a list by model, most expensive first: model, agent, tokens, cost (my call: it explains where the cost comes from)
- a currency switch, **USD | IDR**. The choice is remembered on this Mac (`@AppStorage`; my call).

Notices on the Overall tab:

- **Stale rate:** when the rate could not be refreshed, a line such as "Rate from 2 Nov 2026 (could not refresh)".
- **No rate:** when no rate was ever fetched, IDR is disabled and the line says why.
- **Unpriced models:** tokens from models missing from the price table count toward tokens but not cost, with a line such as "1.2M tokens from unpriced models: gpt-x".
- **Prices date:** a footnote saying "API list prices as of <date>".

## Sources

Read only from local files. No message content is kept; only counts, model and timestamp.

- **Claude Code:** every `*.jsonl` under `~/.claude/projects/`, recursively, which includes subagent sidechains. Each assistant line with `message.usage` contributes `input_tokens`, `output_tokens`, `cache_read_input_tokens` and `cache_creation_input_tokens`, priced by `message.model`. **Dedupe** on `message.id` plus `requestId`, because one reply is written as several lines that repeat the same usage. Claude's `input_tokens` already excludes cache tokens.
- **Claude cache writes:** `message.usage.cache_creation` splits each write into `ephemeral_5m_input_tokens` and `ephemeral_1h_input_tokens`. Price each at its own rate. About two thirds of recent writes are 1-hour writes. When the split is missing, price the whole write at the 5-minute rate.
- **Codex:** every `*.jsonl` and `*.jsonl.zst` under `~/.codex/sessions/` and `~/.codex/archived_sessions/`. About a quarter of recent sessions are zstd-compressed; decompress them with Node's built-in `zlib` zstd (node >=24), no new dependency. Count each session once, keyed by the session id from `session_meta`, in case a session shows up in both folders. `event_msg` lines with `payload.type == "token_count"` carry `info.total_token_usage`, which is cumulative per session. Use the change from the previous event in the same file. A repeated event has zero change, so it adds nothing. Take the model from the latest line before the event that names one. That is `turn_context` when present, otherwise `thread_settings_applied` or similar; many files have no `turn_context`, so the builder confirms the fields from real files. In OpenAI's format `input_tokens` includes `cached_input_tokens`, so uncached input = `input_tokens - cached_input_tokens`. Also count `cache_write_input_tokens` and price it at the model's cache-write rate, or at input when there is none. Price `reasoning_output_tokens` as output only if `output_tokens` does not already include them; the builder checks this against the OpenAI docs. Internal models with no public price (such as `codex-auto-review`) show as unpriced; they are never guessed.
- **Timestamp:** each line's `timestamp`, bucketed by local calendar day (reuse `localDayKey`).
- Suica's own review runs call the Claude CLI, so they also appear in Overall. That is correct: Overall means everything. The MR reviews tab is a separate view, so nothing is added twice.

## Performance

There are 2.4 GB of Claude logs, and about 4,200 files changed in the last 30 days. So:

- Only read files whose mtime falls within the last 30 days.
- Keep a per-file cache keyed by path, size and mtime that holds each file's per-day, per-model totals. Only new or changed files are parsed again. The cache goes in a JSON file next to the state database, `agent-usage-cache.json` (my call). A corrupt or missing cache is thrown away and rebuilt, never fatal.
- Stream each file line by line. Skip any line that is not valid JSON, because the agent may be partway through writing it.
- The first full read took about 27 seconds on this Mac. The app stops CLI calls after 20 seconds (`shortTimeout` in `AgentClient.swift`), so this command gets its own longer timeout, 120 seconds (my call). The cache is also written every few hundred files, so a run that gets stopped still makes progress for the next one. The page shows its usual loading state.
- Duplicate Claude requests across files are rare (14 of about 46,000), but the dedupe key applies across all files anyway, since doing so costs nothing.

## Prices

A built-in table in `src/agent-usage/prices.ts` (my call) holds the USD price per million tokens for input, output, cache read and cache write. Models are matched by id prefix, so dated suffixes still match. Every model seen in the Owner's logs gets an entry, taken from the official Anthropic and OpenAI pricing pages and recorded with its "as of" date. The table must not be filled from memory. The table holds a 5-minute and a 1-hour cache-write rate for each Claude model. **Long-context tiers:** about a third of Claude requests carry more than 200k tokens of context. If the official pricing page gives a model a higher rate above a context threshold, price each request by its own tier, and keep the cache's per-day, per-model totals split by tier so the tier can still be applied (my call). If no current model has such a tier, a flat table is enough; the builder checks the pricing page before deciding. Unknown model means unpriced, as described above.

## Exchange rate

- The source is Frankfurter (`https://api.frankfurter.app/latest?from=USD&to=IDR`), which publishes ECB reference rates, needs no key and covers IDR (my call).
- Fetched by the CLI command at most once every 24 hours, with a 5-second timeout and no retry (the next page open tries again). The result `{ rate, date, fetchedAt }` is saved in `exchange-rate.json` next to the state database.
- If the fetch fails, use the saved rate and mark it stale. With no saved rate, return no rate.
- The URL is a constant; nothing from input goes into it.

## Interface

- A new command, `suica usage agents --json` (my call), prints a new contract, `contracts/agent-usage.v1.json`. `suica usage` and `usage.v1.json` do not change.
- The document holds USD amounts plus a `rate` object (`{ currency: "IDR", perUsd, date, stale }` or `null`). The app does the conversion, so the switch is instant.
- Swift: a decoder in SuicaCore, an `AgentClient` method, and the Overall view in `Window/`, reusing the `Card` and Swift Charts pattern from `UsageView.swift`. Copy strings go in `Copy`.
- `README.md` and `CONTEXT.md` are updated in the same change.

## Tests

- Node (vitest), using fixture files built from real line shapes: Claude dedupe, Codex cumulative deltas and repeated events, the Codex cached-input subtraction, unpriced models, day bucketing, cache reuse (an unchanged file is not parsed again) and the stale-rate fallback (fetch injected).
- A contract golden test for `agent-usage.v1.json` and a Swift decoder test.

## Non-goals

- Gemini CLI, opencode and Cursor. Their logs were not checked; they can come later.
- Real subscription spend, budgets and alerts.
- Currencies other than USD and IDR.
- History older than 30 days.
- A per-project breakdown.

## Anti-goals

- A cost that looks precise but is wrong because of double counting (Claude's repeated lines or Codex's cumulative totals). The dedupe tests exist to prevent this.
- A page that hangs or blocks because the logs are large, or because the rate service is down.
