import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  parseOrigin,
  projectOfMrKey,
  repoForPath,
  scanScopes,
  scopeForProject,
} from "../src/lessons/scopes.js";

const HOST = "repo.madhani.one";
let root: string;

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "suica-scopes-"));
});
afterEach(() => {
  rmSync(root, { recursive: true, force: true });
});

function repo(rel: string, project: string | undefined, host = HOST): string {
  const dir = join(root, rel);
  mkdirSync(join(dir, ".git"), { recursive: true });
  const config =
    project === undefined
      ? "[core]\n\tbare = false\n"
      : `[core]\n\tbare = false\n[remote "origin"]\n\turl = git@${host}:${project}.git\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n`;
  writeFileSync(join(dir, ".git", "config"), config);
  return dir;
}

describe("scanScopes", () => {
  it("a parent scope finds every repo below it", () => {
    const a = repo("work/a", "g/a");
    const b = repo("work/team/b", "g/sub/b");
    const map = scanScopes([join(root, "work")], HOST);
    expect(map.repos.map((r) => [r.dir, r.project, r.scope]).sort()).toEqual(
      [
        [a, "g/a", join(root, "work")],
        [b, "g/sub/b", join(root, "work")],
      ].sort(),
    );
  });

  it("a scope that is a repo is one repo", () => {
    const a = repo("solo", "g/solo");
    repo("solo/inner", "g/inner");
    const map = scanScopes([a], HOST);
    expect(map.repos).toEqual([{ scope: a, dir: a, project: "g/solo" }]);
  });

  it("node_modules and nested worktrees are skipped", () => {
    repo("work/a", "g/a");
    repo("work/a/node_modules/x", "g/x");
    repo("work/node_modules/y", "g/y");
    repo("work/.claude/worktrees/w", "g/w");
    const map = scanScopes([join(root, "work")], HOST);
    expect(map.repos.map((r) => r.project)).toEqual(["g/a"]);
  });

  it("a repo under two scopes belongs to the deeper one", () => {
    const a = repo("work/team/a", "g/a");
    const map = scanScopes([join(root, "work"), join(root, "work/team")], HOST);
    expect(map.repos).toEqual([{ scope: join(root, "work/team"), dir: a, project: "g/a" }]);
    const reversed = scanScopes([join(root, "work/team"), join(root, "work")], HOST);
    expect(reversed.repos[0]?.scope).toBe(join(root, "work/team"));
  });

  it("skips a repo without an origin but keeps scanning", () => {
    repo("work/none", undefined);
    repo("work/b", "g/b");
    const map = scanScopes([join(root, "work")], HOST);
    expect(map.repos.map((r) => r.project)).toEqual(["g/b"]);
  });

  it("skips a repo whose origin is on another host", () => {
    repo("work/gh", "x/y", "github.com");
    expect(scanScopes([join(root, "work")], HOST).repos).toEqual([]);
  });

  it("respects the depth cap of 4", () => {
    repo("work/1/2/3/4", "g/ok");
    repo("work/1/2/3/4/5", "g/too-deep");
    repo("work/1/2/3/4x/5", "g/too-deep2");
    const map = scanScopes([join(root, "work")], HOST);
    expect(map.repos.map((r) => r.project)).toEqual(["g/ok"]);
  });

  it("does not follow symlinks or enter hidden directories", () => {
    repo("outside/o", "g/o");
    repo("work/.hidden/h", "g/h");
    repo("work/real", "g/real");
    symlinkSync(join(root, "outside"), join(root, "work/link"));
    const map = scanScopes([join(root, "work")], HOST);
    expect(map.repos.map((r) => r.project)).toEqual(["g/real"]);
  });

  it("a scope that does not exist yields no repos", () => {
    expect(scanScopes([join(root, "missing")], HOST).repos).toEqual([]);
  });

  it("skips unreadable directories silently", () => {
    repo("work/ok", "g/ok");
    const locked = join(root, "work/locked");
    mkdirSync(locked);
    chmodSync(locked, 0o000);
    try {
      const map = scanScopes([join(root, "work")], HOST);
      expect(map.repos.map((r) => r.project)).toEqual(["g/ok"]);
    } finally {
      chmodSync(locked, 0o755);
    }
  });

  it("follows a worktree .git file to the main repo config via commondir", () => {
    const main = repo("work/main", "g/main");
    const gitdir = join(main, ".git/worktrees/wt");
    mkdirSync(gitdir, { recursive: true });
    writeFileSync(join(gitdir, "commondir"), "../..\n");
    const wt = join(root, "work/wt");
    mkdirSync(wt);
    writeFileSync(join(wt, ".git"), `gitdir: ${gitdir}\n`);
    const map = scanScopes([join(root, "work")], HOST);
    expect(map.repos.map((r) => [r.dir, r.project]).sort()).toEqual(
      [
        [main, "g/main"],
        [wt, "g/main"],
      ].sort(),
    );
  });

  it("follows a worktree .git file without commondir by stripping /worktrees/<name>", () => {
    const main = repo("work/main", "g/main");
    const gitdir = join(main, ".git/worktrees/wt");
    mkdirSync(gitdir, { recursive: true });
    const wt = join(root, "work/wt");
    mkdirSync(wt);
    writeFileSync(join(wt, ".git"), `gitdir: ${gitdir}`);
    const map = scanScopes([wt], HOST);
    expect(map.repos).toEqual([{ scope: wt, dir: wt, project: "g/main" }]);
  });
});

describe("parseOrigin", () => {
  it("reads ssh and https remotes of the configured host", () => {
    expect(parseOrigin("git@repo.madhani.one:g/p.git", HOST)).toBe("g/p");
    expect(parseOrigin("https://repo.madhani.one/g/sub/p.git", HOST)).toBe("g/sub/p");
    expect(parseOrigin("git@github.com:x/y.git", HOST)).toBeUndefined();
  });

  it("is tolerant of ssh:// with port, no .git, trailing slash and credentials", () => {
    expect(parseOrigin("ssh://git@repo.madhani.one:2222/group/p.git", HOST)).toBe("group/p");
    expect(parseOrigin("ssh://git@repo.madhani.one/group/p", HOST)).toBe("group/p");
    expect(parseOrigin("https://repo.madhani.one/group/p/", HOST)).toBe("group/p");
    expect(parseOrigin("https://repo.madhani.one/group/p.git/", HOST)).toBe("group/p");
    expect(parseOrigin("https://u:tok@repo.madhani.one:8443/g/p.git", HOST)).toBe("g/p");
    expect(parseOrigin("git@REPO.madhani.one:g/p.git", HOST)).toBe("g/p");
    expect(parseOrigin("  https://repo.madhani.one/g/p.git\n", HOST)).toBe("g/p");
  });

  it("rejects empty paths and garbage", () => {
    expect(parseOrigin("", HOST)).toBeUndefined();
    expect(parseOrigin("https://repo.madhani.one/", HOST)).toBeUndefined();
    expect(parseOrigin("/local/path/repo", HOST)).toBeUndefined();
  });
});

describe("lookups", () => {
  it("projectOfMrKey drops the iid", () => {
    expect(projectOfMrKey("g/sub/p!7")).toBe("g/sub/p");
    expect(projectOfMrKey("g/p")).toBe("g/p");
  });

  it("scopeForProject compares case-sensitively", () => {
    repo("work/a", "g/a");
    const map = scanScopes([join(root, "work")], HOST);
    expect(scopeForProject(map, "g/a")?.dir).toBe(join(root, "work/a"));
    expect(scopeForProject(map, "G/a")).toBeUndefined();
    expect(scopeForProject(map, "g/zzz")).toBeUndefined();
  });

  it("repoForPath picks the deepest repo containing the file", () => {
    const outer = repo("work/outer", "g/outer");
    const inner = repo("work/outer/vendor/inner", "g/inner");
    const map = scanScopes([outer], HOST);
    // the scope itself is a repo, so build a map with both explicitly
    const both = {
      repos: [
        { scope: join(root, "work"), dir: outer, project: "g/outer" },
        { scope: join(root, "work"), dir: inner, project: "g/inner" },
      ],
    };
    expect(map.repos).toHaveLength(1);
    expect(repoForPath(both, join(inner, "src/x.ts"))?.project).toBe("g/inner");
    expect(repoForPath(both, join(outer, "src/x.ts"))?.project).toBe("g/outer");
    expect(repoForPath(both, join(outer, "vendor/innerish/x.ts"))?.project).toBe("g/outer");
    expect(repoForPath(both, join(root, "elsewhere/x.ts"))).toBeUndefined();
  });
});
