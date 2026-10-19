import { describe, expect, it } from "vitest";
import type { ToolResult } from "../src/teams/mcp.ts";
import { TeamsFailure, createTeamsApi, escapeODataString } from "../src/teams/api.ts";

function fakeCaller(result: ToolResult): {
  calls: { name: string; args: Record<string, unknown> }[];
  call: (name: string, args: Readonly<Record<string, unknown>>) => Promise<ToolResult>;
} {
  const calls: { name: string; args: Record<string, unknown> }[] = [];
  return {
    calls,
    call: (name, args) => {
      calls.push({ name, args: { ...args } });
      return Promise.resolve(result);
    },
  };
}
const ok = (text: string): ToolResult => ({ text, isError: false });

describe("escapeODataString", () => {
  it("doubles single quotes so a name cannot break out of the filter", () => {
    expect(escapeODataString("O'Brien")).toBe("O''Brien");
    expect(escapeODataString("a') or (displayName ne '")).toBe("a'') or (displayName ne ''");
    expect(escapeODataString("100% ✓ \\")).toBe("100% ✓ \\");
  });
});

describe("searchUsers", () => {
  const users = [
    { displayName: "Rayhan A", userPrincipalName: "rayhan@x.id", mail: "rayhan@x.id", id: "u1" },
    { displayName: null, userPrincipalName: "svc@x.id", mail: null, id: "u2" },
  ];

  it("parses the JSON list and sends an escaped, trimmed query", async () => {
    const { calls, call } = fakeCaller(ok(JSON.stringify(users)));
    await expect(createTeamsApi(call).searchUsers("  O'Brien ")).resolves.toEqual(users);
    expect(calls).toEqual([{ name: "search_users", args: { query: "O''Brien" } }]);
  });

  it("shortens a very long query to 100 characters before escaping", async () => {
    const { calls, call } = fakeCaller(ok("No users found matching your search."));
    await createTeamsApi(call).searchUsers("x".repeat(300));
    expect(String(calls[0]?.args["query"])).toHaveLength(100);
  });

  it("returns an empty list without calling Teams for an empty query", async () => {
    const { calls, call } = fakeCaller(ok("[]"));
    await expect(createTeamsApi(call).searchUsers("   ")).resolves.toEqual([]);
    expect(calls).toHaveLength(0);
  });

  it("returns an empty list for the 'no users' text", async () => {
    const { call } = fakeCaller(ok("No users found matching your search."));
    await expect(createTeamsApi(call).searchUsers("zzz")).resolves.toEqual([]);
  });

  it("fails on error text that is not flagged as an error, on non-JSON and on a wrong shape", async () => {
    for (const text of ["❌ Error: Insufficient privileges", "<html>", '[{"id":1}]']) {
      const { call } = fakeCaller(ok(text));
      await expect(createTeamsApi(call).searchUsers("a")).rejects.toMatchObject({ kind: "error" });
    }
  });
});

describe("openChat", () => {
  it("returns the chat id from the success text", async () => {
    const { calls, call } = fakeCaller(
      ok("✅ Chat created successfully. Chat ID: 19:abc@unq.gbl.spaces"),
    );
    await expect(createTeamsApi(call).openChat("rayhan@x.id")).resolves.toBe(
      "19:abc@unq.gbl.spaces",
    );
    expect(calls).toEqual([{ name: "create_chat", args: { userEmails: ["rayhan@x.id"] } }]);
  });

  it("fails when there is no chat id or the text is an error", async () => {
    for (const result of [ok("❌ Error: nope"), ok("✅ done"), { text: "x", isError: true }]) {
      const { call } = fakeCaller(result);
      await expect(createTeamsApi(call).openChat("a@x.id")).rejects.toBeInstanceOf(TeamsFailure);
    }
  });
});

describe("sendMessage", () => {
  it("sends Markdown, so links are clickable, and returns the message id", async () => {
    const { calls, call } = fakeCaller(ok("✅ Message sent successfully. Message ID: 1699"));
    await expect(createTeamsApi(call).sendMessage("19:abc", "halo")).resolves.toBe("1699");
    expect(calls).toEqual([
      {
        name: "send_chat_message",
        args: { chatId: "19:abc", message: "halo", format: "markdown" },
      },
    ]);
  });

  it("fails on an error result or on text that does not confirm the send", async () => {
    for (const result of [
      { text: "❌ Failed to send message: 403", isError: true },
      ok("something else"),
    ]) {
      const { call } = fakeCaller(result);
      await expect(createTeamsApi(call).sendMessage("c", "t")).rejects.toMatchObject({
        kind: "error",
      });
    }
  });
});
