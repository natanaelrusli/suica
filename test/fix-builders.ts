import type { FixThread } from "../src/fix-store.ts";

export const bob = { username: "bob", name: "Bob" };

export function thread(id: string, noteId: string, overrides: Partial<FixThread> = {}): FixThread {
  return {
    id,
    noteId,
    author: bob,
    filePath: "src/a.ts",
    line: 3,
    notes: [{ author: bob, body: "Rename this", createdAt: "2026-10-21T09:00:00Z" }],
    action: null,
    reply: "",
    post: false,
    posted: false,
    ...overrides,
  };
}
