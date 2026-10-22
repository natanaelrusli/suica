import { readFileSync } from "node:fs";
import type { Exec } from "../exec.ts";
import { MODEL_CLI_IDS, type ModelCliId } from "../model-cli.ts";
import { SAFE_ID, geminiChat } from "./chat.ts";
import type { OfficeSession } from "./types.ts";

/** One turn may run tools for a while; past this the agent is stopped and the send failed. */
export const SEND_TIMEOUT_MS = 30 * 60_000;
export const MAX_MESSAGE_CHARS = 8_000;

/** What `suica office send` prints as `{"status": …}`. */
export type SendOutcome =
  "sent" | "busy" | "not_found" | "unsupported" | "agent_missing" | "empty" | "too_long" | "failed";

/**
 * The arguments of one headless turn that resumes the Session. The message always follows `--`
 * or is bound to `--prompt=`, so a message that starts with `-` can never be read as a flag. No
 * permission flag is added: the agent runs with the Owner's own settings.
 */
export function sendArgs(agent: ModelCliId, resumeId: string, message: string): string[] {
  switch (agent) {
    case "claude":
      return ["-p", "--resume", resumeId, "--", message];
    case "codex":
      return ["exec", "resume", "--skip-git-repo-check", resumeId, "--", message];
    case "gemini":
      return ["--resume", resumeId, `--prompt=${message}`];
  }
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Gemini CLI resumes by its full session id, which only the chat file's first line holds: the
 * Office names a Gemini Session by the file's name.
 */
export function geminiResumeId(home: string, sessionId: string): string | null {
  if (!SAFE_ID.test(sessionId)) return null;
  const path = geminiChat(home, sessionId);
  if (path === undefined) return null;
  try {
    const first = readFileSync(path, "utf8").split("\n", 1)[0] ?? "";
    const parsed: unknown = JSON.parse(first);
    if (typeof parsed !== "object" || parsed === null || !("sessionId" in parsed)) return null;
    const id = parsed.sessionId;
    return typeof id === "string" && UUID.test(id) ? id : null;
  } catch {
    return null;
  }
}

export interface SendDeps {
  /** The Sessions detection sees now, as `suica office --json` prints them. */
  readonly sessions: () => readonly OfficeSession[];
  /** The agent CLI's executable, or null when it is not installed. */
  readonly cliPath: (agent: ModelCliId) => string | null;
  readonly geminiResumeId: (sessionId: string) => string | null;
  readonly exec: Exec;
}

const isModelCli = (agent: string): agent is ModelCliId =>
  (MODEL_CLI_IDS as readonly string[]).includes(agent);

/**
 * Sends the Owner's message to a Session as one headless turn of its agent, in the folder the
 * Session runs in, and waits for the turn to end. The answer lands in the Session's transcript,
 * where the Chat Panel reads it.
 */
export async function sendToSession(
  deps: SendDeps,
  agent: string,
  sessionId: string,
  rawMessage: string,
): Promise<SendOutcome> {
  const message = rawMessage.trim();
  if (message === "") return "empty";
  if (message.length > MAX_MESSAGE_CHARS) return "too_long";
  if (!isModelCli(agent)) return "unsupported";
  const session = deps
    .sessions()
    .find((found) => found.agent === agent && found.sessionId === sessionId);
  if (session === undefined) return "not_found";
  // A second turn on top of a running one would interleave both in one transcript.
  if (session.status === "working") return "busy";
  const cli = deps.cliPath(agent);
  if (cli === null) return "agent_missing";
  const resumeId = agent === "gemini" ? deps.geminiResumeId(sessionId) : sessionId;
  if (resumeId === null) return "not_found";
  try {
    await deps.exec(cli, sendArgs(agent, resumeId, message), {
      timeoutMs: SEND_TIMEOUT_MS,
      cwd: session.cwd,
    });
    return "sent";
  } catch {
    // A non-zero exit, a timeout or a missing folder; the agent's own output says which.
    return "failed";
  }
}
