import { describe, expect, it } from "vitest";
import {
  MAX_MESSAGE_CHARS,
  fetchMessageContext,
  kindOf,
  parseMessageRequest,
} from "../src/teams/manual.ts";
import type { MessageRequest } from "../src/teams/manual.ts";

const request = (overrides: Partial<MessageRequest> = {}): MessageRequest => ({
  to: "bob",
  template: "nudge",
  text: null,
  send: false,
  ...overrides,
});

function response(overrides: Record<string, unknown> = {}): unknown {
  return {
    data: {
      currentUser: { username: "me", name: "Nata" },
      project: {
        mergeRequest: {
          title: "Add thing",
          webUrl: "https://gitlab.example/g/p/-/merge_requests/5",
          author: { username: "alice", name: "Alice" },
          reviewers: {
            nodes: [
              { username: "bob", name: "Bob" },
              { username: "me", name: "Nata" },
            ],
          },
          ...overrides,
        },
      },
    },
  };
}

describe("parseMessageRequest", () => {
  it("reads a request and treats a blank text as none", () => {
    expect(
      parseMessageRequest('{"to":"bob","template":"rereview","text":"  ","send":true}'),
    ).toEqual(request({ template: "rereview", send: true }));
    expect(
      parseMessageRequest('{"to":"bob","template":"nudge","text":" Hi ","send":true}'),
    ).toEqual(request({ text: "Hi", send: true }));
  });

  it("refuses an unknown template, a missing field, a long text and bad JSON", () => {
    expect(
      parseMessageRequest('{"to":"bob","template":"alert.summary","text":null,"send":true}'),
    ).toBeUndefined();
    expect(parseMessageRequest('{"to":"bob","text":null,"send":true}')).toBeUndefined();
    const long = JSON.stringify(request({ text: "x".repeat(MAX_MESSAGE_CHARS + 1) }));
    expect(parseMessageRequest(long)).toBeUndefined();
    expect(parseMessageRequest("{")).toBeUndefined();
  });
});

describe("kindOf", () => {
  it("files each template under its flow", () => {
    expect(kindOf("nudge")).toBe("nudge");
    expect(kindOf("reminder")).toBe("reminder");
    expect(kindOf("rereview")).toBe("rereview");
    expect(kindOf("notice.approved")).toBe("notice");
    expect(kindOf("notice.findings")).toBe("notice");
  });
});

describe("fetchMessageContext", () => {
  const fetch = (to: string, raw = response()) =>
    fetchMessageContext(() => Promise.resolve(raw), "g/p!5", request({ to }), 7);

  it("builds a manual intent for a Reviewer or the Author", async () => {
    const context = await fetch("bob");
    expect(context).toEqual({
      owner: { username: "me", name: "Nata" },
      intent: {
        dedupeKey: "manual:g/p!5:bob:7",
        kind: "nudge",
        variant: "nudge",
        mr: {
          key: "g/p!5",
          iid: 5,
          projectPath: "g/p",
          title: "Add thing",
          url: "https://gitlab.example/g/p/-/merge_requests/5",
        },
        recipient: { username: "bob", name: "Bob" },
      },
    });
    expect((await fetch("alice"))?.intent.recipient).toEqual({ username: "alice", name: "Alice" });
  });

  it("refuses someone outside the MR and the Owner", async () => {
    expect(await fetch("mallory")).toBeUndefined();
    expect(await fetch("me")).toBeUndefined();
  });

  it("fails on a missing MR and a bad key", async () => {
    await expect(fetch("bob", response({ title: 1 }))).rejects.toThrow("merge request not found");
    await expect(
      fetchMessageContext(() => Promise.resolve(response()), "nope", request(), 7),
    ).rejects.toThrow("bad merge request key");
  });
});
