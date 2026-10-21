/** GitLab reviewer state. Observed values: UNREVIEWED, APPROVED, UNAPPROVED; others may exist. */
export type ReviewState = string;

export const UNREVIEWED: ReviewState = "UNREVIEWED";
export const APPROVED: ReviewState = "APPROVED";

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

/** An MR's head pipeline. */
export interface Pipeline {
  /** GitLab's per-project pipeline number, as text. */
  readonly iid: string;
  /** GitLab's status: SUCCESS, FAILED, RUNNING, PENDING, CANCELED, SKIPPED, MANUAL, … */
  readonly status: string;
  readonly url: string;
}

export const PIPELINE_FAILED = "FAILED";

export interface MergeRequest {
  /** `<project path>!<iid>`, stable and safe to log. */
  readonly key: string;
  readonly projectPath: string;
  readonly iid: number;
  readonly title: string;
  readonly url: string;
  readonly draft: boolean;
  /** ISO 8601 as GitLab sends it; null when it was not fetched. */
  readonly createdAt: string | null;
  /** The head commit of the source branch; null while GitLab has not computed it. */
  readonly headSha: string | null;
  /** SHA-256 of the description, so a change to it is noticed; null when not fetched. */
  readonly descriptionSha: string | null;
  readonly author: Person;
  readonly reviewers: readonly Reviewer[];
  /** Most recent notes only; empty for MRs fetched without notes. */
  readonly notes: readonly Note[];
  /** Null when the MR has no pipeline. */
  readonly pipeline: Pipeline | null;
}

export interface Snapshot {
  readonly me: Person;
  /** Open MRs where the Owner is a Reviewer. */
  readonly reviewRequested: readonly MergeRequest[];
  /** Open MRs the Owner authored. */
  readonly authored: readonly MergeRequest[];
}
