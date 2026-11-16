import { describe, expect, it, vi } from "vitest";
import { resumeReviewPosting, type ReviewPostDeps } from "../src/review-post.ts";

function fixture(state: "ready" | "posting" = "ready") {
  const row = { id: 1, status: state, headSha: "abc", mrKey: "group/project!1" } as never;
  const store = {
    getAgentReview: () => row,
    claimReviewPosting: (_id: number, token: string, now: number) => ({ reviewId: 1, token, expiresAt: now + 900000 }),
    saveReviewPostPlan: vi.fn((_lease, parts) => { persisted = parts; return true; }),
    reviewPostParts: () => persisted,
    renewReviewPosting: () => true,
    updateReviewPostPart: vi.fn((_lease, key, next, remoteId) => { persisted = persisted.map((p) => p.key === key ? { ...p, state: next, remoteId } : p); return true; }),
    finishReviewPosting: () => persisted.every((p) => p.state === "confirmed"),
    transitionAgentReview: vi.fn(() => true),
  } as never;
  let persisted: any[] = [];
  const deps: ReviewPostDeps = { store, post: vi.fn(async () => ({ id: 7 })), postJson: vi.fn(async () => ({ id: 8 })), rest: vi.fn(async () => []), log: vi.fn(), now: () => 100, ownerUsername: "owner", preflight: async () => true, buildPlan: async () => [{ key: "summary", kind: "summary", endpoint: "/notes", payload: JSON.stringify({ body: "review" }), state: "pending", remoteId: null }], token: () => "token" };
  return { deps, store, get parts() { return persisted; } };
}

describe("resumeReviewPosting", () => {
  it("freezes a sanitized marked payload and confirms a successful write", async () => {
    const f = fixture();
    expect(await resumeReviewPosting(f.deps, 1)).toBe("posted");
    expect(f.parts[0].payload).toContain("<!-- suica-review:1:abc:summary -->");
    expect(f.deps.post).toHaveBeenCalledTimes(1);
  });
  it("holds an ambiguous transport failure and does not resend", async () => {
    const f = fixture();
    f.deps.post = vi.fn(async () => { throw new Error("timeout"); });
    expect(await resumeReviewPosting(f.deps, 1)).toBe("held");
    expect(await resumeReviewPosting(f.deps, 1)).toBe("held");
    expect(f.deps.post).toHaveBeenCalledTimes(1);
  });
  it("holds when preflight fails before writes", async () => {
    const f = fixture(); f.deps.preflight = async () => false;
    expect(await resumeReviewPosting(f.deps, 1)).toBe("held");
    expect(f.deps.post).not.toHaveBeenCalled();
  });
});
