import { TeamsFailure, createTeamsApi } from "./api.ts";
import type { TeamsApi } from "./api.ts";
import { McpError, openMcpSession } from "./mcp.ts";
import type { McpOptions, McpSession } from "./mcp.ts";

export interface TeamsGateway {
  /** Starts the Teams MCP, runs `use` with an API bound to it, and always stops the server again. */
  session<T>(use: (api: TeamsApi) => Promise<T>): Promise<T>;
}

function toFailure(error: unknown): TeamsFailure {
  if (error instanceof TeamsFailure) return error;
  if (error instanceof McpError) {
    const transport = error.kind === "spawn" || error.kind === "timeout" || error.kind === "closed";
    return new TeamsFailure(transport ? "unavailable" : "error", `MCP ${error.kind}`);
  }
  return new TeamsFailure("error", "unexpected Teams failure");
}

export function createTeamsGateway(
  options: McpOptions,
  open: (options: McpOptions) => Promise<McpSession> = openMcpSession,
): TeamsGateway {
  return {
    async session(use) {
      let mcp: McpSession;
      try {
        mcp = await open(options);
      } catch (error) {
        throw toFailure(error);
      }
      const api = createTeamsApi(async (name, args) => {
        try {
          return await mcp.callTool(name, args);
        } catch (error) {
          throw toFailure(error);
        }
      });
      try {
        return await use(api);
      } finally {
        mcp.close();
      }
    },
  };
}
