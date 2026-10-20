import { describe, expect, it } from "vitest";
import {
  buildInvocation,
  describeClaudeEvent,
  describeCodexEvent,
  parseClaudeOutput,
  parseCodexOutput,
  RunFailure,
} from "../src/review-runner.ts";

describe("buildInvocation", () => {
  it("gives claude only read tools, refuses the rest without asking and starts no MCP server", () => {
    const { args, lastMessageFile } = buildInvocation("claude", "/skill\n\nreview", "/w");
    expect(args.slice(0, 5)).toEqual([
      "-p",
      "/skill\n\nreview",
      "--output-format",
      "stream-json",
      "--verbose",
    ]);
    const tools = args.slice(args.indexOf("--tools") + 1, args.indexOf("--allowedTools"));
    expect(tools).toEqual(["Read", "Grep", "Glob", "Skill"]);
    expect(args).toContain("--strict-mcp-config");
    expect(
      args.slice(args.indexOf("--permission-mode"), args.indexOf("--permission-mode") + 2),
    ).toEqual(["--permission-mode", "dontAsk"]);
    expect(args.join(" ")).not.toMatch(/Bash|bypass|restricted/);
    expect(lastMessageFile).toBeUndefined();
  });

  it("runs codex in a read-only sandbox without MCP servers, in the work folder", () => {
    const { args, lastMessageFile } = buildInvocation("codex", "review", "/w");
    expect(args.slice(0, 3)).toEqual(["exec", "--sandbox", "read-only"]);
    expect(args).toContain("--ephemeral");
    expect(args.slice(args.indexOf("-c"), args.indexOf("-c") + 2)).toEqual([
      "-c",
      "mcp_servers={}",
    ]);
    expect(args.slice(args.indexOf("-C"), args.indexOf("-C") + 2)).toEqual(["-C", "/w"]);
    expect(lastMessageFile).toBe("/w/codex-last-message.md");
    expect(args.at(-1)).toBe("review");
    expect(args.join(" ")).not.toMatch(/dangerously|full-auto|workspace-write/);
  });
});

describe("the review effort", () => {
  it("is medium for claude and codex", () => {
    const claude = buildInvocation("claude", "p", "/w").args;
    expect(claude.slice(claude.indexOf("--effort"), claude.indexOf("--effort") + 2)).toEqual([
      "--effort",
      "medium",
    ]);
    expect(buildInvocation("codex", "p", "/w").args).toContain('model_reasoning_effort="medium"');
  });
});

describe("the review model", () => {
  it("is passed as --model to claude and -m to codex, and left out for the CLI's default", () => {
    const claude = buildInvocation("claude", "p", "/w", "opus").args;
    expect(claude.slice(claude.indexOf("--model"), claude.indexOf("--model") + 2)).toEqual([
      "--model",
      "opus",
    ]);
    const codex = buildInvocation("codex", "p", "/w", "gpt-5.5").args;
    expect(codex.slice(-3)).toEqual(["-m", "gpt-5.5", "p"]);
    expect(buildInvocation("claude", "p", "/w").args).not.toContain("--model");
    expect(buildInvocation("codex", "p", "/w").args).not.toContain("-m");
  });

  it("is read from claude as the model that wrote the most", () => {
    const stdout = JSON.stringify({
      is_error: false,
      result: "x",
      modelUsage: {
        "claude-haiku-5-5": { inputTokens: 900, outputTokens: 10 },
        "claude-opus-5-5": { inputTokens: 50, outputTokens: 4000 },
      },
    });
    expect(parseClaudeOutput(stdout).model).toBe("claude-opus-5-5");
  });
});

describe("parseClaudeOutput", () => {
  it("returns the review and sums tokens over every model", () => {
    const stdout = JSON.stringify({
      is_error: false,
      subtype: "success",
      result: "  # Code review\n",
      modelUsage: {
        a: {
          inputTokens: 10,
          outputTokens: 5,
          cacheReadInputTokens: 100,
          cacheCreationInputTokens: 7,
        },
        b: { inputTokens: 1, outputTokens: 2 },
      },
    });
    expect(parseClaudeOutput(stdout)).toEqual({
      body: "# Code review",
      tokens: { inputTokens: 11, outputTokens: 7, cacheReadTokens: 100, cacheCreationTokens: 7 },
      model: "a",
    });
  });

  it("reports no tokens when claude sends no usage", () => {
    expect(parseClaudeOutput(JSON.stringify({ is_error: false, result: "x" })).tokens).toBeNull();
  });

  it("fails on an error result, an empty result or output that is not JSON", () => {
    const failing = [
      JSON.stringify({ is_error: true, subtype: "error_max_turns", result: "partial" }),
      JSON.stringify({ is_error: false, result: "   " }),
      "Error: not logged in",
    ];
    for (const stdout of failing) expect(() => parseClaudeOutput(stdout)).toThrow(RunFailure);
  });
});

describe("parseCodexOutput", () => {
  it("takes the review from the last message and the tokens from every finished turn", () => {
    const stdout = [
      '{"type":"thread.started"}',
      '{"type":"turn.completed","usage":{"input_tokens":1000,"cached_input_tokens":600,"output_tokens":50}}',
      "not json",
      '{"type":"turn.completed","usage":{"input_tokens":200,"cached_input_tokens":0,"cache_write_input_tokens":9,"output_tokens":5}}',
    ].join("\n");
    expect(parseCodexOutput(stdout, "# Review\n")).toEqual({
      body: "# Review",
      tokens: { inputTokens: 600, outputTokens: 55, cacheReadTokens: 600, cacheCreationTokens: 9 },
      model: null,
    });
  });

  it("fails without a final message and reports no tokens without a finished turn", () => {
    expect(() => parseCodexOutput("", "  ")).toThrow(RunFailure);
    expect(parseCodexOutput('{"type":"turn.started"}', "x").tokens).toBeNull();
  });
});

describe("the live activity", () => {
  const assistant = (content: unknown[]) =>
    JSON.stringify({ type: "assistant", message: { content } });

  it("reads the review from the result event of claude's stream", () => {
    const stdout = [
      JSON.stringify({ type: "system", subtype: "init" }),
      assistant([{ type: "text", text: "Looking at the diff." }]),
      JSON.stringify({ type: "result", is_error: false, result: "# Review", modelUsage: {} }),
    ].join("\n");
    expect(parseClaudeOutput(stdout).body).toBe("# Review");
  });

  it("describes claude's steps, thinking and notes, with paths inside the checkout", () => {
    const tool = (name: string, input: unknown) => assistant([{ type: "tool_use", name, input }]);
    expect(describeClaudeEvent(tool("Read", { file_path: "/w/src/a.ts" }), "/w")).toEqual([
      "Reading src/a.ts",
    ]);
    expect(
      describeClaudeEvent(tool("Grep", { pattern: "timeoutMs", path: "/w/src" }), "/w"),
    ).toEqual(['Searching "timeoutMs" in src']);
    expect(describeClaudeEvent(tool("Glob", { pattern: "**/*.ts" }), "/w")).toEqual([
      "Finding files **/*.ts",
    ]);
    expect(
      describeClaudeEvent(tool("Skill", { skill: "madhani:madhani-code-review" }), "/w"),
    ).toEqual(["Loading skill madhani:madhani-code-review"]);
    expect(
      describeClaudeEvent(
        assistant([
          { type: "thinking", thinking: "The retry loop\nhas no cap." },
          { type: "text", text: "Checking the callers next." },
        ]),
        "/w",
      ),
    ).toEqual(["Thinking: The retry loop has no cap.", "Checking the callers next."]);
    expect(describeClaudeEvent(JSON.stringify({ type: "system", subtype: "init" }), "/w")).toEqual(
      [],
    );
    expect(describeClaudeEvent("not json", "/w")).toEqual([]);
  });

  it("shortens a long line to 200 characters", () => {
    const [line] = describeClaudeEvent(assistant([{ type: "text", text: "x".repeat(500) }]), "/w");
    expect(line).toHaveLength(200);
    expect(line?.endsWith("…")).toBe(true);
  });

  it("describes codex's reasoning, commands and final message", () => {
    const item = (type: string, item: unknown) => JSON.stringify({ type, item });
    expect(
      describeCodexEvent(item("item.completed", { type: "reasoning", text: "**Plan** check" })),
    ).toEqual(["Thinking: **Plan** check"]);
    expect(
      describeCodexEvent(item("item.started", { type: "command_execution", command: "rg -n x" })),
    ).toEqual(["Running rg -n x"]);
    expect(
      describeCodexEvent(item("item.completed", { type: "agent_message", text: "# R" })),
    ).toEqual(["Writing the review"]);
    expect(describeCodexEvent(item("item.completed", { type: "command_execution" }))).toEqual([]);
  });
});
