import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { McpError, openMcpSession } from "../src/teams/mcp.ts";
import type { McpSession } from "../src/teams/mcp.ts";

const server = fileURLToPath(new URL("./fixtures/fake-mcp-server.ts", import.meta.url));
const open = (mode: string, startTimeoutMs = 5000, callTimeoutMs = 5000): Promise<McpSession> =>
  openMcpSession({
    command: process.execPath,
    args: [server, mode],
    startTimeoutMs,
    callTimeoutMs,
  });

async function withSession<T>(mode: string, use: (session: McpSession) => Promise<T>): Promise<T> {
  const session = await open(mode);
  try {
    return await use(session);
  } finally {
    session.close();
  }
}

describe("openMcpSession", () => {
  it("calls a tool and returns its text", async () => {
    const result = await withSession("ok", (s) => s.callTool("echo", { a: 1 }));
    expect(result).toEqual({ text: 'echo:{"a":1}', isError: false });
  });

  it("ignores log noise that is not JSON on stdout", async () => {
    const result = await withSession("noisy", (s) => s.callTool("echo", {}));
    expect(result.text).toBe("echo:{}");
  });

  it("maps a tool-level error to isError without throwing", async () => {
    const result = await withSession("ok", (s) => s.callTool("fail", {}));
    expect(result).toEqual({ text: "❌ nope", isError: true });
  });

  it("times out when the server never answers initialize", async () => {
    await expect(open("silent", 200)).rejects.toMatchObject({ kind: "timeout" });
  });

  it("times out one hanging call and stays usable for the next", async () => {
    const session = await open("ok", 5000, 200);
    try {
      await expect(session.callTool("hang", {})).rejects.toMatchObject({ kind: "timeout" });
      await expect(session.callTool("echo", {})).resolves.toMatchObject({ text: "echo:{}" });
    } finally {
      session.close();
    }
  });

  it("rejects when the server exits during startup", async () => {
    await expect(open("crash")).rejects.toMatchObject({ kind: "closed" });
  });

  it("reports a missing command as a spawn error", async () => {
    const attempt = openMcpSession({
      command: "/nonexistent/teams-mcp",
      startTimeoutMs: 2000,
      callTimeoutMs: 2000,
    });
    await expect(attempt).rejects.toMatchObject({ kind: "spawn" });
  });

  it("rejects a malformed tool result as a protocol error", async () => {
    await withSession("ok", async (s) => {
      await expect(s.callTool("bad", {})).rejects.toMatchObject({ kind: "protocol" });
    });
  });

  it("rejects calls that are still pending when the session is closed", async () => {
    const session = await open("ok");
    const pending = session.callTool("hang", {});
    session.close();
    await expect(pending).rejects.toBeInstanceOf(McpError);
    await expect(pending).rejects.toMatchObject({ kind: "closed" });
  });
});
