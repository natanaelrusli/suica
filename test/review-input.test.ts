import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { assertReviewCoverage, loadReviewInput } from "../src/review-input.ts";
import { RunFailure } from "../src/review-runner.ts";
import type { ReviewInput } from "../src/review-input.ts";
import type { MrDetailJson } from "../src/reviews.ts";

const detail = JSON.parse(
  readFileSync(new URL("../contracts/mr-detail.v1.json", import.meta.url), "utf8"),
) as MrDetailJson;
const head = "a".repeat(40);
const version = (id: number, sha = head) => ({
  id,
  head_commit_sha: sha,
  base_commit_sha: "b".repeat(40),
  start_commit_sha: "b".repeat(40),
});
const diff = { old_path: "src/a.ts", new_path: "src/a.ts", diff: "@@ -0,0 +1 @@\n+x" };
const response = (diffs: unknown[], extra: Record<string, unknown> = {}) => ({
  diffs,
  state: "collected",
  real_size: String(diffs.length),
  overflow: false,
  ...extra,
});
function runner(responses: unknown[]) {
  const calls: string[] = [];
  const rest = async (path: string) => {
    calls.push(path);
    const response = responses.shift();
    if (response === undefined) throw new Error("unexpected REST call");
    return response;
  };
  return { rest, calls };
}
describe("loadReviewInput", () => {
  it("chooses the fetched head version and requests exact paths", async () => {
    const fake = runner([[version(1, "c".repeat(40)), version(7)], response([diff])]);
    const input = await loadReviewInput(fake.rest, { ...detail, headSha: head });
    expect(input.versionId).toBe(7);
    expect(fake.calls).toEqual([
      "projects/g%2Fp/merge_requests/7/versions?per_page=100",
      "projects/g%2Fp/merge_requests/7/versions/7",
    ]);
  });
  it("rejects malformed keys without calling REST", async () => {
    const fake = runner([]);
    await expect(
      loadReviewInput(fake.rest, { ...detail, key: "bad", headSha: head }),
    ).rejects.toBeInstanceOf(RunFailure);
    expect(fake.calls).toEqual([]);
  });
  it.each([{ versions: [version(1, "c".repeat(40))] }, { versions: [version(1), version(2)] }])(
    "rejects missing or duplicate matching head versions",
    async ({ versions }) => {
      const fake = runner([versions]);
      await expect(loadReviewInput(fake.rest, { ...detail, headSha: head })).rejects.toBeInstanceOf(
        RunFailure,
      );
      expect(fake.calls).toHaveLength(1);
    },
  );
  it.each([{ too_large: true }, { collapsed: true }])(
    "rejects omitted text marked unavailable",
    async (flag) => {
      const fake = runner([
        [version(1)],
        response([{ old_path: "big.lock", new_path: "big.lock", diff: "binary", ...flag }]),
      ]);
      const input = await loadReviewInput(fake.rest, { ...detail, headSha: head });
      expect(input.files[0]?.diff).toBe("binary");
      expect(() => assertReviewCoverage(input)).toThrow(RunFailure);
    },
  );
  it.each([{ too_large: true }, { collapsed: true }])(
    "refuses nonempty diffs marked unsupported",
    async (flag) => {
      const input = await loadReviewInput(
        runner([[version(1)], response([{ ...diff, ...flag }])]).rest,
        { ...detail, headSha: head },
      );
      expect(() => assertReviewCoverage(input)).toThrow(/GitLab marks this file/);
    },
  );
  it.each([
    { diffs: [diff] },
    { diffs: [diff], state: "collected" },
    response([diff], { real_size: "2" }),
  ])("rejects incomplete or mismatched version metadata", async (payload) => {
    const input = await loadReviewInput(runner([[version(1)], payload]).rest, {
      ...detail,
      headSha: head,
    });
    expect(input.detail.filesTruncated).toBe(true);
    expect(() => assertReviewCoverage(input)).toThrow(RunFailure);
  });
  it("accepts complete coverage with more than 100 files", async () => {
    const many = Array.from({ length: 101 }, (_, i) => ({
      ...diff,
      old_path: `${i}.ts`,
      new_path: `${i}.ts`,
    }));
    const input = await loadReviewInput(runner([[version(1)], response(many)]).rest, {
      ...detail,
      headSha: head,
    });
    expect(input.detail.filesTruncated).toBe(false);
    expect(() => assertReviewCoverage(input)).not.toThrow();
  });
  it("explains why an empty diff cannot be reviewed", async () => {
    const input = await loadReviewInput(
      runner([[version(1)], response([{ ...diff, diff: "" }])]).rest,
      { ...detail, headSha: head },
    );
    expect(() => assertReviewCoverage(input)).toThrow(/binary-only changes/);
  });
  it("rejects overflow coverage", async () => {
    const fake = runner([[version(1)], response([diff], { overflow: true })]);
    const input = await loadReviewInput(fake.rest, { ...detail, headSha: head });
    expect(input.detail.filesTruncated).toBe(true);
    expect(() => assertReviewCoverage(input)).toThrow(RunFailure);
  });
  it("preserves GitLab file flags", async () => {
    const fake = runner([
      [version(1)],
      response([
        { ...diff, new_file: true },
        { ...diff, old_path: "old.ts", new_path: "new.ts", renamed_file: true },
        { ...diff, old_path: "gone.ts", new_path: "gone.ts", deleted_file: true },
      ]),
    ]);
    const input = await loadReviewInput(fake.rest, { ...detail, headSha: head });
    expect(
      input.detail.files.map(({ newFile, renamedFile, deletedFile }) => ({
        newFile,
        renamedFile,
        deletedFile,
      })),
    ).toEqual([
      { newFile: true, renamedFile: false, deletedFile: false },
      { newFile: false, renamedFile: true, deletedFile: false },
      { newFile: false, renamedFile: false, deletedFile: true },
    ]);
  });
});
describe("assertReviewCoverage", () => {
  const input = {
    detail: {
      ...detail,
      additions: 1,
      deletions: 0,
      files: [
        {
          oldPath: "a",
          newPath: "a",
          newFile: false,
          renamedFile: false,
          deletedFile: false,
          diff: "@@ -0,0 +1 @@\n+x",
        },
      ],
      filesTruncated: false,
    },
    headSha: head,
    baseSha: "b".repeat(40),
    startSha: "b".repeat(40),
    versionId: 1,
    files: [
      {
        oldPath: "a",
        newPath: "a",
        newFile: false,
        renamedFile: false,
        deletedFile: false,
        diff: "@@ -0,0 +1 @@\n+x",
      },
    ],
  } satisfies ReviewInput;
  it("accepts complete textual diff input", () =>
    expect(() => assertReviewCoverage(input)).not.toThrow());
  it("rejects truncated file coverage", () =>
    expect(() =>
      assertReviewCoverage({ ...input, detail: { ...input.detail, filesTruncated: true } }),
    ).toThrow(RunFailure));
  it("rejects omitted diff text", () =>
    expect(() =>
      assertReviewCoverage({
        ...input,
        files: [{ ...input.files[0]!, diff: null }],
      }),
    ).toThrow(RunFailure));
  it("requires aggregate line counts", () =>
    expect(() =>
      assertReviewCoverage({ ...input, detail: { ...input.detail, additions: null } }),
    ).toThrow(RunFailure));
});
