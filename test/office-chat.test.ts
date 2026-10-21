import { mkdtempSync, readFileSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { readChat, type OfficeChatJson } from "../src/office/chat.ts";
import { NOW, lines, put } from "./office-builders.ts";

let home: string;
beforeEach(() => {
  home = realpathSync(mkdtempSync(join(tmpdir(), "suica-office-chat-")));
});
afterEach(() => {
  rmSync(home, { recursive: true, force: true });
});

const iso = (ms: number) => new Date(ms).toISOString();

const claudeUser = (content: unknown, at: number, extra: Record<string, unknown> = {}) => ({
  type: "user",
  timestamp: iso(at),
  message: { role: "user", content },
  ...extra,
});
const claudeAssistant = (content: unknown[], at: number) => ({
  type: "assistant",
  timestamp: iso(at),
  message: { role: "assistant", content },
});
const toolResult = { type: "tool_result", tool_use_id: "t", content: "ok" };

function claudeTranscript(sessionId: string, text: string, project = "-work-suica"): void {
  put(join(home, ".claude", "projects", project, `${sessionId}.jsonl`), text);
}

const empty = (agent: string, sessionId: string): OfficeChatJson => ({
  version: 1,
  agent,
  sessionId,
  title: null,
  messages: [],
});

describe("readChat", () => {
  it("reads a Claude Code conversation: prompts and answers, tool calls and results left out", () => {
    claudeTranscript(
      "c1",
      lines(
        claudeUser("skipped meta", NOW - 90_000, { isMeta: true }),
        claudeUser("skipped sidechain", NOW - 80_000, { isSidechain: true }),
        claudeUser("  First question\n", NOW - 70_000),
        claudeAssistant(
          [
            { type: "thinking", thinking: "hidden" },
            { type: "text", text: "One." },
            { type: "tool_use", id: "t", name: "Read", input: {} },
            { type: "text", text: "Two." },
          ],
          NOW - 60_000,
        ),
        claudeUser([toolResult], NOW - 50_000),
        claudeAssistant([{ type: "tool_use", id: "t", name: "Edit", input: {} }], NOW - 40_000),
        claudeUser([toolResult, { type: "text", text: "Mixed with a result" }], NOW - 30_000),
        {
          type: "assistant",
          message: { role: "assistant", content: [{ type: "text", text: "No time" }] },
        },
      ),
    );
    expect(readChat(home, "claude", "c1")).toEqual({
      version: 1,
      agent: "claude",
      sessionId: "c1",
      title: "First question",
      messages: [
        { at: NOW - 70_000, role: "user", text: "First question" },
        { at: NOW - 60_000, role: "assistant", text: "One.\n\nTwo." },
        { at: NOW - 30_000, role: "user", text: "Mixed with a result" },
        { at: 0, role: "assistant", text: "No time" },
      ],
    });
  });

  it("titles a Claude conversation by the session file's name over the transcript", () => {
    claudeTranscript("c2", lines(claudeUser("Prompt", NOW - 1_000)), "-elsewhere");
    put(
      join(home, ".claude", "sessions", "77.json"),
      JSON.stringify({ pid: 77, sessionId: "c2", cwd: "/elsewhere", name: "Named" }),
    );
    expect(readChat(home, "claude", "c2").title).toBe("Named");
  });

  it("keeps the last 40 messages, oldest first, each clipped to 4000 characters", () => {
    const entries = Array.from({ length: 45 }, (_, n) =>
      n % 2 === 0
        ? claudeUser(`prompt ${n} ${"x".repeat(5_000)}`, NOW - (100 - n) * 1_000)
        : claudeAssistant([{ type: "text", text: `answer ${n}` }], NOW - (100 - n) * 1_000),
    );
    claudeTranscript("c3", lines(...entries));
    const { messages } = readChat(home, "claude", "c3");
    expect(messages).toHaveLength(40);
    expect(messages[0]?.text).toBe("answer 5");
    expect(messages.at(-1)?.text).toMatch(/^prompt 44 x+…$/);
    expect(messages.at(-1)?.text).toHaveLength(4000);
    expect(messages.every((m, i) => i === 0 || m.at >= (messages[i - 1]?.at ?? 0))).toBe(true);
  });

  it("reads a Codex conversation from its UserMessage items and assistant messages", () => {
    const dir = join(home, ".codex", "sessions", "2026", "10", "21");
    const userItem = (text: string, at: number) => ({
      timestamp: iso(at),
      type: "response_item",
      payload: { type: "message", role: "user", content: [{ type: "input_text", text }] },
    });
    put(
      join(dir, "rollout-2026-10-21T00-00-00-x1.jsonl"),
      lines(
        { timestamp: iso(NOW - 99_000), type: "session_meta", payload: { id: "x1", cwd: "/w" } },
        {
          timestamp: iso(NOW - 98_000),
          type: "response_item",
          payload: {
            type: "message",
            role: "developer",
            content: [{ type: "input_text", text: "developer preamble" }],
          },
        },
        userItem("Duplicate of the item below", NOW - 90_000),
        {
          timestamp: iso(NOW - 90_000),
          type: "event_msg",
          payload: {
            type: "item_completed",
            item: { type: "UserMessage", content: [{ type: "text", text: "Fix the build" }] },
          },
        },
        {
          timestamp: iso(NOW - 80_000),
          type: "response_item",
          payload: {
            type: "message",
            role: "assistant",
            content: [
              { type: "output_text", text: "On it." },
              { type: "output_text", text: "Done." },
            ],
          },
        },
      ),
    );
    expect(readChat(home, "codex", "x1")).toEqual({
      version: 1,
      agent: "codex",
      sessionId: "x1",
      title: "Fix the build",
      messages: [
        { at: NOW - 90_000, role: "user", text: "Fix the build" },
        { at: NOW - 80_000, role: "assistant", text: "On it.\n\nDone." },
      ],
    });
  });

  it("falls back to Codex user message items without preambles when there is no UserMessage item", () => {
    const dir = join(home, ".codex", "sessions", "2026", "09", "01");
    const userItem = (text: string, at: number) => ({
      timestamp: iso(at),
      type: "response_item",
      payload: { type: "message", role: "user", content: [{ type: "input_text", text }] },
    });
    put(
      join(dir, "rollout-old-x2.jsonl"),
      lines(
        userItem("# AGENTS.md", NOW - 90_000),
        userItem("<permissions>", NOW - 89_000),
        userItem(">>> review", NOW - 88_000),
        userItem("Real prompt", NOW - 87_000),
      ),
    );
    expect(readChat(home, "codex", "x2").messages).toEqual([
      { at: NOW - 87_000, role: "user", text: "Real prompt" },
    ]);
    expect(readChat(home, "codex", "x2").title).toBe("Real prompt");
  });

  it("reads a Gemini CLI conversation from the first line's messages and the later lines", () => {
    put(
      join(home, ".gemini", "tmp", "cli-probe", "chats", "session-2026-10-21-g1.jsonl"),
      lines(
        {
          $set: {
            messages: [
              {
                type: "user",
                timestamp: iso(NOW - 90_000),
                content: [
                  { text: "<session_context>\ncontext\n</session_context>\n\nProbe the CLI" },
                ],
              },
              {
                type: "user",
                timestamp: iso(NOW - 85_000),
                content: [{ text: "<session_context>\nonly context\n</session_context>" }],
              },
              { type: "gemini", timestamp: iso(NOW - 80_000), content: "Sure." },
            ],
          },
        },
        { type: "info", timestamp: iso(NOW - 70_000), content: "Opening a browser" },
        {
          type: "user",
          timestamp: iso(NOW - 60_000),
          content: [{ text: "Part one" }, { text: "Part two" }],
        },
        {
          type: "gemini",
          timestamp: iso(NOW - 50_000),
          content: "",
          toolCalls: [{ name: "replace" }],
        },
        { type: "gemini", timestamp: iso(NOW - 40_000), content: "Done." },
      ),
    );
    expect(readChat(home, "gemini", "g1")).toEqual({
      version: 1,
      agent: "gemini",
      sessionId: "g1",
      title: "Probe the CLI",
      messages: [
        { at: NOW - 90_000, role: "user", text: "Probe the CLI" },
        { at: NOW - 80_000, role: "assistant", text: "Sure." },
        { at: NOW - 60_000, role: "user", text: "Part one\n\nPart two" },
        { at: NOW - 40_000, role: "assistant", text: "Done." },
      ],
    });
  });

  it("is empty for an unknown agent, a missing transcript and a session id that is not a file name", () => {
    claudeTranscript("c1", lines(claudeUser("Prompt", NOW - 1_000)));
    expect(readChat(home, "aider", "c1")).toEqual(empty("aider", "c1"));
    expect(readChat(home, "claude", "c9")).toEqual(empty("claude", "c9"));
    expect(readChat(home, "codex", "c1")).toEqual(empty("codex", "c1"));
    put(join(home, "x.jsonl"), lines(claudeUser("Outside", NOW - 1_000)));
    for (const weird of ["../x", "../../x", "/x", ".", "..", "a/b", ""]) {
      expect(readChat(home, "claude", weird)).toEqual(empty("claude", weird));
    }
  });

  it("matches the golden contract file", () => {
    const golden = JSON.parse(
      readFileSync("contracts/office-chat.v1.json", "utf8"),
    ) as OfficeChatJson;
    claudeTranscript(
      "c1",
      lines(
        claudeUser("Show the agent's conversation when I click its figure.", NOW - 60_000),
        claudeAssistant(
          [
            {
              type: "text",
              text: "I'll add a chat panel to the Office page that reads the session transcript.",
            },
          ],
          NOW - 40_000,
        ),
        { type: "custom-title", customTitle: "Office chat window", sessionId: "c1" },
      ),
    );
    expect(JSON.parse(JSON.stringify(readChat(home, "claude", "c1")))).toEqual(golden);
  });
});
