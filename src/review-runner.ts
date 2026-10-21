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

/** How hard the CLI thinks, lowest first; `review.effort` picks one. */
export const REVIEW_EFFORTS = ["low", "medium", "high", "xhigh", "max"] as const;
export type ReviewEffort = (typeof REVIEW_EFFORTS)[number];

/** Codex stops at xhigh. */
const codexEffort = (effort: ReviewEffort): string => (effort === "max" ? "xhigh" : effort);

/** Read-only tools only: the MR is untrusted, so no shell, no web, no edits. */
const CLAUDE_TOOLS = ["Read", "Grep", "Glob", "Skill"] as const;
/** An Agent Fix edits files in its checkout; still no shell, so no project code runs and nothing reaches the network. */
const CLAUDE_FIX_TOOLS = ["Read", "Glob", "Grep", "Edit", "Write"] as const;

/** review: read-only; fix: may edit files inside the working folder. */
export type InvocationMode = "review" | "fix";

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
  /** Medium is enough for a review; higher levels cost much more time and tokens. */
  effort: ReviewEffort = "medium",
  mode: InvocationMode = "review",
): Invocation {
  const tools = mode === "fix" ? CLAUDE_FIX_TOOLS : CLAUDE_TOOLS;
  if (cli === "claude") {
    return {
      args: [
        "-p",
        prompt,
        "--output-format",
        "stream-json",
        "--verbose",
        ...(model === undefined ? [] : ["--model", model]),
        "--effort",
        effort,
        "--tools",
        ...tools,
        "--allowedTools",
        ...tools,
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
      mode === "fix" ? "workspace-write" : "read-only",
      // A fix may write in its folder but never reach the network, whatever the Owner's codex config says.
      ...(mode === "fix" ? ["-c", "sandbox_workspace_write.network_access=false"] : []),
      "--skip-git-repo-check",
      "--ephemeral",
      "--json",
      "-c",
      "mcp_servers={}",
      "-c",
      `model_reasoning_effort="${codexEffort(effort)}"`,
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

/** The last JSON line of claude's stream that is its result (one object without a type also is). */
function claudeResult(stdout: string): unknown {
  let result: unknown;
  for (const line of stdout.split("\n")) {
    if (!line.trim().startsWith("{")) continue;
    try {
      const event: unknown = JSON.parse(line);
      const type =
        typeof event === "object" && event !== null && "type" in event ? event.type : undefined;
      if (type === "result" || type === undefined) result = event;
    } catch {
      // A partial or foreign line: the result event is a whole line of its own.
    }
  }
  return result;
}

/** Reads `claude -p --output-format stream-json --verbose`: the review is in its result event. */
export function parseClaudeOutput(stdout: string): RunResult {
  const raw = claudeResult(stdout);
  if (raw === undefined) throw new RunFailure("claude output was not JSON");
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

// MARK: - Live activity

const ACTIVITY_CHARS = 200;

/** One line of at most `ACTIVITY_CHARS`, whitespace and line breaks collapsed. */
function oneLine(text: string): string {
  const flat = text.replace(/\s+/g, " ").trim();
  return flat.length <= ACTIVITY_CHARS ? flat : `${flat.slice(0, ACTIVITY_CHARS - 1)}…`;
}

/** A path inside the checkout without the checkout's own folder. */
function relative(path: string, workDir: string): string {
  return path.startsWith(`${workDir}/`) ? path.slice(workDir.length + 1) : path;
}

const contentSchema = z.array(
  z.object({
    type: z.string(),
    name: z.string().optional(),
    input: z.record(z.string(), z.unknown()).optional(),
    text: z.string().optional(),
    thinking: z.string().optional(),
  }),
);
const claudeEventSchema = z.object({
  type: z.literal("assistant"),
  message: z.object({ content: contentSchema }),
});

function field(input: Readonly<Record<string, unknown>> | undefined, key: string): string {
  const value = input?.[key];
  return typeof value === "string" ? value : "";
}

function describeTool(
  name: string,
  input: Readonly<Record<string, unknown>> | undefined,
  workDir: string,
): string {
  const path = relative(field(input, "path") || field(input, "file_path"), workDir);
  switch (name) {
    case "Read":
      return `Reading ${path}`;
    case "Grep":
      return `Searching "${field(input, "pattern")}"${path === "" ? "" : ` in ${path}`}`;
    case "Glob":
      return `Finding files ${field(input, "pattern")}`;
    case "Skill":
      return `Loading skill ${field(input, "skill")}`;
    default:
      return `Using ${name}`;
  }
}

/**
 * What one line of claude's stream shows the Owner: each tool step, thinking and the text the
 * model writes. Anything else (system events, tool results, the result itself) shows nothing.
 */
export function describeClaudeEvent(line: string, workDir: string): string[] {
  let raw: unknown;
  try {
    raw = JSON.parse(line);
  } catch {
    return [];
  }
  const parsed = claudeEventSchema.safeParse(raw);
  if (!parsed.success) return [];
  return parsed.data.message.content.flatMap((block) => {
    if (block.type === "tool_use" && block.name !== undefined) {
      return [oneLine(describeTool(block.name, block.input, workDir))];
    }
    if (block.type === "thinking" && block.thinking?.trim()) {
      return [oneLine(`Thinking: ${block.thinking}`)];
    }
    if (block.type === "text" && block.text?.trim()) return [oneLine(block.text)];
    return [];
  });
}

const codexEventSchema = z.object({
  type: z.string(),
  item: z.object({
    type: z.string(),
    text: z.string().optional(),
    command: z.string().optional(),
  }),
});

/** What one line of `codex exec --json` shows the Owner: reasoning, commands as they start, the answer. */
export function describeCodexEvent(line: string): string[] {
  let raw: unknown;
  try {
    raw = JSON.parse(line);
  } catch {
    return [];
  }
  const parsed = codexEventSchema.safeParse(raw);
  if (!parsed.success) return [];
  const { type, item } = parsed.data;
  if (type === "item.completed" && item.type === "reasoning" && item.text?.trim()) {
    return [oneLine(`Thinking: ${item.text}`)];
  }
  if (type === "item.started" && item.type === "command_execution" && item.command) {
    return [oneLine(`Running ${item.command}`)];
  }
  if (type === "item.completed" && item.type === "agent_message") return ["Writing the review"];
  return [];
}
