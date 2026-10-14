/** GitLab reviewer state. Observed values: UNREVIEWED, APPROVED, UNAPPROVED; others may exist. */
export type ReviewState = string;

export const UNREVIEWED: ReviewState = "UNREVIEWED";

export interface Person {
  readonly username: string;
  readonly name: string;
}

export interface Reviewer extends Person {
  readonly state: ReviewState;
}

export interface Note {
  readonly id: string;
  readonly system: boolean;
  readonly author: Person;
}

export interface MergeRequest {
  /** `<project path>!<iid>`, stable and safe to log. */
  readonly key: string;
  readonly projectPath: string;
  readonly iid: number;
  readonly title: string;
  readonly url: string;
  readonly draft: boolean;
  readonly author: Person;
  readonly reviewers: readonly Reviewer[];
  /** Most recent notes only; empty for MRs fetched without notes. */
  readonly notes: readonly Note[];
}

export interface Snapshot {
  readonly me: Person;
  /** Open MRs where the Owner is a Reviewer. */
  readonly reviewRequested: readonly MergeRequest[];
  /** Open MRs the Owner authored. */
  readonly authored: readonly MergeRequest[];
}
