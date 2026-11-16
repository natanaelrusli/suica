import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { openStore } from "../src/store.ts";
import type { PostPart } from "../src/review-post.ts";

const dirs: string[] = [];
function dbPath(): string {
  const dir = mkdtempSync(join(tmpdir(), "review-post-"));
  dirs.push(dir);
  return join(dir, "state.db");
}
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});
function ready(path = ":memory:") {
  const store = openStore(path);
  const id = store.queueAgentReview("g/p!1", "manual", 1)!;
  store.transitionAgentReview(id, ["queued"], "running", {}, 1);
  store.transitionAgentReview(id, ["running"], "ready", { body: "review" }, 1);
  return { store, id };
}
const part = (key: string, state: PostPart["state"] = "pending"): PostPart => ({
  key,
  kind: "inline",
  endpoint: "/notes",
  payload: JSON.stringify({ body: key }),
  state,
  remoteId: null,
});

describe("review posting journal", () => {
  it("claims a ready review and blocks another owner until the 15 minute lease expires", () => {
    const { store, id } = ready();
    expect(store.claimReviewPosting(id, "one", 100)?.expiresAt).toBe(900100);
    expect(store.claimReviewPosting(id, "two", 100)).toBeUndefined();
    expect(store.claimReviewPosting(id, "two", 900100)?.token).toBe("two");
    store.close();
  });
  it("fences a stale owner and changes interrupted sending work to uncertain", () => {
    const { store, id } = ready();
    const old = store.claimReviewPosting(id, "one", 100)!;
    expect(store.saveReviewPostPlan(old, [part("a", "sending")], 100));
    const next = store.claimReviewPosting(id, "two", 900100)!;
    expect(store.reviewPostParts(id)[0]?.state).toBe("uncertain");
    expect(store.updateReviewPostPart(old, "a", "confirmed", "remote", 900101)).toBe(false);
    expect(store.renewReviewPosting(old, 900101)).toBe(false);
    expect(next.token).toBe("two");
    store.close();
  });
  it("freezes the plan and persists confirmed remote IDs across reopen", () => {
    const path = dbPath();
    const { id, ...first } = ready(path);
    let store = first.store;
    const lease = store.claimReviewPosting(id, "one", 100)!;
    expect(store.saveReviewPostPlan(lease, [part("a")], 100));
    expect(store.saveReviewPostPlan(lease, [part("b")], 100));
    expect(store.updateReviewPostPart(lease, "a", "confirmed", "remote-1", 101)).toBe(true);
    store.close();
    store = openStore(path);
    expect(store.reviewPostParts(id)).toMatchObject([
      { key: "a", remoteId: "remote-1", state: "confirmed" },
    ]);
    store.close();
  });
  it("finishes only with every part confirmed under the current lease", () => {
    const { store, id } = ready();
    const lease = store.claimReviewPosting(id, "one", 100)!;
    expect(store.saveReviewPostPlan(lease, [part("a"), part("b", "uncertain")], 100));
    expect(store.finishReviewPosting(lease, 101)).toBe(false);
    expect(store.updateReviewPostPart(lease, "b", "confirmed", "b", 102)).toBe(true);
    expect(store.updateReviewPostPart(lease, "a", "confirmed", "a", 103)).toBe(true);
    expect(store.finishReviewPosting(lease, 104)).toBe(true);
    expect(store.getAgentReview(id)?.status).toBe("posted");
    expect(store.claimReviewPosting(id, "later", 105)).toBeUndefined();
    store.close();
  });
});
