import { existsSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { readSessionFiles } from "./claude.ts";
import { clip } from "./describe.ts";
import { readTail } from "./tail.ts";
import {
  claudeMessages,
  claudeTitle,
  codexMessages,
  codexTitle,
  geminiMessages,
  geminiTitle,
  type ChatMessage,
} from "./transcript.ts";

export type { ChatMessage, ChatRole } from "./transcript.ts";

/** The document `suica office chat <agent> <sessionId> --json` prints; see contracts/office-chat.v1.json. */
export interface OfficeChatJson {
  readonly version: 1;
  readonly agent: string;
  readonly sessionId: string;
  readonly title: string | null;
  /** Oldest first, at most 40. */
  readonly messages: readonly ChatMessage[];
}

const MAX_MESSAGES = 40;
const MAX_CHARS = 4000;
/** Tool results make a transcript large and its messages sparse: 32 MB of one held 9. */
const TAIL_BYTES = 64 * 1024 * 1024;
/** A session id is a file name: nothing that could leave the agent's folder. */
export const SAFE_ID = /^[A-Za-z0-9_-][A-Za-z0-9._-]*$/;

function list(dir: string): string[] {
  try {
    return readdirSync(dir);
  } catch {
    return [];
  }
}

/** The transcript under `~/.claude/projects`, in whichever project folder holds it. */
function claudeTranscript(home: string, sessionId: string): string | undefined {
  const projects = join(home, ".claude", "projects");
  for (const project of list(projects)) {
    const path = join(projects, project, `${sessionId}.jsonl`);
    if (existsSync(path)) return path;
  }
  return undefined;
}

/** The `rollout-…<sessionId>.jsonl` under `~/.codex/sessions/YYYY/MM/DD`, newest day first. */
function codexRollout(home: string, sessionId: string): string | undefined {
  const root = join(home, ".codex", "sessions");
  const newestFirst = (dir: string): string[] => list(dir).sort().reverse();
  for (const year of newestFirst(root)) {
    for (const month of newestFirst(join(root, year))) {
      for (const day of newestFirst(join(root, year, month))) {
        const dir = join(root, year, month, day);
        const name = list(dir).find(
          (file) => file.startsWith("rollout-") && file.endsWith(`${sessionId}.jsonl`),
        );
        if (name !== undefined) return join(dir, name);
      }
    }
  }
  return undefined;
}

/** The `session-…<sessionId>.jsonl` under a project's `chats` folder in `~/.gemini/tmp`. */
export function geminiChat(home: string, sessionId: string): string | undefined {
  const tmp = join(home, ".gemini", "tmp");
  for (const project of list(tmp)) {
    const dir = join(tmp, project, "chats");
    const name = list(dir).find(
      (file) => file.startsWith("session-") && file.endsWith(`${sessionId}.jsonl`),
    );
    if (name !== undefined) return join(dir, name);
  }
  return undefined;
}

function claudeName(home: string, sessionId: string): unknown {
  for (const file of readSessionFiles(home).values()) {
    if (file["sessionId"] === sessionId) return file["name"];
  }
  return undefined;
}

interface Source {
  readonly find: (home: string, sessionId: string) => string | undefined;
  readonly messages: (lines: readonly string[]) => ChatMessage[];
  readonly title: (home: string, sessionId: string, path: string) => string | null;
}

const SOURCES: Readonly<Record<string, Source>> = {
  claude: {
    find: claudeTranscript,
    messages: claudeMessages,
    title: (home, sessionId, path) => claudeTitle(path, claudeName(home, sessionId)),
  },
  codex: {
    find: codexRollout,
    messages: codexMessages,
    title: (_home, _id, path) => codexTitle(path),
  },
  gemini: {
    find: geminiChat,
    messages: geminiMessages,
    title: (_home, _id, path) => geminiTitle(path),
  },
};

/**
 * The last 40 messages of one Session's conversation, oldest first, each at most 4000
 * characters, from the tail of its transcript. An unknown agent or a transcript that cannot be
 * found gives an empty conversation.
 */
export function readChat(home: string, agent: string, sessionId: string): OfficeChatJson {
  const empty: OfficeChatJson = { version: 1, agent, sessionId, title: null, messages: [] };
  const source = SOURCES[agent];
  if (source === undefined || !SAFE_ID.test(sessionId)) return empty;
  const path = source.find(home, sessionId);
  if (path === undefined) return empty;
  const messages = source
    .messages(readTail(path, TAIL_BYTES))
    .slice(-MAX_MESSAGES)
    .map((found) => ({ at: found.at, role: found.role, text: clip(found.text, MAX_CHARS) }));
  return { version: 1, agent, sessionId, title: source.title(home, sessionId, path), messages };
}
