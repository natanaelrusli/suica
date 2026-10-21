import { createHash } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { z } from "zod";
import type { Config } from "./config.ts";
import { UNREVIEWED } from "./domain.ts";
import type { MergeRequest, Person, Pipeline, Snapshot } from "./domain.ts";
import { defaultExec, execFailure } from "./exec.ts";
import type { Exec, ExecFailure } from "./exec.ts";

export type GitlabFailureKind =
  "glab-missing" | "gitlab-auth" | "gitlab-unreachable" | "gitlab-error";

export class FetchFailure extends Error {
  readonly kind: GitlabFailureKind;
  /** The HTTP status glab reported for a REST call, when it reported one. */
  readonly httpStatus: number | undefined;

  constructor(kind: GitlabFailureKind, message: string, httpStatus?: number) {
    super(message);
    this.name = "FetchFailure";
    this.kind = kind;
    this.httpStatus = httpStatus;
  }
}

export type GraphqlRunner = (
  query: string,
  variables?: Readonly<Record<string, string>>,
) => Promise<unknown>;

const PAGE_SIZE = 100;
const NOTES_WINDOW = 50;

const NOTES_FIELD = `  notes(last: ${NOTES_WINDOW}) { nodes { id system author { username name } } }\n`;

/** Notes are the costly part for GitLab; only the poller reads them. */
function snapshotQuery(notes: boolean): string {
  return `
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
  createdAt
  diffHeadSha
  description
  project { fullPath }
  author { username name }
  reviewers { nodes { username name mergeRequestInteraction { reviewState } } }
  headPipeline { iid status path }
${notes ? NOTES_FIELD : ""}}
`;
}

export const SNAPSHOT_QUERY = snapshotQuery(true);

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
  createdAt: z.string().nullable().optional(),
  diffHeadSha: z.string().nullable().optional(),
  description: z.string().nullable().optional(),
  project: z.object({ fullPath: z.string() }),
  author: personSchema.nullable(),
  reviewers: z.object({ nodes: z.array(reviewerSchema) }),
  notes: z.object({ nodes: z.array(noteSchema) }).optional(),
  headPipeline: z
    .object({ iid: z.string(), status: z.string(), path: z.string().nullable() })
    .nullable()
    .optional(),
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

/** The hash kept instead of a description: an empty description hashes too, so a cleared one counts. */
export function descriptionSha(description: string | null): string {
  return createHash("sha256")
    .update(description ?? "")
    .digest("hex");
}

/** GitLab gives the pipeline's path; the link is on the MR's own host. */
function toPipeline(
  webUrl: string,
  pipeline: z.infer<typeof mrSchema>["headPipeline"],
): Pipeline | null {
  if (pipeline === null || pipeline === undefined) return null;
  const origin = new URL(webUrl).origin;
  return {
    iid: pipeline.iid,
    status: pipeline.status,
    url: pipeline.path?.startsWith("/") === true ? `${origin}${pipeline.path}` : webUrl,
  };
}

function toMergeRequest(node: z.infer<typeof mrSchema>): MergeRequest {
  return {
    key: `${node.project.fullPath}!${node.iid}`,
    projectPath: node.project.fullPath,
    iid: node.iid,
    title: node.title,
    url: node.webUrl,
    draft: node.draft,
    createdAt: node.createdAt ?? null,
    headSha: node.diffHeadSha ?? null,
    descriptionSha: node.description === undefined ? null : descriptionSha(node.description),
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
    pipeline: toPipeline(node.webUrl, node.headPipeline),
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
/** glab ends an HTTP error with "(HTTP 404)". */
const HTTP_STATUS_PATTERN = /\(HTTP (\d{3})\)/;

export function httpStatusOf(failure: ExecFailure): number | undefined {
  const match = HTTP_STATUS_PATTERN.exec(failure.stderr ?? "");
  return match?.[1] === undefined ? undefined : Number(match[1]);
}

export function classifyFailure(failure: ExecFailure): GitlabFailureKind {
  if (failure.code === "ENOENT") return "glab-missing";
  const text = (failure.stderr ?? "").toLowerCase();
  if (failure.killed === true || UNREACHABLE_PATTERN.test(text)) return "gitlab-unreachable";
  if (AUTH_PATTERN.test(text)) return "gitlab-auth";
  return "gitlab-error";
}

/** Runs `glab api <endpoint>` with `fields` and returns its output as text. */
async function runGlabText(
  config: Config["gitlab"],
  exec: Exec,
  endpoint: string,
  fields: readonly string[] = [],
): Promise<string> {
  try {
    const { stdout } = await exec(
      config.glabPath,
      ["api", endpoint, "--hostname", config.hostname, ...fields],
      { timeoutMs: config.timeoutSeconds * 1000 },
    );
    return stdout;
  } catch (error) {
    const failure = execFailure(error);
    throw new FetchFailure(
      classifyFailure(failure),
      failure.code === "ENOENT"
        ? "glab executable not found"
        : `glab failed with code ${String(failure.code ?? "unknown")}`,
      httpStatusOf(failure),
    );
  }
}

/** Runs `glab api <endpoint>` with `fields` and parses its JSON output. */
async function runGlab(
  config: Config["gitlab"],
  exec: Exec,
  endpoint: string,
  fields: readonly string[] = [],
): Promise<unknown> {
  const stdout = await runGlabText(config, exec, endpoint, fields);
  try {
    const output: unknown = JSON.parse(stdout);
    return output;
  } catch {
    throw new FetchFailure("gitlab-error", "glab output was not JSON");
  }
}

/** Variables travel as separate `-f` fields, so values never end up inside the query text. */
export function glabRunner(config: Config["gitlab"], exec: Exec = defaultExec): GraphqlRunner {
  return (query, variables = {}) =>
    runGlab(config, exec, "graphql", [
      "-f",
      `query=${query}`,
      ...Object.entries(variables).flatMap(([name, value]) => ["-f", `${name}=${value}`]),
    ]);
}

/** A REST GET; `path` is relative to the API root and must already be URL-encoded. */
export type RestRunner = (path: string) => Promise<unknown>;

export function glabRest(config: Config["gitlab"], exec: Exec = defaultExec): RestRunner {
  return (path) => runGlab(config, exec, path);
}

/** A REST GET of a plain-text resource, such as a job log; `path` must already be URL-encoded. */
export type TextRunner = (path: string) => Promise<string>;

export function glabText(config: Config["gitlab"], exec: Exec = defaultExec): TextRunner {
  return (path) => runGlabText(config, exec, path);
}

/** A REST POST with string form fields, each sent as a literal `-f` value; returns the JSON reply. */
export type PostRunner = (
  path: string,
  fields: Readonly<Record<string, string>>,
) => Promise<unknown>;

function formRunner(config: Config["gitlab"], exec: Exec, method: "POST" | "PUT"): PostRunner {
  return (path, fields) =>
    runGlab(config, exec, path, [
      "-X",
      method,
      ...Object.entries(fields).flatMap(([name, value]) => ["-f", `${name}=${value}`]),
    ]);
}

export function glabPost(config: Config["gitlab"], exec: Exec = defaultExec): PostRunner {
  return formRunner(config, exec, "POST");
}

/** A REST PUT with string form fields, such as a merge. */
export type PutRunner = PostRunner;

export function glabPut(config: Config["gitlab"], exec: Exec = defaultExec): PutRunner {
  return formRunner(config, exec, "PUT");
}

/** A REST POST with a JSON body, for nested fields such as a diff thread's `position`. */
export type PostJsonRunner = (path: string, body: unknown) => Promise<unknown>;

/**
 * The body travels in a private temporary file through `--input`: `-F` would rewrite `:branch` and
 * the like inside JSON values, and `-f` cannot nest.
 */
export function glabPostJson(config: Config["gitlab"], exec: Exec = defaultExec): PostJsonRunner {
  return async (path, body) => {
    const dir = mkdtempSync(join(tmpdir(), "suica-post-"));
    const file = join(dir, "body.json");
    try {
      writeFileSync(file, JSON.stringify(body), { mode: 0o600 });
      return await runGlab(config, exec, path, [
        "-X",
        "POST",
        "-H",
        "Content-Type: application/json",
        "--input",
        file,
      ]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  };
}

const usersSchema = z.array(personSchema);

/** A user's display name by username; undefined when GitLab knows no such user. */
export async function fetchPerson(rest: RestRunner, username: string): Promise<Person | undefined> {
  const users = usersSchema.safeParse(await rest(`users?username=${encodeURIComponent(username)}`));
  if (!users.success) throw new FetchFailure("gitlab-error", "unexpected users response shape");
  return users.data.find((user) => user.username === username);
}

const currentUserSchema = z.object({ username: z.string() });

/** The username of the account glab is signed in as: the Owner. */
export async function fetchCurrentUsername(rest: RestRunner): Promise<string> {
  const user = currentUserSchema.safeParse(await rest("user"));
  if (!user.success) throw new FetchFailure("gitlab-error", "unexpected user response shape");
  return user.data.username;
}

/** `notes: false` leaves every MR's notes empty, for readers that do not look at them. */
export async function fetchSnapshot(
  run: GraphqlRunner,
  { notes = true }: { readonly notes?: boolean } = {},
): Promise<Snapshot> {
  return parseSnapshot(await run(notes ? SNAPSHOT_QUERY : snapshotQuery(false)));
}
