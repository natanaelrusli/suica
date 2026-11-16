import type { Store } from "./store.ts";
import { FetchFailure } from "./gitlab.ts";
import type { PostRunner, PostJsonRunner, RestRunner } from "./gitlab.ts";
import type { AgentReviewRow } from "./store.ts";
import { sanitizeForGitLab } from "./review-sanitize.ts";

export interface PostPart {
  key: string;
  kind: "inline" | "summary";
  endpoint: string;
  payload: string;
  state: "pending" | "sending" | "confirmed" | "uncertain" | "rejected";
  remoteId: string | null;
}
export interface PostingLease {
  reviewId: number;
  token: string;
  expiresAt: number;
}
export interface ReviewPostDeps {
  store: Store;
  post: PostRunner;
  postJson: PostJsonRunner;
  rest: RestRunner;
  log: (message: string) => void;
  now: () => number;
  ownerUsername: string;
  preflight: () => Promise<boolean>;
  buildPlan: (row: AgentReviewRow) => Promise<readonly PostPart[]>;
  token?: () => string;
  completionDetail?: (parts: readonly PostPart[]) => string;
}

const MAX_NOTE_CHARS = 100_000;
const MAX_WARNING_CHARS = 500;
const safeKey = (key: string) => (/^[a-zA-Z0-9_-]{1,64}$/.test(key) ? key : "part");
function failureCategory(error: unknown): string {
  const status = error instanceof FetchFailure ? error.httpStatus : undefined;
  if (status !== undefined && Number.isInteger(status) && status >= 100 && status <= 599)
    return `HTTP ${status}`;
  if (error instanceof FetchFailure) return error.kind;
  return "unexpected error";
}
function warning(message: string): string {
  return message.slice(0, MAX_WARNING_CHARS);
}
const marker = (id: number, sha: string, key: string) =>
  `<!-- suica-review:${id}:${sha}:${key} -->`;
function bodyFrom(payload: string): string {
  const value: unknown = JSON.parse(payload);
  if (
    typeof value === "object" &&
    value !== null &&
    "body" in value &&
    typeof value.body === "string"
  )
    return value.body;
  return "";
}
function withMarker(payload: string, id: number, sha: string, key: string): string {
  const value: unknown = JSON.parse(payload);
  const mark = marker(id, sha, key);
  if (
    typeof value !== "object" ||
    value === null ||
    !("body" in value) ||
    typeof value.body !== "string"
  )
    throw new Error("post payload has no body");
  const body = sanitizeForGitLab(value.body);
  const limited = body.slice(0, Math.max(0, MAX_NOTE_CHARS - mark.length - 2));
  return JSON.stringify({ ...value, body: `${limited}\n\n${mark}` });
}

export async function resumeReviewPosting(
  deps: ReviewPostDeps,
  id: number,
): Promise<"posted" | "held" | "nothing"> {
  const row = deps.store.getAgentReview(id);
  if (!row || (row.status !== "ready" && row.status !== "posting")) return "nothing";
  if (
    row.status === "ready" &&
    row.detail?.includes("Posting was interrupted") &&
    !deps.store.reviewPostParts(id).length
  )
    return "held";
  try {
    if (!(await deps.preflight())) return "held";
  } catch {
    const message = warning("Posting preflight failed; inspect GitLab before retrying.");
    deps.log(message);
    return "held";
  }
  const token = deps.token?.() ?? `${id}-${deps.now()}-${Math.random()}`;
  const lease = deps.store.claimReviewPosting(id, token, deps.now());
  if (!lease) return "held";
  const hold = (message: string): "held" => {
    deps.store.holdReviewPosting(lease, message, deps.now());
    deps.log(message);
    return "held";
  };
  try {
    let parts = deps.store.reviewPostParts(id);
    if (!parts.length) {
      const planned = await deps.buildPlan(row);
      const frozen = planned.map((part) => ({
        ...part,
        payload: withMarker(part.payload, id, row.headSha ?? "unknown", part.key),
        state: "pending" as const,
        remoteId: null,
      }));
      if (!deps.store.saveReviewPostPlan(lease, frozen, deps.now()))
        return hold("Could not save frozen posting plan; inspect before retrying.");
      parts = deps.store.reviewPostParts(id);
    }
    for (const part of parts) {
      if (part.state === "confirmed") continue;
      if (part.state === "rejected")
        return hold(
          warning(`Posting part ${safeKey(part.key)} is rejected; inspect GitLab before retrying.`),
        );
      if (part.state === "sending" || part.state === "uncertain") {
        let recovered: string | null;
        try {
          recovered = await reconcile(deps, row, part);
        } catch (error) {
          return hold(
            warning(
              `Could not reconcile posting part ${safeKey(part.key)} (${failureCategory(error)}); inspect GitLab.`,
            ),
          );
        }
        if (!recovered)
          return hold(
            `Posting part ${safeKey(part.key)} remains uncertain; inspect GitLab before retrying.`,
          );
        if (!deps.store.updateReviewPostPart(lease, part.key, "confirmed", recovered, deps.now()))
          return hold("Posting ownership changed during recovery; inspect GitLab.");
        continue;
      }
      if (!deps.store.renewReviewPosting(lease, deps.now()))
        return hold("Posting lease expired; inspect GitLab before retrying.");
      if (!deps.store.updateReviewPostPart(lease, part.key, "sending", null, deps.now()))
        return hold("Posting ownership changed; inspect GitLab before retrying.");
      try {
        const payload: unknown = JSON.parse(part.payload);
        const result =
          part.kind === "inline"
            ? await deps.postJson(part.endpoint, payload)
            : await deps.post(part.endpoint, { body: bodyFrom(part.payload) });
        const remoteId =
          typeof result === "object" &&
          result !== null &&
          "id" in result &&
          (typeof result.id === "string" || typeof result.id === "number")
            ? String(result.id)
            : null;
        let confirmedId = remoteId;
        if (confirmedId === null) confirmedId = await reconcile(deps, row, part);
        if (confirmedId === null) {
          deps.store.updateReviewPostPart(lease, part.key, "uncertain", null, deps.now());
          return hold(
            warning(
              `Posting part ${safeKey(part.key)} has no confirmed remote ID; inspect GitLab.`,
            ),
          );
        }
        if (!deps.store.updateReviewPostPart(lease, part.key, "confirmed", confirmedId, deps.now()))
          return hold("Posting ownership changed after remote write; inspect GitLab.");
      } catch (error) {
        const status = error instanceof FetchFailure ? error.httpStatus : undefined;
        if (
          status !== undefined &&
          status >= 400 &&
          status < 500 &&
          status !== 408 &&
          status !== 429
        ) {
          deps.store.updateReviewPostPart(lease, part.key, "rejected", null, deps.now());
          return hold(
            warning(
              `Posting part ${safeKey(part.key)} was rejected (HTTP ${status}); inspect GitLab before retrying.`,
            ),
          );
        }
        deps.store.updateReviewPostPart(lease, part.key, "uncertain", null, deps.now());
        return hold(
          warning(
            `Posting part ${safeKey(part.key)} outcome is uncertain (${failureCategory(error)}); inspect GitLab.`,
          ),
        );
      }
    }
    return deps.store.finishReviewPosting(lease, deps.now(), deps.completionDetail?.(parts))
      ? "posted"
      : hold("Posting could not be fenced at completion; inspect GitLab.");
  } catch (error) {
    return hold(
      warning(
        `Posting held for inspection (${failureCategory(error)}); inspect GitLab before retrying.`,
      ),
    );
  }
}

async function reconcile(
  deps: ReviewPostDeps,
  row: AgentReviewRow,
  part: PostPart,
): Promise<string | null> {
  const path = part.endpoint.replace(/\/notes$/, "/notes");
  const expected = marker(row.id, row.headSha ?? "unknown", part.key);
  for (let page = 1; page <= 100; page++) {
    const result: unknown = await deps.rest(`${path}?per_page=100&page=${page}`);
    if (!Array.isArray(result)) throw new Error("incomplete notes response");
    const items: unknown[] = result;
    const notes = items.flatMap((item): unknown[] => {
      const top = part.kind === "inline" ? notesOf(item) : undefined;
      return top === undefined
        ? [item]
        : top.flatMap((discussion) => notesOf(discussion) ?? [discussion]);
    });
    for (const item of notes) {
      if (
        typeof item !== "object" ||
        item === null ||
        !("body" in item) ||
        typeof item.body !== "string" ||
        !item.body.includes(expected) ||
        !("author" in item) ||
        typeof item.author !== "object" ||
        item.author === null ||
        !("username" in item.author) ||
        item.author.username !== deps.ownerUsername
      )
        continue;
      if ("id" in item && (typeof item.id === "string" || typeof item.id === "number"))
        return String(item.id);
      throw new Error("matching note has no remote ID");
    }
    if (result.length === 0) return null;
  }
  throw new Error("note pagination incomplete");
}

/** The `notes` array of a discussion object, if it has one. */
function notesOf(value: unknown): unknown[] | undefined {
  return typeof value === "object" &&
    value !== null &&
    "notes" in value &&
    Array.isArray(value.notes)
    ? (value.notes as unknown[])
    : undefined;
}
