import { describe, expect, it } from "vitest";
import { isReadyToApprove } from "../src/inline-review.ts";
import { SUICA_REVIEW_LAYER } from "../src/review-template.ts";

const review = (findings: string, verdict: string): string =>
  `## Scope\nCode reading only.\n\n## Findings\n${findings}\n\n## Verdict\nReady to approve: ${verdict}\n`;

describe("Suica review layer", () => {
  it("names the headings the parser reads", () => {
    expect(SUICA_REVIEW_LAYER).toContain("### Blocker");
    expect(SUICA_REVIEW_LAYER).toContain("Ready to approve:");
  });

  it("is ready with no findings or only Nit/Minor, not with a Major", () => {
    expect(isReadyToApprove(review("None.", "yes"))).toBe(true);
    expect(isReadyToApprove(review("### Minor\n1. `a.ts:3` — x", "yes"))).toBe(true);
    expect(isReadyToApprove(review("### Major\n1. `a.ts:3` — x", "yes"))).toBe(false);
  });

  it("is never ready when its own verdict says no", () => {
    expect(isReadyToApprove(review("None.", "no"))).toBe(false);
  });
});
