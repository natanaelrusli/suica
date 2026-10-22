import type { Exec } from "./exec.ts";
import { FetchFailure, fetchCurrentUsername, glabRest } from "./gitlab.ts";
import type { GitlabFailureKind } from "./gitlab.ts";

/** `suica gitlab check <host> --json`: whether glab can reach the host as a signed-in user. */

const CHECK_TIMEOUT_SECONDS = 30;
/** A host name with an optional port, as `glab --hostname` takes it; no scheme or path. */
const HOST_PATTERN = /^[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:\d{1,5})?$/i;

export type GitlabCheckStatus = "ok" | "bad-host" | GitlabFailureKind;

export interface GitlabCheckJson {
  readonly status: GitlabCheckStatus;
  /** The signed-in GitLab user, only with `ok`. */
  readonly username: string | null;
}

/** Needs no config file: a new user runs it before there is one, with glab from `PATH`. */
export async function checkGitlab(host: string, exec: Exec): Promise<GitlabCheckJson> {
  if (!HOST_PATTERN.test(host)) return { status: "bad-host", username: null };
  const gitlab = { hostname: host, glabPath: "glab", timeoutSeconds: CHECK_TIMEOUT_SECONDS };
  try {
    return { status: "ok", username: await fetchCurrentUsername(glabRest(gitlab, exec)) };
  } catch (error) {
    return { status: error instanceof FetchFailure ? error.kind : "gitlab-error", username: null };
  }
}
