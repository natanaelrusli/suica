import { describe, expect, it } from "vitest";
import { diffLines, extractFindings, placeFinding, summaryWithout } from "../src/inline-review.ts";

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

describe("extractFindings", () => {
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
