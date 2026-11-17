import { z } from "zod";
import { parseMrKey } from "./reviews.ts";
import type { MrDetailJson } from "./reviews.ts";
import type { RestRunner } from "./gitlab.ts";
import { RunFailure } from "./review-runner.ts";

export const versionsSchema = z.array(
  z.object({
    id: z.number(),
    head_commit_sha: z.string(),
    base_commit_sha: z.string(),
    start_commit_sha: z.string(),
  }),
);
export const versionSchema = z.object({
  diffs: z.array(
    z.object({
      old_path: z.string(),
      new_path: z.string(),
      diff: z.string().optional(),
      new_file: z.boolean().optional(),
      renamed_file: z.boolean().optional(),
      deleted_file: z.boolean().optional(),
      too_large: z.boolean().optional(),
      collapsed: z.boolean().optional(),
    }),
  ),
  overflow: z.boolean().optional(),
  state: z.string().optional(),
  real_size: z.string().optional(),
});
const MAX_FILE_DIFF_CHARS = 200_000;
const MAX_TOTAL_DIFF_CHARS = 1_500_000;
type ReviewFile = MrDetailJson["files"][number] & {
  readonly coverage: "text" | "unsupported-empty-or-binary" | "unavailable" | "truncated";
};

export interface ReviewInput {
  readonly detail: MrDetailJson;
  readonly headSha: string;
  readonly baseSha: string;
  readonly startSha: string;
  readonly versionId: number;
  readonly files: readonly ReviewFile[];
}

export async function loadReviewInput(
  rest: RestRunner,
  detail: MrDetailJson,
): Promise<ReviewInput> {
  if (!detail.headSha) throw new RunFailure("missing merge request head SHA");
  const key = parseMrKey(detail.key);
  if (!key) throw new RunFailure("invalid merge request key");
  const mrPath = `projects/${encodeURIComponent(key.projectPath)}/merge_requests/${key.iid}`;
  const versions = versionsSchema.parse(await rest(`${mrPath}/versions?per_page=100`));
  const matching = versions.filter((version) => version.head_commit_sha === detail.headSha);
  if (matching.length !== 1)
    throw new RunFailure("immutable diff version for fetched head is missing or ambiguous");
  const version = matching[0];
  if (version === undefined)
    throw new RunFailure("immutable diff version for fetched head is missing");
  const raw = versionSchema.parse(await rest(`${mrPath}/versions/${version.id}`));
  // GitLab sends `diff: ""` for both an empty new/deleted file and a binary one; the blob size tells them apart.
  const isEmptyBlob = async (file: (typeof raw.diffs)[number]): Promise<boolean> => {
    if (file.diff !== "" || (!file.new_file && !file.deleted_file)) return false;
    const [path, ref] = file.deleted_file
      ? [file.old_path, version.base_commit_sha]
      : [file.new_path, version.head_commit_sha];
    try {
      const meta = z
        .object({ size: z.number() })
        .parse(
          await rest(
            `projects/${encodeURIComponent(key.projectPath)}/repository/files/${encodeURIComponent(path)}?ref=${ref}`,
          ),
        );
      return meta.size === 0;
    } catch {
      return false;
    }
  };
  const emptyBlobs = await Promise.all(raw.diffs.map(isEmptyBlob));
  const files: ReviewFile[] = raw.diffs.map((file, i) => ({
    oldPath: file.old_path,
    newPath: file.new_path,
    newFile: file.new_file ?? false,
    renamedFile: file.renamed_file ?? file.old_path !== file.new_path,
    deletedFile: file.deleted_file ?? false,
    diff: file.diff ?? null,
    coverage:
      file.too_large || file.collapsed
        ? "truncated"
        : file.diff === undefined
          ? "unavailable"
          : file.diff.length === 0 && !emptyBlobs[i]
            ? "unsupported-empty-or-binary"
            : "text",
  }));
  return {
    detail: {
      ...detail,
      files: files.map((file) => ({
        oldPath: file.oldPath,
        newPath: file.newPath,
        newFile: file.newFile,
        renamedFile: file.renamedFile,
        deletedFile: file.deletedFile,
        diff: file.diff,
      })),
      filesTruncated:
        raw.overflow === true ||
        raw.state !== "collected" ||
        raw.real_size === undefined ||
        !/^\d+$/.test(raw.real_size) ||
        Number(raw.real_size) !== raw.diffs.length,
    },
    files,
    headSha: version.head_commit_sha,
    baseSha: version.base_commit_sha,
    startSha: version.start_commit_sha,
    versionId: version.id,
  };
}
export function assertReviewCoverage(input: ReviewInput): void {
  const files = input.files;
  if (!files.length || input.detail.filesTruncated)
    throw new RunFailure("diff version coverage is incomplete");
  let total = 0;
  for (const file of files) {
    if (file.coverage === "unsupported-empty-or-binary")
      throw new RunFailure(
        `empty diff unsupported for ${file.newPath}; GitLab's version diff response cannot distinguish binary-only changes from missing textual diff`,
      );
    if (file.coverage === "unavailable")
      throw new RunFailure(`diff text unavailable for ${file.newPath}`);
    if (file.coverage === "truncated")
      throw new RunFailure(`GitLab marks this file too_large or collapsed: ${file.newPath}`);
    if (file.diff === null) throw new RunFailure(`diff text unavailable for ${file.newPath}`);
    if (
      file.diff.length > MAX_FILE_DIFF_CHARS ||
      (total += file.diff.length) > MAX_TOTAL_DIFF_CHARS
    )
      throw new RunFailure("diff exceeds review text coverage limits");
  }
  if (input.detail.additions === null || input.detail.deletions === null)
    throw new RunFailure("aggregate line counts unavailable to verify diff coverage");
}
