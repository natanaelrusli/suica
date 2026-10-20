import { z } from "zod";
import { UNREVIEWED } from "./domain.ts";
import type { MergeRequest, Person, Reviewer, Snapshot } from "./domain.ts";
import { FetchFailure } from "./gitlab.ts";
import type { GraphqlRunner, PostRunner, RestRunner } from "./gitlab.ts";
import { isReadyToApprove } from "./inline-review.ts";
import type { Logger } from "./log.ts";
import type { AgentReviewRow, AgentReviewStatus } from "./store.ts";

/** The newest Agent Review of an MR. */
export interface AgentReviewJson {
  readonly id: number;
  readonly status: AgentReviewStatus;
  /** claude or codex; null until the run starts. */
  readonly cli: string | null;
  /** As the CLI reported it, else `review.model`; null until known. */
  readonly model: string | null;
  /** Epoch milliseconds; null while queued. */
  readonly startedAt: number | null;
  readonly headSha: string | null;
  /** The commit the previous Agent Review covered; set only for an Agent Re-review. */
  readonly previousSha: string | null;
  /** Markdown as the model wrote it; GitLab gets a sanitised copy with an agent label. */
  readonly body: string | null;
  readonly detail: string;
  /** Epoch milliseconds. */
  readonly createdAt: number;
  readonly updatedAt: number;
}

/** What the agent is reviewing now and what waits; in `suica status --json` and `suica state`. */
export interface ReviewActivityJson {
  readonly running: {
    readonly id: number;
    readonly mrKey: string;
    /** Null until the run has read the MR. */
    readonly mrTitle: string | null;
    readonly cli: string | null;
    /** `review.model` until the CLI reports the model it used; null for the CLI's default. */
    readonly model: string | null;
    /** Epoch milliseconds. */
    readonly startedAt: number | null;
  } | null;
  /** In the order they run. */
  readonly queued: readonly {
    readonly id: number;
    readonly mrKey: string;
    readonly mrTitle: string | null;
  }[];
}

export function buildReviewActivity(
  activity: { running: AgentReviewRow | undefined; queued: readonly AgentReviewRow[] },
  configuredModel: string | undefined,
): ReviewActivityJson {
  const { running } = activity;
  return {
    running:
      running === undefined
        ? null
        : {
            id: running.id,
            mrKey: running.mrKey,
            mrTitle: running.mrTitle,
            cli: running.cli,
            model: running.model ?? configuredModel ?? null,
            startedAt: running.startedAt,
          },
    queued: activity.queued.map((row) => ({ id: row.id, mrKey: row.mrKey, mrTitle: row.mrTitle })),
  };
}

/** How an MR changed since the agent's posted review, for the list's badge and Re-review button. */
export interface ChangedSinceReviewJson {
  readonly code: boolean;
  readonly description: boolean;
}

/** One open MR where the Owner is a Reviewer. See contracts/reviews.v1.json. */
export interface ReviewSummaryJson {
  readonly key: string;
  readonly title: string;
  readonly url: string;
  readonly draft: boolean;
  /** ISO 8601, when the MR was opened; null when GitLab did not say. */
  readonly createdAt: string | null;
  readonly author: Person;
  readonly reviewers: readonly Reviewer[];
  /** Null when the agent never reviewed it. */
  readonly agentReview: AgentReviewJson | null;
  /**
   * Set when the newest posted-or-discarded Agent Review was posted, the MR's head or description
   * differs from what it read, and no review is open (queued, running, ready or posting). A base
   * without a description hash (reviewed before the hash was kept) compares the head only. Null
   * once you approved the MR.
   */
  readonly changedSinceReview: ChangedSinceReviewJson | null;
  /**
   * True when the newest posted Agent Review has only Minor or Nit problems left, the MR has not
   * changed since, no newer review is open, and neither the Owner nor the agent approved it yet.
   */
  readonly readyToApprove: boolean;
}

/** `suica reviews --json`. */
export interface ReviewListJson {
  readonly version: 1;
  /** The Owner, so the app can find the Owner among each MR's reviewers. */
  readonly me: Person;
  readonly mergeRequests: readonly ReviewSummaryJson[];
}

function toAgentReviewJson(row: AgentReviewRow): AgentReviewJson {
  return {
    id: row.id,
    status: row.status,
    cli: row.cli,
    model: row.model,
    startedAt: row.startedAt,
    headSha: row.headSha,
    previousSha: row.previousSha,
    body: row.body,
    detail: row.detail,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  };
}

const OPEN_STATUSES: readonly AgentReviewStatus[] = ["queued", "running", "ready", "posting"];

/** Pure: see `ReviewSummaryJson.changedSinceReview`. */
export function changedSinceReview(
  mr: Pick<MergeRequest, "headSha" | "descriptionSha">,
  latest: AgentReviewRow | undefined,
  base: AgentReviewRow | undefined,
): ChangedSinceReviewJson | null {
  if (base?.status !== "posted" || base.headSha === null || mr.headSha === null) return null;
  if (latest !== undefined && OPEN_STATUSES.includes(latest.status)) return null;
  const code = base.headSha !== mr.headSha;
  const description =
    base.descriptionSha !== null &&
    mr.descriptionSha !== null &&
    base.descriptionSha !== mr.descriptionSha;
  return code || description ? { code, description } : null;
}

/** Pure: see `ReviewSummaryJson.readyToApprove`. */
export function readyToApprove(
  mr: Pick<MergeRequest, "headSha" | "descriptionSha" | "reviewers">,
  me: Person,
  latest: AgentReviewRow | undefined,
  base: AgentReviewRow | undefined,
): boolean {
  if (base?.status !== "posted" || base.body === null || base.approved) return false;
  if (latest !== undefined && OPEN_STATUSES.includes(latest.status)) return false;
  if (base.headSha !== mr.headSha || changedSinceReview(mr, latest, base) !== null) return false;
  const mine = mr.reviewers.find((each) => each.username === me.username);
  return mine?.state !== "APPROVED" && isReadyToApprove(base.body);
}

export function buildReviewList(
  snapshot: Snapshot,
  agentReviews: ReadonlyMap<string, AgentReviewRow> = new Map(),
  bases: ReadonlyMap<string, AgentReviewRow> = new Map(),
): ReviewListJson {
  return {
    version: 1,
    me: snapshot.me,
    mergeRequests: snapshot.reviewRequested.map((mr) => {
      const latest = agentReviews.get(mr.key);
      const approvedByMe = mr.reviewers.some(
        (each) => each.username === snapshot.me.username && each.state === "APPROVED",
      );
      return {
        key: mr.key,
        title: mr.title,
        url: mr.url,
        draft: mr.draft,
        createdAt: mr.createdAt,
        author: mr.author,
        reviewers: mr.reviewers,
        agentReview: latest === undefined ? null : toAgentReviewJson(latest),
        // Once you approved, a change is yours to look at; the list stops offering a re-review.
        changedSinceReview: approvedByMe ? null : changedSinceReview(mr, latest, bases.get(mr.key)),
        readyToApprove: readyToApprove(mr, snapshot.me, latest, bases.get(mr.key)),
      };
    }),
  };
}

export interface NoteJson {
  readonly id: string;
  readonly body: string;
  readonly system: boolean;
  /** ISO 8601, as GitLab sends it. */
  readonly createdAt: string;
  readonly author: Person;
  /** Set for a comment on a line of the diff. */
  readonly filePath: string | null;
  readonly line: number | null;
}

export interface DiscussionJson {
  readonly id: string;
  readonly resolvable: boolean;
  readonly resolved: boolean;
  readonly notes: readonly NoteJson[];
}

export interface DiffFileJson {
  readonly oldPath: string;
  readonly newPath: string;
  readonly newFile: boolean;
  readonly renamedFile: boolean;
  readonly deletedFile: boolean;
  /** Unified diff hunks; null when GitLab or this command left it out because it is too large. */
  readonly diff: string | null;
}

/** `suica mr <key> --json`. See contracts/mr-detail.v1.json. */
export interface MrDetailJson {
  readonly version: 1;
  readonly key: string;
  readonly title: string;
  readonly description: string;
  readonly url: string;
  readonly draft: boolean;
  readonly sourceBranch: string;
  readonly targetBranch: string;
  readonly createdAt: string;
  readonly updatedAt: string;
  readonly author: Person;
  readonly labels: readonly string[];
  /** GitLab's pipeline status (SUCCESS, FAILED, RUNNING, …); null without a pipeline. */
  readonly pipelineStatus: string | null;
  readonly additions: number | null;
  readonly deletions: number | null;
  readonly reviewers: readonly Reviewer[];
  readonly approvedBy: readonly Person[];
  /** True when merging squashes the commits, with the project's squash setting applied. */
  readonly squashOnMerge: boolean;
  /** The commit the diff was taken at; an approval is tied to it. Null when GitLab has none. */
  readonly headSha: string | null;
  /** True when GitLab lets the Owner approve this MR now. */
  readonly canApprove: boolean;
  readonly discussions: readonly DiscussionJson[];
  /** True when the MR has more discussions than were fetched. */
  readonly discussionsTruncated: boolean;
  readonly files: readonly DiffFileJson[];
  /** True when the MR has more changed files than were fetched. */
  readonly filesTruncated: boolean;
}

/** Segments start with a letter, digit or underscore, so none is `..` or looks like a flag. */
const KEY_PATTERN = /^(\w[\w.-]*(?:\/\w[\w.-]*)+)!(\d+)$/;

/** Splits `<project path>!<iid>`; undefined for anything else, so input never shapes a request. */
export function parseMrKey(key: string): { projectPath: string; iid: string } | undefined {
  const match = KEY_PATTERN.exec(key);
  if (match?.[1] === undefined || match[2] === undefined) return undefined;
  return { projectPath: match[1], iid: match[2] };
}

const DISCUSSIONS_PAGE = 100;
const FILES_PAGE = 100;
/** The app reads at most 4 MiB of output; diff text past these budgets is left out. */
const MAX_FILE_DIFF_CHARS = 200_000;
const MAX_TOTAL_DIFF_CHARS = 1_500_000;

export const MR_DETAIL_QUERY = `
query SuicaMergeRequest($path: ID!, $iid: String!) {
  project(fullPath: $path) {
    mergeRequest(iid: $iid) {
      title
      description
      webUrl
      draft
      sourceBranch
      targetBranch
      createdAt
      updatedAt
      author { username name }
      labels { nodes { title } }
      headPipeline { status }
      diffStatsSummary { additions deletions }
      reviewers { nodes { username name mergeRequestInteraction { reviewState } } }
      approvedBy { nodes { username name } }
      squashOnMerge
      diffHeadSha
      userPermissions { canApprove }
      discussions(first: ${DISCUSSIONS_PAGE}) {
        pageInfo { hasNextPage }
        nodes {
          id
          resolvable
          resolved
          notes {
            nodes {
              id
              body
              system
              createdAt
              author { username name }
              position { filePath newLine oldLine }
            }
          }
        }
      }
    }
  }
}
`;

const GHOST: Person = { username: "ghost", name: "(unknown user)" };

const personSchema = z.object({ username: z.string(), name: z.string() });
const noteSchema = z.object({
  id: z.string(),
  body: z.string(),
  system: z.boolean(),
  createdAt: z.string(),
  author: personSchema.nullable(),
  position: z
    .object({
      filePath: z.string(),
      newLine: z.number().int().nullable(),
      oldLine: z.number().int().nullable(),
    })
    .nullable()
    .optional(),
});
const detailSchema = z.object({
  data: z
    .object({
      project: z
        .object({
          mergeRequest: z
            .object({
              title: z.string(),
              description: z.string().nullable(),
              webUrl: z.string().refine((url) => /^https?:\/\//.test(url)),
              draft: z.boolean(),
              sourceBranch: z.string(),
              targetBranch: z.string(),
              createdAt: z.string(),
              updatedAt: z.string(),
              author: personSchema.nullable(),
              labels: z.object({ nodes: z.array(z.object({ title: z.string() })) }),
              headPipeline: z.object({ status: z.string() }).nullable(),
              diffStatsSummary: z
                .object({ additions: z.number().int(), deletions: z.number().int() })
                .nullable(),
              reviewers: z.object({
                nodes: z.array(
                  personSchema.extend({
                    mergeRequestInteraction: z
                      .object({ reviewState: z.string().nullable() })
                      .nullable(),
                  }),
                ),
              }),
              approvedBy: z.object({ nodes: z.array(personSchema) }),
              squashOnMerge: z.boolean(),
              diffHeadSha: z.string().nullable(),
              userPermissions: z.object({ canApprove: z.boolean() }),
              discussions: z.object({
                pageInfo: z.object({ hasNextPage: z.boolean() }),
                nodes: z.array(
                  z.object({
                    id: z.string(),
                    resolvable: z.boolean(),
                    resolved: z.boolean(),
                    notes: z.object({ nodes: z.array(noteSchema) }),
                  }),
                ),
              }),
            })
            .nullable(),
        })
        .nullable(),
    })
    .nullable()
    .optional(),
  errors: z.array(z.object({ message: z.string() })).optional(),
});

const diffSchema = z.array(
  z.object({
    old_path: z.string(),
    new_path: z.string(),
    new_file: z.boolean(),
    renamed_file: z.boolean(),
    deleted_file: z.boolean(),
    diff: z.string(),
    too_large: z.boolean().nullable().optional(),
    collapsed: z.boolean().nullable().optional(),
  }),
);

/** Keeps files in order and leaves out diff text past the per-file and total budgets. */
export function parseDiffs(raw: unknown): { files: DiffFileJson[]; truncated: boolean } {
  const parsed = diffSchema.safeParse(raw);
  if (!parsed.success) throw new FetchFailure("gitlab-error", "unexpected diffs response shape");
  let budget = MAX_TOTAL_DIFF_CHARS;
  const files = parsed.data.map((file) => {
    const fits =
      file.too_large !== true &&
      file.diff.length <= MAX_FILE_DIFF_CHARS &&
      file.diff.length <= budget;
    if (fits) budget -= file.diff.length;
    return {
      oldPath: file.old_path,
      newPath: file.new_path,
      newFile: file.new_file,
      renamedFile: file.renamed_file,
      deletedFile: file.deleted_file,
      diff: fits && file.diff !== "" ? file.diff : null,
    };
  });
  return { files, truncated: parsed.data.length >= FILES_PAGE };
}

export function parseMrDetail(
  key: string,
  raw: unknown,
  diffs: { files: DiffFileJson[]; truncated: boolean },
): MrDetailJson {
  const parsed = detailSchema.safeParse(raw);
  if (!parsed.success) throw new FetchFailure("gitlab-error", "unexpected GraphQL response shape");
  const { data, errors } = parsed.data;
  if (errors !== undefined && errors.length > 0) {
    throw new FetchFailure("gitlab-error", "GraphQL response contained errors");
  }
  const mr = data?.project?.mergeRequest;
  if (mr === null || mr === undefined) {
    throw new FetchFailure("gitlab-error", "merge request not found");
  }
  return {
    version: 1,
    key,
    title: mr.title,
    description: mr.description ?? "",
    url: mr.webUrl,
    draft: mr.draft,
    sourceBranch: mr.sourceBranch,
    targetBranch: mr.targetBranch,
    createdAt: mr.createdAt,
    updatedAt: mr.updatedAt,
    author: mr.author ?? GHOST,
    labels: mr.labels.nodes.map((label) => label.title),
    pipelineStatus: mr.headPipeline?.status ?? null,
    additions: mr.diffStatsSummary?.additions ?? null,
    deletions: mr.diffStatsSummary?.deletions ?? null,
    reviewers: mr.reviewers.nodes.map((reviewer) => ({
      username: reviewer.username,
      name: reviewer.name,
      state: reviewer.mergeRequestInteraction?.reviewState ?? UNREVIEWED,
    })),
    approvedBy: mr.approvedBy.nodes,
    squashOnMerge: mr.squashOnMerge,
    headSha: mr.diffHeadSha,
    canApprove: mr.userPermissions.canApprove,
    discussions: mr.discussions.nodes.map((discussion) => ({
      id: discussion.id,
      resolvable: discussion.resolvable,
      resolved: discussion.resolved,
      notes: discussion.notes.nodes.map((note) => ({
        id: note.id,
        body: note.body,
        system: note.system,
        createdAt: note.createdAt,
        author: note.author ?? GHOST,
        filePath: note.position?.filePath ?? null,
        line: note.position?.newLine ?? note.position?.oldLine ?? null,
      })),
    })),
    discussionsTruncated: mr.discussions.pageInfo.hasNextPage,
    files: diffs.files,
    filesTruncated: diffs.truncated,
  };
}

export async function fetchMrDetail(
  graphql: GraphqlRunner,
  rest: RestRunner,
  key: string,
): Promise<MrDetailJson> {
  const parts = parseMrKey(key);
  if (parts === undefined) throw new FetchFailure("gitlab-error", "malformed merge request key");
  const project = encodeURIComponent(parts.projectPath);
  const [raw, diffs] = await Promise.all([
    graphql(MR_DETAIL_QUERY, { path: parts.projectPath, iid: parts.iid }),
    rest(`projects/${project}/merge_requests/${parts.iid}/diffs?per_page=${FILES_PAGE}`),
  ]);
  return parseMrDetail(key, raw, parseDiffs(diffs));
}

export type ApproveOutcome = "approved" | "head-changed" | "bad-request" | "failed";

const SHA_PATTERN = /^[0-9a-f]{40}$/;
const HTTP_CONFLICT = 409;

/**
 * Approves the MR as the Owner, only at `sha`: GitLab answers 409 when the source branch moved
 * since the Owner loaded it, so a push the Owner has not seen is never approved.
 */
export async function approveMergeRequest(
  deps: { readonly post: PostRunner; readonly log: Logger },
  key: string,
  sha: string,
): Promise<ApproveOutcome> {
  const parts = parseMrKey(key);
  if (parts === undefined || !SHA_PATTERN.test(sha)) return "bad-request";
  try {
    await deps.post(
      `projects/${encodeURIComponent(parts.projectPath)}/merge_requests/${parts.iid}/approve`,
      { sha },
    );
  } catch (error) {
    if (!(error instanceof FetchFailure)) throw error;
    if (error.httpStatus === HTTP_CONFLICT) return "head-changed";
    deps.log.warn("approve failed", { kind: error.kind, httpStatus: error.httpStatus ?? null });
    return "failed";
  }
  return "approved";
}

/** Discussions the Owner started on one MR, a page at a time. */
const OWN_THREADS_QUERY = `
query SuicaOwnThreads($path: ID!, $iid: String!, $after: String) {
  currentUser { username }
  project(fullPath: $path) {
    mergeRequest(iid: $iid) {
      discussions(first: ${DISCUSSIONS_PAGE}, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { id resolvable resolved notes(first: 1) { nodes { author { username } } } }
      }
    }
  }
}`;
const RESOLVE_THREAD_MUTATION = `
mutation SuicaResolveThread($id: DiscussionID!) {
  discussionToggleResolve(input: { id: $id, resolve: true }) { errors }
}`;
/** 2,000 discussions: far beyond any MR on this team, and a bound on the calls. */
const MAX_THREAD_PAGES = 20;

const ownThreadsSchema = z.object({
  data: z.object({
    currentUser: z.object({ username: z.string() }),
    project: z.object({
      mergeRequest: z.object({
        discussions: z.object({
          pageInfo: z.object({ hasNextPage: z.boolean(), endCursor: z.string().nullable() }),
          nodes: z.array(
            z.object({
              id: z.string(),
              resolvable: z.boolean(),
              resolved: z.boolean(),
              notes: z.object({
                nodes: z.array(z.object({ author: z.object({ username: z.string() }).nullable() })),
              }),
            }),
          ),
        }),
      }),
    }),
  }),
});
const resolveSchema = z.object({
  data: z.object({ discussionToggleResolve: z.object({ errors: z.array(z.string()) }) }),
});

export interface ResolveOutcome {
  /** Threads resolved now. */
  readonly resolved: number;
  /** False when a thread could not be resolved or the threads could not all be read. */
  readonly complete: boolean;
}

/**
 * Resolves every open thread the Owner started on the MR (the Owner's own comments and the Agent
 * Review's inline threads), after the Owner approved it. Threads others started stay open, even
 * where the Owner replied. Never throws.
 */
export async function resolveOwnThreads(
  deps: { readonly graphql: GraphqlRunner; readonly log: Logger },
  key: string,
): Promise<ResolveOutcome> {
  const parts = parseMrKey(key);
  if (parts === undefined) return { resolved: 0, complete: false };
  const open: string[] = [];
  try {
    let after: string | null = null;
    for (let page = 0; page < MAX_THREAD_PAGES; page++) {
      const variables: Record<string, string> = { path: parts.projectPath, iid: parts.iid };
      if (after !== null) variables["after"] = after;
      const { data } = ownThreadsSchema.parse(await deps.graphql(OWN_THREADS_QUERY, variables));
      const { pageInfo, nodes } = data.project.mergeRequest.discussions;
      const me = data.currentUser.username;
      for (const thread of nodes) {
        if (
          thread.resolvable &&
          !thread.resolved &&
          thread.notes.nodes[0]?.author?.username === me
        ) {
          open.push(thread.id);
        }
      }
      if (!pageInfo.hasNextPage || pageInfo.endCursor === null) {
        after = null;
        break;
      }
      after = pageInfo.endCursor;
    }
    if (after !== null) throw new Error("too many discussions");
  } catch (error) {
    deps.log.warn("own threads lookup failed", { reason: errorName(error) });
    return { resolved: 0, complete: false };
  }
  let resolved = 0;
  for (const id of open) {
    try {
      const { data } = resolveSchema.parse(await deps.graphql(RESOLVE_THREAD_MUTATION, { id }));
      if (data.discussionToggleResolve.errors.length === 0) resolved++;
    } catch (error) {
      deps.log.warn("resolve thread failed", { reason: errorName(error) });
    }
  }
  deps.log.info("own threads resolved", { mr_key: key, resolved, open: open.length });
  return { resolved, complete: resolved === open.length };
}

function errorName(error: unknown): string {
  return error instanceof Error ? error.name : "unknown";
}
