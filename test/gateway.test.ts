import { describe, expect, it } from "vitest";
import { TeamsFailure } from "../src/teams/api.ts";
import { createTeamsGateway } from "../src/teams/gateway.ts";
import { McpError } from "../src/teams/mcp.ts";
import type { McpOptions, McpSession } from "../src/teams/mcp.ts";

const options: McpOptions = { command: "x", startTimeoutMs: 1000, callTimeoutMs: 1000 };

function fakeSession(callTool: McpSession["callTool"]): {
  session: McpSession;
  closed: () => number;
} {
  let closes = 0;
  return {
    session: {
      callTool,
      close: () => {
        closes += 1;
      },
    },
    closed: () => closes,
  };
}

describe("createTeamsGateway", () => {
  it("opens one session per use and always closes it", async () => {
    const fake = fakeSession(() =>
      Promise.resolve({ text: "No users found matching your search.", isError: false }),
    );
    const gateway = createTeamsGateway(options, () => Promise.resolve(fake.session));
    await expect(gateway.session((api) => api.searchUsers("a"))).resolves.toEqual([]);
    expect(fake.closed()).toBe(1);
    await expect(gateway.session(() => Promise.reject(new Error("boom")))).rejects.toThrow("boom");
    expect(fake.closed()).toBe(2);
  });

  it("reports a server that cannot be started as unavailable", async () => {
    const gateway = createTeamsGateway(options, () => Promise.reject(new McpError("timeout", "t")));
    await expect(gateway.session(() => Promise.resolve(1))).rejects.toMatchObject({
      name: "TeamsFailure",
      kind: "unavailable",
    });
  });

  it("maps transport problems to unavailable and protocol or server problems to error", async () => {
    const attempt = async (kind: McpError["kind"]): Promise<string> => {
      const fake = fakeSession(() => Promise.reject(new McpError(kind, "x")));
      const gateway = createTeamsGateway(options, () => Promise.resolve(fake.session));
      try {
        await gateway.session((api) => api.searchUsers("a"));
      } catch (error) {
        if (error instanceof TeamsFailure) return error.kind;
      }
      return "none";
    };
    expect(await attempt("timeout")).toBe("unavailable");
    expect(await attempt("closed")).toBe("unavailable");
    expect(await attempt("spawn")).toBe("unavailable");
    expect(await attempt("protocol")).toBe("error");
    expect(await attempt("server")).toBe("error");
  });
});
