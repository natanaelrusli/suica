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
});
const MAX_FILE_DIFF_CHARS = 200_000;
const MAX_TOTAL_DIFF_CHARS = 1_500_000;
export interface ReviewInput {
  readonly detail: MrDetailJson;
  readonly headSha: string;
  readonly baseSha: string;
  readonly startSha: string;
  readonly versionId: number;
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
  const version = matching[0]!;
  const raw = versionSchema.parse(await rest(`${mrPath}/versions/${version.id}`));
  const files = raw.diffs.map((file) => ({
    oldPath: file.old_path,
    newPath: file.new_path,
    newFile: file.new_file ?? false,
    renamedFile: file.renamed_file ?? file.old_path !== file.new_path,
    deletedFile: file.deleted_file ?? false,
    diff: file.diff ?? null,
  }));
  return {
    detail: { ...detail, files, filesTruncated: raw.overflow === true },
    headSha: version.head_commit_sha,
    baseSha: version.base_commit_sha,
    startSha: version.start_commit_sha,
    versionId: version.id,
  };
}
export function assertReviewCoverage(input: ReviewInput): void {
  const files = input.detail.files;
  if (!files.length || input.detail.filesTruncated)
    throw new RunFailure("diff version coverage is incomplete");
  let total = 0;
  for (const file of files) {
    if (file.diff === null) throw new RunFailure(`diff text unavailable for ${file.newPath}`);
    if (
      file.diff.length > MAX_FILE_DIFF_CHARS ||
      (total += file.diff.length) > MAX_TOTAL_DIFF_CHARS
    )
      throw new RunFailure("diff exceeds review text coverage limits");
    if (!file.diff.length) throw new RunFailure(`diff coverage unsupported for ${file.newPath}`);
  }
  if (input.detail.additions === null || input.detail.deletions === null)
    throw new RunFailure("aggregate line counts unavailable to verify diff coverage");
}
