import { describe, expect, it } from "vitest";
import {
  countFindings,
  countOpenPreviousItems,
  diffLines,
  extractFindings,
  isCleanReview,
  isReadyToApprove,
  placeFinding,
  summaryWithout,
} from "../src/inline-review.ts";

const REVIEW = [
  "# Code review: g/p!7",
  "## Summary — fit to merge after #1.",
  "## Done well",
  "- `src/a.ts:3` — clear names.",
  "## Findings",
  "### Major",
  "1. `src/a.ts:12` — the timeout is missing. Case: a slow host.",
  "   Fix: pass `timeoutMs`.",
  "",
  "   ```ts",
  "   # not a heading",
  "   ```",
  "2. `repo/src/b.ts:4-9`: an unhandled error.",
  "### Minor",
  "3. A finding without a location.",
  "4. `src/gone.ts:1` — a file outside the diff.",
  "",
  "Not part of finding 4.",
  "## Candidates for a rule",
  "- `src/a.ts:12` — not a finding.",
].join("\n");

const NESTED_PREVIOUS = [
  "## Findings",
  "### Previous review",
  "1. `a.ts:3` old — not fixed",
  "#### Evidence",
  "- `a.ts:5` still there",
  "### Minor",
  "1. `b.ts:4` new",
  "### Previous findings",
  "- `c.ts:1` old too",
  "## Notes",
  "1. `d.ts:2` not a finding",
].join("\n");

const TOP_LEVEL_PREVIOUS = [
  "## Previous review",
  "### Findings",
  "1. `a.ts:3` old — fixed",
  "#### Major findings",
  "- `c.ts:1` old too",
  "## Findings",
  "### Minor",
  "1. `b.ts:4` new",
].join("\n");

describe("extractFindings", () => {
  it("extractFindings gives each finding its severity subheading", () => {
    const body = [
      "## Findings",
      "1. `z.ts:1` — before any subheading",
      "### Blocker",
      "1. `a.ts:4` — a",
      "",
      "**Minor**",
      "",
      "- `b.ts:9` — b",
    ].join("\n");
    expect(extractFindings(body).map((f) => f.severity)).toEqual(["", "Blocker", "Minor"]);
  });

  it("takes the located items under Findings and its subheadings, with their continuation", () => {
    const findings = extractFindings(REVIEW);
    expect(findings.map(({ number, path, line }) => ({ number, path, line }))).toEqual([
      { number: "1", path: "src/a.ts", line: 12 },
      { number: "2", path: "repo/src/b.ts", line: 4 },
      { number: "4", path: "src/gone.ts", line: 1 },
    ]);
    expect(findings[0]?.text).toBe(
      "the timeout is missing. Case: a slow host.\nFix: pass `timeoutMs`.\n\n```ts\n# not a heading\n```",
    );
    expect(findings[1]?.text).toBe("an unhandled error.");
    expect(findings[2]?.text).toBe("a file outside the diff.");
  });

  it("numbers bullets by their position and finds nothing without a Findings heading", () => {
    expect(extractFindings("## Findings\n- `a.ts:1` x\n- `b.ts:2` y").map((f) => f.number)).toEqual(
      ["1", "2"],
    );
    expect(extractFindings("## Notes\n1. `a.ts:1` — x")).toEqual([]);
  });
  it("never extracts an item under a Previous findings heading as a finding", () => {
    const body = "## Findings\n### Major\n1. `b.ts:4` new\n## Previous findings\n1. `a.ts:3` old\n";
    expect(extractFindings(body).map((f) => f.path)).toEqual(["b.ts"]);
  });
  it("never extracts an item under a Previous subheading inside Findings, up to its next sibling", () => {
    expect(extractFindings(NESTED_PREVIOUS).map((f) => f.path)).toEqual(["b.ts"]);
  });
  it("never extracts an item under a Findings subheading of a Previous heading", () => {
    expect(extractFindings(TOP_LEVEL_PREVIOUS).map((f) => f.path)).toEqual(["b.ts"]);
  });
});

describe("countFindings", () => {
  it("counts every top-level item per severity subheading, located or not, in severity order", () => {
    expect(countFindings(REVIEW)).toEqual([
      { severity: "Major", count: 2 },
      { severity: "Minor", count: 2 },
    ]);
  });

  it("skips nested bullets, code, none-items and anything outside Findings", () => {
    const review = [
      "## Findings — Blocker / Major / Minor / Nit",
      "### Nit",
      "1. `a.ts` — no line, still a finding.",
      "   - Case: a nested bullet.",
      "   - Fix: another one.",
      "### Blocker",
      "None.",
      "### MAJOR (1)",
      "- `b.ts:2` — x",
      "  ```",
      "  - not an item",
      "  ```",
      "### Minor",
      "- None",
      "## Done well",
      "- `c.ts:1` — good.",
    ].join("\n");
    expect(countFindings(review)).toEqual([
      { severity: "Major", count: 1 },
      { severity: "Nit", count: 1 },
    ]);
  });

  it("puts findings without a severity subheading under an empty severity, after the rest", () => {
    expect(countFindings("## Findings\n1. `a.ts:1` x\n### Critical\n1. y")).toEqual([
      { severity: "Critical", count: 1 },
      { severity: "", count: 1 },
    ]);
    expect(countFindings("## Findings\nNone.\n## Done well\n- z")).toEqual([]);
  });

  it("leaves out a subsection that is not a severity, such as notes outside the diff", () => {
    const review = [
      "## Findings",
      "### Major (1)",
      "1. `a.ts:1` — x",
      "### Outside this diff",
      "- `b.ts:2` — an older problem.",
      "### Minor — 1",
      "2. `c.ts:3` — y",
    ].join("\n");
    expect(countFindings(review)).toEqual([
      { severity: "Major", count: 1 },
      { severity: "Minor", count: 1 },
    ]);
  });
  it("reads a line that is only a bold severity, as some agents write it, like a subheading", () => {
    const review = [
      "## Findings",
      "**Major (1)**",
      "1. `a.ts:1` — x",
      "   **not a label**: a finding's own bold text",
      "__Minor__",
      "2. `b.ts:2` — y",
      "**Outside this diff**",
      "- `c.ts:3` — an older problem.",
      "## Done well",
      "**Nit**",
      "- `d.ts:4` — good.",
    ].join("\n");
    expect(countFindings(review)).toEqual([
      { severity: "Major", count: 1 },
      { severity: "Minor", count: 1 },
    ]);
    expect(isReadyToApprove("## Findings\n**Minor**\n1. `a.ts:1` x\n**Nit**\n2. y")).toBe(true);
  });

  it("ignores items under a Previous findings heading when counting", () => {
    const body =
      "## Previous findings\n1. `a.ts:3` old — not fixed\n## Findings\n### Minor\n1. `b.ts:4` new\n";
    expect(countFindings(body)).toEqual([{ severity: "Minor", count: 1 }]);
    expect(countFindings(NESTED_PREVIOUS)).toEqual([{ severity: "Minor", count: 1 }]);
    expect(countFindings(TOP_LEVEL_PREVIOUS)).toEqual([{ severity: "Minor", count: 1 }]);
  });
});

describe("countOpenPreviousItems and isCleanReview", () => {
  const rereview = (previous: readonly string[], findings: readonly string[] = ["None."]) =>
    [
      "# Re-review",
      "## Previous review",
      ...previous,
      "## Findings",
      ...findings,
      "## Done well",
      "- ok",
    ].join("\n");

  it("counts the previous items that are not marked fixed, at the top level only", () => {
    const body = rereview([
      "1. Major `a.ts:1` the timeout — fixed: `timeoutMs` is passed now.",
      "   - evidence bullet, not fixed, ignored",
      "2. Minor `b.ts:2` the name — not fixed, still `x`.",
      "3. Minor `c.ts:3` the loop — partly fixed; one branch remains.",
      "4. Nit `d.ts:4` the comment — partially fixed.",
      "5. Nit `e.ts:5` the test — unfixed.",
      "6. Nit `f.ts:6` the doc — still open, no status word.",
      "```",
      "7. not fixed inside a fence",
      "```",
    ]);
    expect(countOpenPreviousItems(body)).toBe(5);
    expect(isCleanReview(body)).toBe(false);
  });

  it("is clean with every previous item fixed and no findings, also when the section says none", () => {
    const fixed = rereview([
      "- Major `a.ts:1` — fixed, the guard is there.",
      "- Minor `b.ts:2` — Fixed.",
    ]);
    expect(countOpenPreviousItems(fixed)).toBe(0);
    expect(isCleanReview(fixed)).toBe(true);
    expect(isCleanReview(rereview(["None."]))).toBe(true);
    expect(isCleanReview(rereview(["Tidak ada."], ["None."]))).toBe(true);
    expect(isCleanReview("# Review\n## Findings\nNone.")).toBe(true);
  });

  it("is not clean with a new finding, whatever the previous section says", () => {
    const body = rereview(
      ["- Major `a.ts:1` — fixed."],
      ["### Minor", "1. `z.ts:9` — new problem."],
    );
    expect(countOpenPreviousItems(body)).toBe(0);
    expect(isCleanReview(body)).toBe(false);
  });

  it("stops the previous section at the next sibling heading and ignores items outside it", () => {
    const body = [
      "## Previous review",
      "### Checked",
      "- `a.ts:1` — not fixed.",
      "## Findings",
      "None.",
      "## Notes",
      "- not fixed elsewhere, not a previous item",
    ].join("\n");
    expect(countOpenPreviousItems(body)).toBe(1);
    expect(countOpenPreviousItems("## Findings\n1. `a.ts:1` x")).toBe(0);
  });
});

describe("isReadyToApprove", () => {
  const body = (previous: readonly string[], findings: readonly string[]) =>
    ["# Review", "## Previous review", ...previous, "## Findings", ...findings].join("\n");

  it("is true with no findings, or with only Minor and Nit findings left", () => {
    expect(isReadyToApprove("## Findings\nNone.")).toBe(true);
    expect(isReadyToApprove(body([], ["### Minor", "1. `a.ts:1` x", "### Nit", "2. y"]))).toBe(
      true,
    );
  });

  it("is false with a Blocker, Major or other finding, or one without a severity", () => {
    expect(isReadyToApprove(body([], ["### Major", "1. `a.ts:1` x", "### Minor", "2. y"]))).toBe(
      false,
    );
    expect(isReadyToApprove(body([], ["### Blocker", "1. x"]))).toBe(false);
    expect(isReadyToApprove(body([], ["### Critical", "1. x"]))).toBe(false);
    expect(isReadyToApprove(body([], ["1. `a.ts:1` no severity"]))).toBe(false);
  });

  it("counts open previous items: a Minor or Nit one is fine, a Major or unlabelled one is not", () => {
    const minorOpen = ["- Minor `a.ts:1` the name — not fixed.", "- Nit `b.ts:2` — partly fixed."];
    expect(isReadyToApprove(body(minorOpen, ["None."]))).toBe(true);
    expect(isReadyToApprove(body(["- Major `a.ts:1` the guard — not fixed."], ["None."]))).toBe(
      false,
    );
    expect(isReadyToApprove(body(["- `a.ts:1` the guard — not fixed."], ["None."]))).toBe(false);
    expect(isReadyToApprove(body(["- Major `a.ts:1` the guard — fixed."], ["None."]))).toBe(true);
  });

  it("is stricter with nit (Nit findings only) and clean (nothing left)", () => {
    const nit = body([], ["### Nit", "1. `a.ts:1` spacing"]);
    const minor = body([], ["### Minor", "1. `a.ts:1` naming"]);
    const none = body(["- Major `a.ts:1` the guard — fixed."], ["None."]);
    expect(isReadyToApprove(nit, "nit")).toBe(true);
    expect(isReadyToApprove(minor, "nit")).toBe(false);
    expect(isReadyToApprove(nit, "clean")).toBe(false);
    expect(isReadyToApprove(none, "nit")).toBe(true);
    expect(isReadyToApprove(none, "clean")).toBe(true);
    const nitOpen = body(["- Nit `b.ts:2` — not fixed."], ["None."]);
    expect(isReadyToApprove(nitOpen, "nit")).toBe(true);
    expect(isReadyToApprove(body(["- Minor `a.ts:1` — not fixed."], ["None."]), "nit")).toBe(false);
    expect(isReadyToApprove(nitOpen, "clean")).toBe(false);
  });
});

describe("diffLines", () => {
  it("maps new lines to old ones: null when added, skipping removed lines", () => {
    const diff = [
      "@@ -10,4 +10,5 @@ function f() {",
      " ten",
      "-eleven",
      "+eleven!",
      "+eleven and a half",
      " twelve",
      "\\ No newline at end of file",
      "@@ -40 +41 @@",
      " forty",
    ].join("\n");
    expect([...diffLines(diff)]).toEqual([
      [10, 10],
      [11, null],
      [12, null],
      [13, 12],
      [41, 40],
    ]);
  });
});

describe("placeFinding", () => {
  const refs = { baseSha: "b", startSha: "s", headSha: "h" };
  const files = [
    { oldPath: "src/old-a.ts", newPath: "src/a.ts", diff: "@@ -11,2 +11,2 @@\n ctx\n+added" },
    { oldPath: "src/b.ts", newPath: "src/b.ts", diff: "@@ -1 +1,4 @@\n+1\n+2\n+3\n+4" },
  ];

  it("places an added line by its new number and an unchanged one by both", () => {
    const [first, second] = extractFindings(REVIEW);
    expect(first && placeFinding(first, files, refs)).toEqual({
      position_type: "text",
      base_sha: "b",
      start_sha: "s",
      head_sha: "h",
      old_path: "src/old-a.ts",
      new_path: "src/a.ts",
      new_line: 12,
    });
    expect(second && placeFinding(second, files, refs)).toMatchObject({
      new_path: "src/b.ts",
      new_line: 4,
    });
    const context = extractFindings("## Findings\n1. `src/a.ts:11` — x")[0];
    expect(context && placeFinding(context, files, refs)).toMatchObject({
      new_line: 11,
      old_line: 11,
    });
  });

  it("leaves a finding outside the diff unplaced", () => {
    const findings = extractFindings(`${REVIEW}\n## Findings\n1. \`src/a.ts:99\` — x`);
    expect(findings.map((finding) => placeFinding(finding, files, refs) === undefined)).toEqual([
      false,
      false,
      true,
      true,
    ]);
  });
});

describe("summaryWithout", () => {
  it("cuts each posted finding to a pointer and keeps everything else", () => {
    const [first, , third] = extractFindings(REVIEW);
    const summary = summaryWithout(
      REVIEW,
      [first, third].filter((f) => f !== undefined),
    );
    expect(summary).toContain("1. `src/a.ts:12` — posted as an inline comment on that line.\n2.");
    expect(summary).not.toContain("timeoutMs");
    expect(summary).toContain("2. `repo/src/b.ts:4-9`: an unhandled error.");
    expect(summary).toContain(
      "4. `src/gone.ts:1` — posted as an inline comment on that line.\n\nNot part of finding 4.",
    );
    expect(summary).toContain("- `src/a.ts:3` — clear names.");
  });
});
