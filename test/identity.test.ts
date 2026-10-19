import { describe, expect, it } from "vitest";
import { TeamsFailure } from "../src/teams/api.ts";
import type { TeamsUser } from "../src/teams/api.ts";
import { normalizeName, resolveEmail } from "../src/teams/identity.ts";
import type { IdentityDeps } from "../src/teams/identity.ts";
import { openStore } from "../src/store.ts";
import { person } from "./builders.ts";

const user = (
  displayName: string | null,
  id: string,
  mail: string | null = `${id}@x.id`,
): TeamsUser => ({
  displayName,
  userPrincipalName: `${id}@upn.x.id`,
  mail,
  id,
});

function setup(
  options: { found?: TeamsUser[]; people?: Record<string, string>; fail?: Error } = {},
) {
  const store = openStore(":memory:");
  const queries: string[] = [];
  const deps: IdentityDeps = {
    api: {
      searchUsers: (query) => {
        queries.push(query);
        return options.fail === undefined
          ? Promise.resolve(options.found ?? [])
          : Promise.reject(options.fail);
      },
    },
    store,
    people: options.people ?? {},
    now: () => 1000,
  };
  return { deps, store, queries };
}

describe("normalizeName", () => {
  it("ignores case, repeated spaces, accents composition and surrounding whitespace", () => {
    expect(normalizeName("  Rayhan   ASWIANSYAH ")).toBe("rayhan aswiansyah");
    expect(normalizeName("José")).toBe(normalizeName("José"));
  });
});

describe("resolveEmail", () => {
  it("prefers the people map and never searches", async () => {
    const { deps, queries } = setup({ people: { "20435": "rayhan@madhani.id" } });
    await expect(resolveEmail(deps, person("20435", "Rayhan"))).resolves.toEqual({
      kind: "resolved",
      email: "rayhan@madhani.id",
    });
    expect(queries).toEqual([]);
  });

  it("uses the cache before searching", async () => {
    const { deps, store, queries } = setup();
    store.saveIdentity("20435", "cached@madhani.id", 1);
    await expect(resolveEmail(deps, person("20435", "Rayhan"))).resolves.toEqual({
      kind: "resolved",
      email: "cached@madhani.id",
    });
    expect(queries).toEqual([]);
  });

  it("accepts exactly one exact display-name match and caches it", async () => {
    const { deps, store } = setup({ found: [user("Rayhan Aswiansyah", "u1")] });
    await expect(resolveEmail(deps, person("20435", "rayhan  aswiansyah"))).resolves.toEqual({
      kind: "resolved",
      email: "u1@x.id",
    });
    expect(store.loadIdentity("20435")).toBe("u1@x.id");
  });

  it("accepts one Teams name that adds whole words after the GitLab name, and caches it", async () => {
    const { deps, store } = setup({ found: [user("Mufid Hadi Abdulhakim", "u1")] });
    await expect(resolveEmail(deps, person("20400", "Mufid Hadi"))).resolves.toEqual({
      kind: "resolved",
      email: "u1@x.id",
    });
    expect(store.loadIdentity("20400")).toBe("u1@x.id");
  });

  it("prefers the exact name over longer ones", async () => {
    const { deps } = setup({
      found: [user("Budi Santoso Putra", "u1"), user("Budi Santoso", "u2")],
    });
    await expect(resolveEmail(deps, person("1", "Budi Santoso"))).resolves.toEqual({
      kind: "resolved",
      email: "u2@x.id",
    });
  });

  it("refuses two different people whose names both start with the GitLab name", async () => {
    const { deps, store } = setup({
      found: [user("Budi Santoso Putra", "u1"), user("Budi Santoso Wijaya", "u2")],
    });
    await expect(resolveEmail(deps, person("1", "Budi Santoso"))).resolves.toEqual({
      kind: "unresolved",
      reason: "ambiguous",
    });
    expect(store.loadIdentity("1")).toBeUndefined();
  });

  it("does not accept a name that only starts with the same letters", async () => {
    const { deps } = setup({ found: [user("Adinda Putri", "u1")] });
    await expect(resolveEmail(deps, person("1", "Adi"))).resolves.toEqual({
      kind: "unresolved",
      reason: "no-match",
    });
  });

  it("refuses two different people with the same display name", async () => {
    const { deps } = setup({ found: [user("Budi Santoso", "u1"), user("Budi  Santoso", "u2")] });
    await expect(resolveEmail(deps, person("1", "Budi Santoso"))).resolves.toEqual({
      kind: "unresolved",
      reason: "ambiguous",
    });
  });

  it("falls back to the user principal name when there is no mail", async () => {
    const { deps } = setup({ found: [user("Siti", "u3", null)] });
    await expect(resolveEmail(deps, person("1", "Siti"))).resolves.toEqual({
      kind: "resolved",
      email: "u3@upn.x.id",
    });
  });

  it("skips users without a display name and never searches for a deleted GitLab user", async () => {
    const { deps, queries } = setup({ found: [user(null, "u4")] });
    await expect(resolveEmail(deps, person("1", "Siti"))).resolves.toMatchObject({
      reason: "no-match",
    });
    await expect(resolveEmail(deps, person("ghost", "(unknown user)"))).resolves.toMatchObject({
      reason: "no-match",
    });
    expect(queries).toEqual(["Siti"]);
  });

  it("lets a failing search surface so the message can wait", async () => {
    const { deps } = setup({ fail: new TeamsFailure("unavailable", "down") });
    await expect(resolveEmail(deps, person("1", "Siti"))).rejects.toMatchObject({
      kind: "unavailable",
    });
  });
});
