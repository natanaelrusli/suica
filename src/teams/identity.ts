import type { Person } from "../domain.ts";
import type { Store } from "../store.ts";
import type { TeamsApi } from "./api.ts";

export type Resolution =
  | { readonly kind: "resolved"; readonly email: string }
  | { readonly kind: "unresolved"; readonly reason: "no-match" | "ambiguous" };

export interface IdentityDeps {
  readonly api: Pick<TeamsApi, "searchUsers">;
  readonly store: Pick<Store, "loadIdentity" | "saveIdentity">;
  readonly people: Readonly<Record<string, string>>;
  readonly now: () => number;
}

const DELETED_USER = "ghost";

export function normalizeName(name: string): string {
  return name.normalize("NFKC").toLowerCase().replace(/\s+/g, " ").trim();
}

/**
 * GitLab gives a display name and an employee ID, never an email. Resolution order: the
 * `teams.people` map, the cache, then a Teams search accepted only when exactly one Teams user has
 * the same display name. A guess would send a message to the wrong person, so anything less
 * certain is "unresolved" and the Owner adds a line to `teams.people`.
 */
export async function resolveEmail(deps: IdentityDeps, person: Person): Promise<Resolution> {
  const mapped = deps.people[person.username];
  if (mapped !== undefined) return { kind: "resolved", email: mapped };
  const cached = deps.store.loadIdentity(person.username);
  if (cached !== undefined) return { kind: "resolved", email: cached };
  if (person.username === DELETED_USER) return { kind: "unresolved", reason: "no-match" };

  const wanted = normalizeName(person.name);
  const found = await deps.api.searchUsers(person.name);
  const matches = found.filter(
    (candidate) =>
      candidate.displayName !== null && normalizeName(candidate.displayName) === wanted,
  );
  const ids = new Set(matches.map((candidate) => candidate.id));
  const [only] = matches;
  if (ids.size === 0 || only === undefined) return { kind: "unresolved", reason: "no-match" };
  if (ids.size > 1) return { kind: "unresolved", reason: "ambiguous" };
  const email = only.mail ?? only.userPrincipalName;
  deps.store.saveIdentity(person.username, email, deps.now());
  return { kind: "resolved", email };
}
