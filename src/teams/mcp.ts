import { spawn } from "node:child_process";
import { z } from "zod";

export type McpErrorKind = "spawn" | "timeout" | "closed" | "protocol" | "server";

export class McpError extends Error {
  readonly kind: McpErrorKind;

  constructor(kind: McpErrorKind, message: string) {
    super(message);
    this.name = "McpError";
    this.kind = kind;
  }
}

export interface ToolResult {
  readonly text: string;
  readonly isError: boolean;
}

export interface McpSession {
  callTool(name: string, args: Readonly<Record<string, unknown>>): Promise<ToolResult>;
  /** Stops the server and fails every call still waiting. Safe to call more than once. */
  close(): void;
}

export interface McpOptions {
  readonly command: string;
  readonly args?: readonly string[];
  readonly startTimeoutMs: number;
  readonly callTimeoutMs: number;
}

const PROTOCOL_VERSION = "2025-03-26";
const CLIENT_INFO = { name: "mr-review-assistant", version: "0.1.0" };

const frameSchema = z.object({
  id: z.number().optional(),
  result: z.unknown().optional(),
  error: z.object({ message: z.string() }).optional(),
});
const toolResultSchema = z.object({
  content: z.array(z.object({ type: z.string(), text: z.string().optional() })),
  isError: z.boolean().optional(),
});

interface Pending {
  readonly resolve: (value: unknown) => void;
  readonly reject: (error: McpError) => void;
  readonly timer: ReturnType<typeof setTimeout>;
}

/**
 * Minimal MCP client over stdio: newline-delimited JSON-RPC, `initialize` then `tools/call`.
 * The server's stderr is ignored; lines on stdout that are not JSON-RPC frames are skipped.
 */
export async function openMcpSession(options: McpOptions): Promise<McpSession> {
  const child = spawn(options.command, [...(options.args ?? [])], {
    stdio: ["pipe", "pipe", "ignore"],
  });
  const pending = new Map<number, Pending>();
  let nextId = 1;
  let closed = false;
  let buffer = "";

  const failAll = (error: McpError): void => {
    closed = true;
    for (const entry of pending.values()) {
      clearTimeout(entry.timer);
      entry.reject(error);
    }
    pending.clear();
  };

  child.on("error", (error: NodeJS.ErrnoException) => {
    failAll(
      new McpError(
        "spawn",
        error.code === "ENOENT" ? "MCP command not found" : "MCP process error",
      ),
    );
  });
  child.on("exit", () => {
    failAll(new McpError("closed", "MCP server exited"));
  });
  child.stdin.on("error", () => {
    failAll(new McpError("closed", "MCP server closed its input"));
  });

  const handleLine = (line: string): void => {
    let raw: unknown;
    try {
      raw = JSON.parse(line);
    } catch {
      return; // A log line, not a JSON-RPC frame.
    }
    const frame = frameSchema.safeParse(raw);
    if (!frame.success || frame.data.id === undefined) return;
    const entry = pending.get(frame.data.id);
    if (entry === undefined) return;
    pending.delete(frame.data.id);
    clearTimeout(entry.timer);
    if (frame.data.error !== undefined) {
      entry.reject(new McpError("server", "MCP server returned an error"));
    } else {
      entry.resolve(frame.data.result);
    }
  };

  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk: string) => {
    buffer += chunk;
    for (;;) {
      const end = buffer.indexOf("\n");
      if (end < 0) break;
      const line = buffer.slice(0, end).trim();
      buffer = buffer.slice(end + 1);
      if (line.length > 0) handleLine(line);
    }
  });

  const write = (message: object): void => {
    if (!closed) child.stdin.write(`${JSON.stringify(message)}\n`);
  };

  const request = (method: string, params: object, timeoutMs: number): Promise<unknown> =>
    new Promise((resolve, reject) => {
      if (closed) {
        reject(new McpError("closed", "MCP server is not running"));
        return;
      }
      const id = nextId;
      nextId += 1;
      const timer = setTimeout(() => {
        pending.delete(id);
        reject(new McpError("timeout", `MCP ${method} timed out`));
      }, timeoutMs);
      pending.set(id, { resolve, reject, timer });
      write({ jsonrpc: "2.0", id, method, params });
    });

  const close = (): void => {
    const wasOpen = !closed;
    failAll(new McpError("closed", "MCP session closed"));
    if (wasOpen) child.kill("SIGTERM");
  };

  try {
    await request(
      "initialize",
      { protocolVersion: PROTOCOL_VERSION, capabilities: {}, clientInfo: CLIENT_INFO },
      options.startTimeoutMs,
    );
    write({ jsonrpc: "2.0", method: "notifications/initialized" });
  } catch (error) {
    close();
    throw error;
  }

  return {
    async callTool(name, args) {
      const raw = await request("tools/call", { name, arguments: args }, options.callTimeoutMs);
      const parsed = toolResultSchema.safeParse(raw);
      if (!parsed.success) throw new McpError("protocol", "unexpected tools/call result");
      return {
        text: parsed.data.content
          .flatMap((part) => (part.type === "text" && part.text !== undefined ? [part.text] : []))
          .join("\n"),
        isError: parsed.data.isError === true,
      };
    },
    close,
  };
}
