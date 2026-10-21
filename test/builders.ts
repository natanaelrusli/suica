import type { MergeRequest, Note, Person, Reviewer, Snapshot } from "../src/domain.ts";
import type { PreviousState } from "../src/events.ts";

export const ME: Person = { username: "me", name: "Nata" };

export function person(username: string, name = username): Person {
  return { username, name };
}

export function reviewer(username: string, state: string, name = username): Reviewer {
  return { username, name, state };
}

export function note(id: string, author: Person, system = false): Note {
  return { id, system, author };
}

export function mr(
  iid: number,
  overrides: Partial<Omit<MergeRequest, "iid" | "key">> = {},
): MergeRequest {
  const projectPath = overrides.projectPath ?? "g/p";
  return {
    key: `${projectPath}!${iid}`,
    projectPath,
    iid,
    title: `MR ${iid}`,
    url: `https://gitlab.example/${projectPath}/-/merge_requests/${iid}`,
    draft: false,
    createdAt: null,
    headSha: `sha-${iid}-a`,
    descriptionSha: null,
    author: person("author", "Author"),
    reviewers: [],
    notes: [],
    pipeline: null,
    ...overrides,
  };
}

export function snapshot(
  parts: { reviewRequested?: MergeRequest[]; authored?: MergeRequest[] } = {},
): Snapshot {
  return { me: ME, reviewRequested: parts.reviewRequested ?? [], authored: parts.authored ?? [] };
}

export function previous(overrides: Partial<PreviousState> = {}): PreviousState {
  return {
    baselineDone: true,
    trackedAuthored: new Set(),
    myReviewStates: new Map(),
    reviewerStates: new Map(),
    seenNotes: new Set(),
    ...overrides,
  };
}
