import { z } from "zod";
import type { ToolResult } from "./mcp.ts";

export type TeamsFailureKind = "unavailable" | "error";

export class TeamsFailure extends Error {
  readonly kind: TeamsFailureKind;

  constructor(kind: TeamsFailureKind, message: string) {
    super(message);
    this.name = "TeamsFailure";
    this.kind = kind;
  }
}

export interface TeamsUser {
  readonly displayName: string | null;
  readonly userPrincipalName: string;
  readonly mail: string | null;
  readonly id: string;
}

export interface TeamsApi {
  searchUsers(query: string): Promise<TeamsUser[]>;
  /** Returns the id of the 1:1 chat with `email` (Graph returns the existing chat if there is one). */
  openChat(email: string): Promise<string>;
  /** Plain text only. Returns the message id, or "unknown" when the server does not report one. */
  sendMessage(chatId: string, text: string): Promise<string>;
}

export type ToolCaller = (
  name: string,
  args: Readonly<Record<string, unknown>>,
) => Promise<ToolResult>;

const MAX_QUERY_CHARACTERS = 100;

const usersSchema = z.array(
  z.object({
    displayName: z.string().nullable(),
    userPrincipalName: z.string(),
    mail: z.string().nullable(),
    id: z.string(),
  }),
);

/** The Teams MCP puts the query inside `startswith(displayName,'…')`: a quote must be doubled. */
export function escapeODataString(value: string): string {
  return value.replaceAll("'", "''");
}

/** The Teams MCP reports some failures as plain text starting with ❌ without setting isError. */
function failed(result: ToolResult): boolean {
  return result.isError || result.text.startsWith("❌");
}

export function createTeamsApi(call: ToolCaller): TeamsApi {
  return {
    async searchUsers(query) {
      const trimmed = [...query.trim()].slice(0, MAX_QUERY_CHARACTERS).join("");
      if (trimmed.length === 0) return [];
      const result = await call("search_users", { query: escapeODataString(trimmed) });
      if (failed(result)) throw new TeamsFailure("error", "search_users failed");
      if (result.text.startsWith("No users found")) return [];
      let raw: unknown;
      try {
        raw = JSON.parse(result.text);
      } catch {
        throw new TeamsFailure("error", "search_users returned text that is not JSON");
      }
      const parsed = usersSchema.safeParse(raw);
      if (!parsed.success)
        throw new TeamsFailure("error", "search_users returned an unexpected shape");
      return parsed.data;
    },

    async openChat(email) {
      const result = await call("create_chat", { userEmails: [email] });
      const id = /Chat ID:\s*(\S+)/.exec(result.text)?.[1];
      if (failed(result) || id === undefined) throw new TeamsFailure("error", "create_chat failed");
      return id;
    },

    async sendMessage(chatId, text) {
      const result = await call("send_chat_message", { chatId, message: text, format: "markdown" });
      if (failed(result) || !result.text.includes("sent successfully")) {
        throw new TeamsFailure("error", "send_chat_message failed");
      }
      return /Message ID:\s*(\S+)/.exec(result.text)?.[1] ?? "unknown";
    },
  };
}
