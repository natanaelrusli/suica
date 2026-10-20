import { z } from "zod";
import type { ModelCliId } from "./model-cli.ts";

/** How one CLI is started for an Agent Review, and how its output is read. */

export interface RunTokens {
  readonly inputTokens: number;
  readonly outputTokens: number;
  readonly cacheReadTokens: number;
  readonly cacheCreationTokens: number;
}

export interface RunResult {
  /** The review in Markdown. */
  readonly body: string;
  /** Null when the CLI did not report any. */
  readonly tokens: RunTokens | null;
  /** The model that did most of the writing, as the CLI reported it; null when not reported. */
  readonly model: string | null;
}

export interface Invocation {
  readonly args: readonly string[];
  /** Codex writes its final message to this file instead of stdout. */
  readonly lastMessageFile?: string;
}

export class RunFailure extends Error {
  constructor(message: string) {
    super(message);
    this.name = "RunFailure";
  }
}

/** Enough for a review; higher levels cost much more time and tokens. */
const REVIEW_EFFORT = "medium";

/** Read-only tools only: the MR is untrusted, so no shell, no web, no edits. */
const CLAUDE_TOOLS = ["Read", "Grep", "Glob", "Skill"] as const;

/**
 * Claude Code: the skill and the user's plugins load as usual; tools are limited to reading,
 * anything else is refused without asking, and no MCP server (such as Teams) is started.
 * Codex: read-only sandbox, no MCP servers, nothing kept after the run.
 */
export function buildInvocation(
  cli: Exclude<ModelCliId, "gemini">,
  prompt: string,
  workDir: string,
  /** The CLI's default when undefined. */
  model?: string,
): Invocation {
  if (cli === "claude") {
    return {
      args: [
        "-p",
        prompt,
        "--output-format",
        "json",
        ...(model === undefined ? [] : ["--model", model]),
        "--effort",
        REVIEW_EFFORT,
        "--tools",
        ...CLAUDE_TOOLS,
        "--allowedTools",
        ...CLAUDE_TOOLS,
        "--permission-mode",
        "dontAsk",
        "--strict-mcp-config",
      ],
    };
  }
  const lastMessageFile = `${workDir}/codex-last-message.md`;
  return {
    args: [
      "exec",
      "--sandbox",
      "read-only",
      "--skip-git-repo-check",
      "--ephemeral",
      "--json",
      "-c",
      "mcp_servers={}",
      "-c",
      `model_reasoning_effort="${REVIEW_EFFORT}"`,
      "-C",
      workDir,
      "-o",
      lastMessageFile,
      ...(model === undefined ? [] : ["-m", model]),
      prompt,
    ],
    lastMessageFile,
  };
}

const claudeUsageSchema = z.object({
  inputTokens: z.number(),
  outputTokens: z.number(),
  cacheReadInputTokens: z.number().optional(),
  cacheCreationInputTokens: z.number().optional(),
});
const claudeSchema = z.object({
  is_error: z.boolean(),
  result: z.string().optional(),
  subtype: z.string().optional(),
  /** Per model, summed over the whole run including subagents. */
  modelUsage: z.record(z.string(), claudeUsageSchema).optional(),
});

/** Reads `claude -p --output-format json`. */
export function parseClaudeOutput(stdout: string): RunResult {
  let raw: unknown;
  try {
    raw = JSON.parse(stdout);
  } catch {
    throw new RunFailure("claude output was not JSON");
  }
  const parsed = claudeSchema.safeParse(raw);
  if (!parsed.success) throw new RunFailure("unexpected claude output shape");
  const { is_error: isError, result, subtype, modelUsage } = parsed.data;
  if (isError || result === undefined || result.trim() === "") {
    throw new RunFailure(`claude did not finish the review (${subtype ?? "error"})`);
  }
  const entries = Object.entries(modelUsage ?? {});
  const models = entries.map(([, usage]) => usage);
  // Claude Code also calls small helper models; the main one writes the most.
  const main = entries.reduce<[string, number] | undefined>(
    (best, [name, usage]) =>
      best === undefined || usage.outputTokens > best[1] ? [name, usage.outputTokens] : best,
    undefined,
  );
  const tokens =
    models.length === 0
      ? null
      : models.reduce<RunTokens>(
          (sum, model) => ({
            inputTokens: sum.inputTokens + model.inputTokens,
            outputTokens: sum.outputTokens + model.outputTokens,
            cacheReadTokens: sum.cacheReadTokens + (model.cacheReadInputTokens ?? 0),
            cacheCreationTokens: sum.cacheCreationTokens + (model.cacheCreationInputTokens ?? 0),
          }),
          { inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0 },
        );
  return { body: result.trim(), tokens, model: main?.[0] ?? null };
}

const codexUsageSchema = z.object({
  type: z.literal("turn.completed"),
  usage: z.object({
    /** Includes the cached part. */
    input_tokens: z.number(),
    cached_input_tokens: z.number().optional(),
    cache_write_input_tokens: z.number().optional(),
    output_tokens: z.number(),
  }),
});

/** Reads the `codex exec --json` event stream for usage; the review is the last message file. */
export function parseCodexOutput(stdout: string, lastMessage: string): RunResult {
  if (lastMessage.trim() === "") throw new RunFailure("codex did not finish the review");
  let tokens: RunTokens | null = null;
  for (const line of stdout.split("\n")) {
    if (!line.includes('"turn.completed"')) continue;
    let raw: unknown;
    try {
      raw = JSON.parse(line);
    } catch {
      continue;
    }
    const parsed = codexUsageSchema.safeParse(raw);
    if (!parsed.success) continue;
    const usage = parsed.data.usage;
    const cached = usage.cached_input_tokens ?? 0;
    const previous: RunTokens = tokens ?? {
      inputTokens: 0,
      outputTokens: 0,
      cacheReadTokens: 0,
      cacheCreationTokens: 0,
    };
    tokens = {
      inputTokens: previous.inputTokens + Math.max(usage.input_tokens - cached, 0),
      outputTokens: previous.outputTokens + usage.output_tokens,
      cacheReadTokens: previous.cacheReadTokens + cached,
      cacheCreationTokens: previous.cacheCreationTokens + (usage.cache_write_input_tokens ?? 0),
    };
  }
  return { body: lastMessage.trim(), tokens, model: null };
}
