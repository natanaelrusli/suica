import { z } from "zod";
import type { Config } from "./config.ts";
import { UNREVIEWED } from "./domain.ts";
import type { MergeRequest, Person, Snapshot } from "./domain.ts";
import { defaultExec, execFailure } from "./exec.ts";
import type { Exec, ExecFailure } from "./exec.ts";

export type GitlabFailureKind =
  "glab-missing" | "gitlab-auth" | "gitlab-unreachable" | "gitlab-error";

export class FetchFailure extends Error {
  readonly kind: GitlabFailureKind;

  constructor(kind: GitlabFailureKind, message: string) {
    super(message);
    this.name = "FetchFailure";
    this.kind = kind;
  }
}

export type GraphqlRunner = (query: string) => Promise<unknown>;

const PAGE_SIZE = 100;
const NOTES_WINDOW = 50;

export const SNAPSHOT_QUERY = `
query MrReviewAssistantSnapshot {
  currentUser {
    username
    name
    reviewRequestedMergeRequests(state: opened, first: ${PAGE_SIZE}) {
      pageInfo { hasNextPage }
      nodes { ...MrFields }
    }
    authoredMergeRequests(state: opened, first: ${PAGE_SIZE}) {
      pageInfo { hasNextPage }
      nodes { ...MrFields }
    }
  }
}
fragment MrFields on MergeRequest {
  iid
  title
  webUrl
  draft
  project { fullPath }
  author { username name }
  reviewers { nodes { username name mergeRequestInteraction { reviewState } } }
  notes(last: ${NOTES_WINDOW}) { nodes { id system author { username name } } }
}
`;

const GHOST: Person = { username: "ghost", name: "(unknown user)" };

const personSchema = z.object({ username: z.string(), name: z.string() });
const reviewerSchema = personSchema.extend({
  mergeRequestInteraction: z.object({ reviewState: z.string().nullable() }).nullable(),
});
const noteSchema = z.object({
  id: z.string(),
  system: z.boolean(),
  author: personSchema.nullable(),
});
const httpUrlSchema = z
  .string()
  .refine((url) => /^https?:\/\//.test(url), "must be an http(s) URL");
const mrSchema = z.object({
  iid: z.coerce.number().int(),
  title: z.string(),
  webUrl: httpUrlSchema,
  draft: z.boolean(),
  project: z.object({ fullPath: z.string() }),
  author: personSchema.nullable(),
  reviewers: z.object({ nodes: z.array(reviewerSchema) }),
  notes: z.object({ nodes: z.array(noteSchema) }).optional(),
});
const connectionSchema = z.object({
  pageInfo: z.object({ hasNextPage: z.boolean() }),
  nodes: z.array(mrSchema),
});
const responseSchema = z.object({
  data: z
    .object({
      currentUser: z
        .object({
          username: z.string(),
          name: z.string(),
          reviewRequestedMergeRequests: connectionSchema,
          authoredMergeRequests: connectionSchema,
        })
        .nullable(),
    })
    .nullable()
    .optional(),
  errors: z.array(z.object({ message: z.string() })).optional(),
});

function toMergeRequest(node: z.infer<typeof mrSchema>): MergeRequest {
  return {
    key: `${node.project.fullPath}!${node.iid}`,
    projectPath: node.project.fullPath,
    iid: node.iid,
    title: node.title,
    url: node.webUrl,
    draft: node.draft,
    author: node.author ?? GHOST,
    reviewers: node.reviewers.nodes.map((reviewer) => ({
      username: reviewer.username,
      name: reviewer.name,
      state: reviewer.mergeRequestInteraction?.reviewState ?? UNREVIEWED,
    })),
    notes: (node.notes?.nodes ?? []).map((note) => ({
      id: note.id,
      system: note.system,
      author: note.author ?? GHOST,
    })),
  };
}

export function parseSnapshot(raw: unknown): Snapshot {
  const parsed = responseSchema.safeParse(raw);
  if (!parsed.success) throw new FetchFailure("gitlab-error", "unexpected GraphQL response shape");
  const { data, errors } = parsed.data;
  if (errors !== undefined && errors.length > 0) {
    throw new FetchFailure("gitlab-error", "GraphQL response contained errors");
  }
  const user = data?.currentUser;
  if (user === null || user === undefined) {
    throw new FetchFailure("gitlab-auth", "GraphQL response has no current user");
  }
  if (
    user.reviewRequestedMergeRequests.pageInfo.hasNextPage ||
    user.authoredMergeRequests.pageInfo.hasNextPage
  ) {
    throw new FetchFailure(
      "gitlab-error",
      `more than ${PAGE_SIZE} open merge requests; pagination is not supported`,
    );
  }
  return {
    me: { username: user.username, name: user.name },
    reviewRequested: user.reviewRequestedMergeRequests.nodes.map(toMergeRequest),
    authored: user.authoredMergeRequests.nodes.map(toMergeRequest),
  };
}

const UNREACHABLE_PATTERN =
  /timed out|timeout|no such host|connection refused|dial tcp|network is unreachable|could not resolve/;
const AUTH_PATTERN = /\b401\b|unauthorized|not logged in|authenticat/;

export function classifyFailure(failure: ExecFailure): GitlabFailureKind {
  if (failure.code === "ENOENT") return "glab-missing";
  const text = (failure.stderr ?? "").toLowerCase();
  if (failure.killed === true || UNREACHABLE_PATTERN.test(text)) return "gitlab-unreachable";
  if (AUTH_PATTERN.test(text)) return "gitlab-auth";
  return "gitlab-error";
}

export function glabRunner(config: Config["gitlab"], exec: Exec = defaultExec): GraphqlRunner {
  return async (query) => {
    let stdout: string;
    try {
      ({ stdout } = await exec(
        config.glabPath,
        ["api", "graphql", "--hostname", config.hostname, "-f", `query=${query}`],
        { timeoutMs: config.timeoutSeconds * 1000 },
      ));
    } catch (error) {
      const failure = execFailure(error);
      throw new FetchFailure(
        classifyFailure(failure),
        failure.code === "ENOENT"
          ? "glab executable not found"
          : `glab failed with code ${String(failure.code ?? "unknown")}`,
      );
    }
    try {
      const output: unknown = JSON.parse(stdout);
      return output;
    } catch {
      throw new FetchFailure("gitlab-error", "glab output was not JSON");
    }
  };
}

export async function fetchSnapshot(run: GraphqlRunner): Promise<Snapshot> {
  return parseSnapshot(await run(SNAPSHOT_QUERY));
}
