import { clip } from "./describe.ts";
import { readHeadLines, readTail } from "./tail.ts";

/** One turn of a Session's conversation, as `suica office chat` prints it. */
export type ChatRole = "user" | "assistant";
export interface ChatMessage {
  /** Epoch milliseconds, 0 when the transcript does not say. */
  readonly at: number;
  readonly role: ChatRole;
  readonly text: string;
}

const TITLE_MAX = 60;
/** The first prompt is near the start of a transcript; a custom title can be anywhere. */
const CLAUDE_HEAD_BYTES = 256 * 1024;
const CLAUDE_TITLE_TAIL_BYTES = 1024 * 1024;
const CODEX_HEAD_BYTES = 1024 * 1024;
const GEMINI_HEAD_BYTES = 1024 * 1024;
/** A Codex user `message` item that is an AGENTS.md, permissions or review preamble, not a prompt. */
const CODEX_PREAMBLE = /^(#|<|>>>)/;
const CONTEXT_END = "</session_context>";

export const asRecord = (value: unknown): Record<string, unknown> | undefined =>
  typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;

export const parseLine = (line: string): Record<string, unknown> | undefined => {
  try {
    return asRecord(JSON.parse(line));
  } catch {
    return undefined;
  }
};

/** A title from free text: its first non-blank line, whitespace collapsed, at most 60 characters. */
export function titleOf(text: string | null | undefined): string | null {
  const line = text
    ?.split("\n")
    .map((part) => part.replace(/\s+/g, " ").trim())
    .find((part) => part !== "");
  return line === undefined ? null : clip(line, TITLE_MAX);
}

function timeOf(entry: Record<string, unknown>): number {
  const ms = Date.parse(typeof entry["timestamp"] === "string" ? entry["timestamp"] : "");
  return Number.isNaN(ms) ? 0 : Math.floor(ms);
}

/** The `text` of the blocks of `type` (any type when none is given) in a content array, joined by a blank line. */
function blockText(content: unknown, type?: string): string | undefined {
  if (!Array.isArray(content)) return undefined;
  const texts = content.flatMap((item) => {
    const block = asRecord(item);
    const matches = block !== undefined && (type === undefined || block["type"] === type);
    return matches && typeof block["text"] === "string" ? [block["text"]] : [];
  });
  return texts.length === 0 ? undefined : texts.join("\n\n");
}

function message(at: number, role: ChatRole, text: string | undefined): ChatMessage | undefined {
  const trimmed = text?.trim();
  return trimmed === undefined || trimmed === "" ? undefined : { at, role, text: trimmed };
}

/**
 * A Claude Code transcript entry as a chat message: a user prompt (a string, or text blocks; a
 * tool result alone, a meta entry and a sidechain are not prompts) or an assistant answer's text.
 */
function claudeMessage(entry: Record<string, unknown>): ChatMessage | undefined {
  const role = entry["type"];
  if (role !== "user" && role !== "assistant") return undefined;
  if (entry["isMeta"] === true || entry["isSidechain"] === true) return undefined;
  const content = asRecord(entry["message"])?.["content"];
  const text = typeof content === "string" ? content : blockText(content, "text");
  return message(timeOf(entry), role, text);
}

export function claudeMessages(lines: readonly string[]): ChatMessage[] {
  return lines.flatMap((line) => {
    const entry = parseLine(line);
    const found = entry === undefined ? undefined : claudeMessage(entry);
    return found === undefined ? [] : [found];
  });
}

/** The last `custom-title` entry (`/rename`) among the lines. */
function claudeCustomTitle(lines: readonly string[]): string | null {
  for (let index = lines.length - 1; index >= 0; index--) {
    const line = lines[index];
    if (line === undefined || !line.includes('"custom-title"')) continue;
    const entry = parseLine(line);
    if (entry?.["type"] !== "custom-title") continue;
    const title = titleOf(typeof entry["customTitle"] === "string" ? entry["customTitle"] : null);
    if (title !== null) return title;
  }
  return null;
}

/**
 * A Claude Code Session's title: the `name` of its session file, else the last custom title in
 * the transcript, else the first line of its first prompt.
 */
export function claudeTitle(transcript: string | undefined, name?: unknown): string | null {
  const named = typeof name === "string" ? titleOf(name) : null;
  if (named !== null) return named;
  if (transcript === undefined) return null;
  return (
    claudeCustomTitle(readTail(transcript, CLAUDE_TITLE_TAIL_BYTES)) ??
    titleOf(firstPrompt(claudeMessages(readHeadLines(transcript, CLAUDE_HEAD_BYTES))))
  );
}

const firstPrompt = (messages: readonly ChatMessage[]): string | undefined =>
  messages.find((found) => found.role === "user")?.text;

/**
 * Codex rollout lines as chat messages: the user's `UserMessage` items and the assistant's
 * `message` response items. A rollout with no `UserMessage` item (an older Codex) falls back to
 * the user `message` response items that are prompts, not preambles.
 */
export function codexMessages(lines: readonly string[]): ChatMessage[] {
  const found: { readonly message: ChatMessage; readonly fallback: boolean }[] = [];
  let hasItems = false;
  for (const line of lines) {
    const entry = parseLine(line);
    const payload = asRecord(entry?.["payload"]);
    if (entry === undefined || payload === undefined) continue;
    const at = timeOf(entry);
    if (entry["type"] === "event_msg" && payload["type"] === "item_completed") {
      const item = asRecord(payload["item"]);
      if (item?.["type"] !== "UserMessage") continue;
      hasItems = true;
      const first = Array.isArray(item["content"]) ? asRecord(item["content"][0]) : undefined;
      const prompt = message(at, "user", blockText([first], "text"));
      if (prompt !== undefined) found.push({ message: prompt, fallback: false });
      continue;
    }
    if (entry["type"] !== "response_item" || payload["type"] !== "message") continue;
    if (payload["role"] === "assistant") {
      const answer = message(at, "assistant", blockText(payload["content"], "output_text"));
      if (answer !== undefined) found.push({ message: answer, fallback: false });
    } else if (payload["role"] === "user") {
      const prompt = message(at, "user", blockText(payload["content"], "input_text"));
      if (prompt !== undefined && !CODEX_PREAMBLE.test(prompt.text)) {
        found.push({ message: prompt, fallback: true });
      }
    }
  }
  return found.filter((item) => !(hasItems && item.fallback)).map((item) => item.message);
}

/** A Codex Session's title: the first line of its first prompt. */
export function codexTitle(rollout: string): string | null {
  return titleOf(firstPrompt(codexMessages(readHeadLines(rollout, CODEX_HEAD_BYTES))));
}

/** A Gemini CLI message's text, a string or text blocks, without the CLI's session context. */
function geminiText(content: unknown): string | undefined {
  const text = typeof content === "string" ? content : blockText(content);
  if (text === undefined || !text.includes("<session_context>")) return text;
  const end = text.indexOf(CONTEXT_END);
  return end === -1 ? undefined : text.slice(end + CONTEXT_END.length);
}

function geminiMessage(entry: Record<string, unknown>): ChatMessage | undefined {
  const type = entry["type"];
  const role = type === "user" ? "user" : type === "gemini" ? "assistant" : undefined;
  return role === undefined
    ? undefined
    : message(timeOf(entry), role, geminiText(entry["content"]));
}

/**
 * Gemini CLI chat lines as chat messages: the `user` and `gemini` entries, whether in the
 * `$set.messages` list of the first line or one per line; info and tool lines are skipped.
 */
export function geminiMessages(lines: readonly string[]): ChatMessage[] {
  const messages: ChatMessage[] = [];
  for (const line of lines) {
    const entry = parseLine(line);
    if (entry === undefined) continue;
    const set = asRecord(entry["$set"])?.["messages"];
    for (const item of Array.isArray(set) ? set : [entry]) {
      const record = asRecord(item);
      const found = record === undefined ? undefined : geminiMessage(record);
      if (found !== undefined) messages.push(found);
    }
  }
  return messages;
}

/** A Gemini CLI Session's title: the first line of its first prompt that is not context. */
export function geminiTitle(chat: string): string | null {
  const prompt = geminiMessages(readHeadLines(chat, GEMINI_HEAD_BYTES)).find(
    (found) => found.role === "user" && !found.text.startsWith("<"),
  );
  return titleOf(prompt?.text);
}
