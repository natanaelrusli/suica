import { z } from "zod";
import type { Person } from "../domain.ts";
import { FetchFailure } from "../gitlab.ts";
import type { GraphqlRunner } from "../gitlab.ts";
import { parseMrKey } from "../reviews.ts";
import { MANUAL_PREFIX } from "./dispatch.ts";
import { TEMPLATE_NAMES } from "./types.ts";
import type { Intent, OutboxKind, TemplateName } from "./types.ts";

/** A message longer than this is refused; Teams messages from templates are a few lines. */
export const MAX_MESSAGE_CHARS = 4_000;

/** `suica message <key> --json` reads this on stdin. */
export interface MessageRequest {
  /** GitLab username of the Author or a Reviewer of the MR. */
  readonly to: string;
  readonly template: TemplateName;
  /** The text to send as written; null sends (or drafts) the template's text. */
  readonly text: string | null;
  /** False only drafts: the reply holds the template's text and nothing is sent. */
  readonly send: boolean;
}

const requestSchema = z.object({
  to: z.string().min(1).max(255),
  template: z.enum(TEMPLATE_NAMES),
  text: z.string().max(MAX_MESSAGE_CHARS).nullable(),
  send: z.boolean(),
});

/** Undefined for anything but a well-formed request; a blank text counts as none. */
export function parseMessageRequest(raw: string): MessageRequest | undefined {
  let json: unknown;
  try {
    json = JSON.parse(raw);
  } catch {
    return undefined;
  }
  const parsed = requestSchema.safeParse(json);
  if (!parsed.success) return undefined;
  const text = parsed.data.text?.trim() ?? "";
  return { ...parsed.data, text: text === "" ? null : text };
}

/** The flow a template belongs to, so Messages files the row with its kind. */
export function kindOf(template: TemplateName): OutboxKind {
  if (template === "nudge" || template === "reminder" || template === "rereview") return template;
  return "notice";
}

const CONTEXT_QUERY = `
query SuicaMessageContext($path: ID!, $iid: String!) {
  currentUser { username name }
  project(fullPath: $path) {
    mergeRequest(iid: $iid) {
      title
      webUrl
      author { username name }
      reviewers { nodes { username name } }
    }
  }
}
`;

const personSchema = z.object({ username: z.string(), name: z.string() });
const contextSchema = z.object({
  data: z.object({
    currentUser: personSchema.nullable(),
    project: z
      .object({
        mergeRequest: z
          .object({
            title: z.string(),
            webUrl: z.string().refine((url) => /^https?:\/\//.test(url)),
            author: personSchema.nullable(),
            reviewers: z.object({ nodes: z.array(personSchema) }),
          })
          .nullable(),
      })
      .nullable(),
  }),
});

export interface MessageContext {
  readonly owner: Person;
  readonly intent: Intent;
}

/**
 * Reads the MR and checks the recipient against it: only its Author or one of its Reviewers, and
 * never the Owner, can get a message from its page. Undefined for anyone else.
 */
export async function fetchMessageContext(
  run: GraphqlRunner,
  key: string,
  request: MessageRequest,
  now: number,
): Promise<MessageContext | undefined> {
  const parts = parseMrKey(key);
  if (parts === undefined) throw new FetchFailure("gitlab-error", "bad merge request key");
  const parsed = contextSchema.safeParse(
    await run(CONTEXT_QUERY, { path: parts.projectPath, iid: parts.iid }),
  );
  const mr = parsed.success ? parsed.data.data.project?.mergeRequest : undefined;
  const owner = parsed.success ? parsed.data.data.currentUser : undefined;
  if (mr === null || mr === undefined || owner === null || owner === undefined) {
    throw new FetchFailure("gitlab-error", "merge request not found");
  }
  const people = [...(mr.author === null ? [] : [mr.author]), ...mr.reviewers.nodes];
  const recipient = people.find(
    (person) => person.username === request.to && person.username !== owner.username,
  );
  if (recipient === undefined) return undefined;
  return {
    owner,
    intent: {
      dedupeKey: `${MANUAL_PREFIX}${key}:${recipient.username}:${now}`,
      kind: kindOf(request.template),
      variant: request.template,
      mr: {
        key,
        iid: Number(parts.iid),
        projectPath: parts.projectPath,
        title: mr.title,
        url: mr.webUrl,
      },
      recipient,
    },
  };
}
