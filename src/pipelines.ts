import { z } from "zod";
import type { Pipeline } from "./domain.ts";
import { FetchFailure } from "./gitlab.ts";
import type { GraphqlRunner, TextRunner } from "./gitlab.ts";
import type { FixJob, FixPipeline } from "./fix-store.ts";
import { parseMrKey } from "./reviews.ts";

/** At most this many failed jobs, each with the end of its log, go to the model. */
export const MAX_JOBS = 5;
const LOG_LINES = 300;
const LOG_CHARS = 20_000;
const LINE_CHARS = 2_000;
const JOB_ID = /^gid:\/\/gitlab\/Ci::Build\/(\d+)$/;

const HEAD_PIPELINE_QUERY = `
query SuicaHeadPipeline($path: ID!, $iid: String!) {
  project(fullPath: $path) {
    mergeRequest(iid: $iid) {
      title
      webUrl
      author { username }
      headPipeline { iid status path }
    }
  }
}
`;

const PIPELINE_QUERY = `
query SuicaPipeline($path: ID!, $iid: ID!) {
  project(fullPath: $path) {
    pipeline(iid: $iid) {
      iid
      sha
      jobs(statuses: [FAILED]) {
        nodes { id name allowFailure stage { name } webPath }
      }
    }
  }
}
`;

const pipelineRefSchema = z.object({
  iid: z.string(),
  status: z.string(),
  path: z.string().nullable(),
});
const headSchema = z.object({
  data: z.object({
    project: z
      .object({
        mergeRequest: z
          .object({
            title: z.string(),
            webUrl: z.string(),
            author: z.object({ username: z.string() }).nullable(),
            headPipeline: pipelineRefSchema.nullable(),
          })
          .nullable(),
      })
      .nullable(),
  }),
});
const jobSchema = z.object({
  id: z.string(),
  name: z.string(),
  allowFailure: z.boolean(),
  stage: z.object({ name: z.string() }).nullable(),
  webPath: z.string().nullable(),
});
const pipelineSchema = z.object({
  data: z.object({
    project: z
      .object({
        pipeline: z
          .object({
            iid: z.string(),
            sha: z.string().nullable(),
            jobs: z.object({ nodes: z.array(jobSchema) }),
          })
          .nullable(),
      })
      .nullable(),
  }),
});

/** A path GitLab gives, as a link on the MR's own host. */
function link(webUrl: string, path: string | null): string {
  return path?.startsWith("/") === true && URL.canParse(webUrl)
    ? `${new URL(webUrl).origin}${path}`
    : webUrl;
}

/** An MR's title, author and head pipeline, for a Pipeline Fix the Owner asks for. */
export interface HeadPipeline {
  readonly title: string;
  readonly author: string;
  readonly pipeline: Pipeline | null;
}

export async function fetchHeadPipeline(run: GraphqlRunner, key: string): Promise<HeadPipeline> {
  const parts = parseMrKey(key);
  if (parts === undefined) throw new FetchFailure("gitlab-error", "bad merge request key");
  const parsed = headSchema.safeParse(
    await run(HEAD_PIPELINE_QUERY, { path: parts.projectPath, iid: parts.iid }),
  );
  const mr = parsed.success ? parsed.data.data.project?.mergeRequest : undefined;
  if (mr === null || mr === undefined) {
    throw new FetchFailure("gitlab-error", "merge request not found");
  }
  const head = mr.headPipeline;
  return {
    title: mr.title,
    author: mr.author?.username ?? "",
    pipeline:
      head === null
        ? null
        : { iid: head.iid, status: head.status, url: link(mr.webUrl, head.path) },
  };
}

const TIMESTAMP = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z [0-9a-f]{2}[OE]([+ ]?)/;

/** The log's lines without timestamps; GitLab splits a long line into parts marked `+`, joined again here. */
function logLines(raw: string): string[] {
  const lines: string[] = [];
  for (const line of raw.split("\n")) {
    const stamp = TIMESTAMP.exec(line);
    const text = stamp === null ? line : line.slice(stamp[0].length);
    if (stamp?.[1] === "+" && lines.length > 0) lines[lines.length - 1] += text;
    else lines.push(text);
  }
  return lines;
}

/**
 * Removes what only a terminal shows from a GitLab job log: the per-line timestamps of timestamped
 * logs, colour codes, section markers and text a carriage return wrote over. Runs of blank lines
 * become one, and a line longer than 2,000 characters is cut.
 */
export function cleanJobLog(raw: string): string {
  const lines: string[] = [];
  for (const line of logLines(raw)) {
    const text = line
      .replace(/section_(?:start|end):\d+:[\w.-]+(?:\[[^\]]*\])?/g, "")
      // eslint-disable-next-line no-control-regex
      .replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "")
      .split("\r")
      .filter((part) => part !== "")
      .at(-1)
      ?.trimEnd();
    const whole = text ?? "";
    const clean = whole.length > LINE_CHARS ? `${whole.slice(0, LINE_CHARS)}…` : whole;
    if (clean === "" && (lines.length === 0 || lines.at(-1) === "")) continue;
    lines.push(clean);
  }
  return lines.join("\n").trim();
}

/** The end of a cleaned log: its last lines, cut to whole lines within the character budget. */
export function tailJobLog(log: string): string {
  let tail = log.split("\n").slice(-LOG_LINES).join("\n");
  if (tail.length > LOG_CHARS) {
    tail = tail.slice(-LOG_CHARS);
    const start = tail.indexOf("\n");
    if (start >= 0) tail = tail.slice(start + 1);
  }
  return tail;
}

type GitlabJob = z.infer<typeof jobSchema>;

/** The failed jobs that failed the pipeline, or every failed job when all were allowed to fail. */
export function pickFailedJobs(jobs: readonly GitlabJob[]): GitlabJob[] {
  const blocking = jobs.filter((job) => !job.allowFailure);
  return (blocking.length > 0 ? blocking : [...jobs]).slice(0, MAX_JOBS);
}

/** A fence longer than any run of tildes in the text, so a log cannot close it. */
function fenceFor(text: string): string {
  const longest = Math.max(0, ...[...text.matchAll(/~+/g)].map((match) => match[0].length));
  return "~".repeat(Math.max(4, longest + 1));
}

/** `./pipeline.md`: the pipeline, and each failed job with the end of its log. */
export function renderPipelineFile(
  pipeline: Pick<FixPipeline, "iid" | "sha">,
  jobs: readonly { job: FixJob; log: string | null }[],
): string {
  return [
    `# Pipeline #${pipeline.iid}`,
    "",
    pipeline.sha === null ? "It failed." : `It ran on commit ${pipeline.sha} and failed.`,
    "",
    ...jobs.flatMap(({ job, log }) => {
      const fence = fenceFor(log ?? "");
      return [
        `## Job ${job.name} (stage ${job.stage})`,
        "",
        ...(log === null
          ? ["Its log could not be read."]
          : log === ""
            ? ["Its log is empty."]
            : ["The end of its log:", "", `${fence}text`, log, fence]),
        "",
      ];
    }),
  ].join("\n");
}

export interface FailedPipeline {
  /** The pipeline with its commit and failed jobs; no summary yet. */
  readonly pipeline: FixPipeline;
  /** The text of `./pipeline.md`. */
  readonly file: string;
}

/**
 * Reads a failed pipeline of an MR's project: its commit, the jobs that failed it and the end of
 * each one's log. A log that cannot be read is left out, not fatal; logs are never kept elsewhere.
 */
export async function readFailedPipeline(
  run: GraphqlRunner,
  text: TextRunner,
  key: string,
  pipeline: Pick<FixPipeline, "iid" | "url">,
): Promise<FailedPipeline> {
  const parts = parseMrKey(key);
  if (parts === undefined) throw new FetchFailure("gitlab-error", "bad merge request key");
  const parsed = pipelineSchema.safeParse(
    await run(PIPELINE_QUERY, { path: parts.projectPath, iid: pipeline.iid }),
  );
  const found = parsed.success ? parsed.data.data.project?.pipeline : undefined;
  if (found === null || found === undefined) {
    throw new FetchFailure("gitlab-error", "pipeline not found");
  }
  const project = encodeURIComponent(parts.projectPath);
  const jobs = await Promise.all(
    pickFailedJobs(found.jobs.nodes).map(async (each) => {
      const job: FixJob = {
        name: each.name,
        stage: each.stage?.name ?? "",
        url: link(pipeline.url, each.webPath),
      };
      const id = JOB_ID.exec(each.id)?.[1];
      if (id === undefined) return { job, log: null };
      try {
        return {
          job,
          log: tailJobLog(cleanJobLog(await text(`projects/${project}/jobs/${id}/trace`))),
        };
      } catch {
        return { job, log: null };
      }
    }),
  );
  const read: FixPipeline = {
    iid: found.iid,
    url: pipeline.url,
    sha: found.sha,
    jobs: jobs.map((each) => each.job),
    summary: "",
  };
  return { pipeline: read, file: renderPipelineFile(read, jobs) };
}
