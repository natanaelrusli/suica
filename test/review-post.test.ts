import { describe, expect, it, vi } from "vitest";
import { resumeReviewPosting, type ReviewPostDeps } from "../src/review-post.ts";
import { openStore } from "../src/store.ts";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FetchFailure } from "../src/gitlab.ts";

const marker = "<!-- suica-review:1:abc:summary -->";
function fixture() {
  const dir = mkdtempSync(join(tmpdir(), "review-post-run-"));
  const store = openStore(join(dir, "state.db"));
  const id = store.queueAgentReview("g/p!1", "manual", 1)!;
  store.transitionAgentReview(id, ["queued"], "running", {}, 1);
  store.transitionAgentReview(id, ["running"], "ready", { body: "review", headSha: "abc" }, 1);
  let now = 100;
  const row = store.getAgentReview(id)!;
  const deps: ReviewPostDeps = {
    store,
    post: vi.fn(async () => ({ id: 7 })),
    postJson: vi.fn(async () => ({ id: 8 })),
    rest: vi.fn(async () => []),
    log: vi.fn(),
    now: () => now,
    ownerUsername: "owner",
    preflight: async () => true,
    buildPlan: async () => [
      {
        key: "summary",
        kind: "summary",
        endpoint: "/notes",
        payload: JSON.stringify({ body: "review" }),
        state: "pending",
        remoteId: null,
      },
    ],
    token: () => `t${now}`,
  };
  return {
    deps,
    store,
    row,
    advance: (n: number) => {
      now = n;
    },
    close: () => {
      store.close();
      rmSync(dir, { recursive: true, force: true });
    },
  };
}
const note = (id: number, body = marker, username = "owner") => ({
  id,
  body,
  author: { username },
});
describe("resumeReviewPosting", () => {
  it("freezes payload and persists acknowledged IDs", async () => {
    const f = fixture();
    expect(await resumeReviewPosting(f.deps, 1)).toBe("posted");
    expect(f.store.reviewPostParts(1)[0]).toMatchObject({ state: "confirmed", remoteId: "7" });
    expect(f.store.reviewPostParts(1)[0]?.payload).toContain(marker);
    f.close();
  });
  it("recovers a lost response after lease expiry without duplicate writes", async () => {
    const f = fixture();
    f.deps.post = vi.fn(async () => {
      throw new Error("timeout");
    });
    expect(await resumeReviewPosting(f.deps, 1)).toBe("held");
    f.advance(900101);
    f.deps.rest = vi.fn(async () => [note(44)]);
    expect(await resumeReviewPosting(f.deps, 1)).toBe("posted");
    expect(f.store.reviewPostParts(1)[0]).toMatchObject({ state: "confirmed", remoteId: "44" });
    expect(f.deps.post).toHaveBeenCalledTimes(1);
    f.close();
  });
  it("holds an absent uncertain marker without another write", async () => {
    const f = fixture();
    f.deps.post = vi.fn(async () => {
      throw new Error("timeout");
    });
    expect(await resumeReviewPosting(f.deps, 1)).toBe("held");
    f.advance(900101);
    expect(await resumeReviewPosting(f.deps, 1)).toBe("held");
    expect(f.deps.post).toHaveBeenCalledTimes(1);
    f.close();
  });
  it("records a definite HTTP 400 rejection and never retries that part", async () => {
    const f = fixture();
    f.deps.post = vi.fn(async () => {
      throw new FetchFailure("gitlab-error", "refused", 400);
    });
    expect(await resumeReviewPosting(f.deps, 1)).toBe("held");
    expect(f.store.reviewPostParts(1)[0]).toMatchObject({ state: "rejected", remoteId: null });
    f.advance(900101);
    expect(await resumeReviewPosting(f.deps, 1)).toBe("held");
    expect(f.deps.post).toHaveBeenCalledTimes(1);
    expect(f.store.getAgentReview(1)).toMatchObject({ status: "posting" });
    f.close();
  });
  it("reconciles inline discussion notes and ignores foreign authors", async () => {
    const f = fixture();
    f.deps.postJson = vi.fn(async () => ({}));
    f.deps.buildPlan = async () => [
      {
        key: "summary",
        kind: "inline",
        endpoint: "/notes",
        payload: JSON.stringify({ body: "review" }),
        state: "pending",
        remoteId: null,
      },
    ];
    f.deps.rest = vi.fn(async () => [
      { id: 3, body: marker, author: { username: "someone" } },
      { id: 4, notes: [note(55)] },
    ]);
    expect(await resumeReviewPosting(f.deps, 1)).toBe("posted");
    f.close();
  });
  it("paginates and holds when later page fails", async () => {
    const f = fixture();
    f.deps.post = vi.fn(async () => {
      throw new Error("timeout");
    });
    const full = Array.from({ length: 100 }, (_, i) => note(i + 1, "unrelated"));
    f.deps.rest = vi.fn(async (url) => {
      if (url.endsWith("page=1")) return full;
      return [note(101)];
    });
    expect(await resumeReviewPosting(f.deps, 1)).toBe("held");
    f.advance(900101);
    const result = await resumeReviewPosting(f.deps, 1);
    expect(result, f.deps.log.mock.calls.map((c) => c[0]).join("\n")).toBe("posted");
    expect(f.store.reviewPostParts(1)[0]?.remoteId).toBe("101");
    f.close();
  });
  it("continues beyond short pages until it finds the matching marker", async () => {
    const f = fixture();
    f.deps.post = vi.fn(async () => { throw new Error("timeout"); });
    expect(await resumeReviewPosting(f.deps, 1)).toBe("held");
    f.advance(900101);
    f.deps.rest = vi.fn(async (url) => url.endsWith("page=1") ? [note(1, "unrelated")] : [note(2)]);
    expect(await resumeReviewPosting(f.deps, 1)).toBe("posted");
    expect(f.deps.rest).toHaveBeenCalledTimes(2);
    expect(f.store.reviewPostParts(1)[0]?.remoteId).toBe("2");
    f.close();
  });
  it("holds on a later page failure without exposing thrown secrets or retrying", async () => {
    const f = fixture();
    const secret = "https://user:secret@example.test/private-body";
    f.deps.post = vi.fn(async () => { throw new Error(secret); });
    expect(await resumeReviewPosting(f.deps, 1)).toBe("held");
    f.advance(900101);
    f.deps.rest = vi.fn(async (url) => {
      if (url.endsWith("page=1")) return [note(1, "unrelated")];
      throw new Error(secret);
    });
    expect(await resumeReviewPosting(f.deps, 1)).toBe("held");
    const detail = f.store.getAgentReview(1)?.detail ?? "";
    const logs = f.deps.log.mock.calls.map(([message]) => message).join("\n");
    expect(detail + logs).not.toContain(secret);
    expect(detail.length).toBeLessThanOrEqual(500);
    expect(f.deps.post).toHaveBeenCalledTimes(1);
    f.close();
  });
  it("holds when 100 nonempty pages are exhausted", async () => {
    const f = fixture();
    f.deps.post = vi.fn(async () => { throw new Error("timeout"); });
    expect(await resumeReviewPosting(f.deps, 1)).toBe("held");
    f.advance(900101);
    f.deps.rest = vi.fn(async () => [note(1, "unrelated")]);
    expect(await resumeReviewPosting(f.deps, 1)).toBe("held");
    expect(f.deps.rest).toHaveBeenCalledTimes(100);
    expect(f.deps.post).toHaveBeenCalledTimes(1);
    f.close();
  });

});
