import { lstatSync, readdirSync, readFileSync } from "node:fs";
import { isAbsolute, join, resolve, sep } from "node:path";

export interface ScopedRepo {
  readonly scope: string;
  readonly dir: string;
  readonly project: string; // "group/sub/project"
}

export interface ScopeMap {
  readonly repos: readonly ScopedRepo[];
}

export interface ScopeStat {
  readonly isDirectory: boolean;
  readonly isFile: boolean;
  readonly isSymlink: boolean;
}

/** The file-system calls the scan makes, so tests can substitute them. */
export interface ScopeFs {
  /** Entry names of a directory; throws when unreadable. */
  readdir(path: string): string[];
  /** Like lstat: a symlink reports isSymlink and neither of the others. */
  stat(path: string): ScopeStat | undefined;
  readFile(path: string): string | undefined;
}

export const nodeScopeFs: ScopeFs = {
  readdir: (path) => readdirSync(path),
  stat: (path) => {
    try {
      const s = lstatSync(path);
      return {
        isDirectory: s.isDirectory(),
        isFile: s.isFile(),
        isSymlink: s.isSymbolicLink(),
      };
    } catch {
      return undefined;
    }
  },
  readFile: (path) => {
    try {
      return readFileSync(path, "utf8");
    } catch {
      return undefined;
    }
  },
};

const MAX_DEPTH = 4;

export function projectOfMrKey(key: string): string {
  const bang = key.lastIndexOf("!");
  return bang < 0 ? key : key.slice(0, bang);
}

/** The "group/sub/project" of a remote URL on `hostname`; undefined for another host or no path. */
export function parseOrigin(url: string, hostname: string): string | undefined {
  const text = url.trim();
  let host: string;
  let path: string;
  const scheme = /^[a-z][a-z0-9+.-]*:\/\/([^/]*)\/(.*)$/i.exec(text);
  if (scheme) {
    const authority = scheme[1] ?? "";
    host = authority.slice(authority.lastIndexOf("@") + 1).replace(/:\d*$/, "");
    path = scheme[2] ?? "";
  } else {
    const scp = /^(?:[^@/\s]+@)?([^:/\s]+):(.*)$/.exec(text);
    if (!scp) return undefined;
    host = scp[1] ?? "";
    path = scp[2] ?? "";
  }
  if (host.toLowerCase() !== hostname.toLowerCase()) return undefined;
  const project = path
    .replace(/^\/+/, "")
    .replace(/\/+$/, "")
    .replace(/\.git$/, "")
    .replace(/\/+$/, "");
  return project === "" ? undefined : project;
}

function originUrl(config: string): string | undefined {
  let inOrigin = false;
  for (const raw of config.split(/\r?\n/)) {
    const line = raw.trim();
    if (line.startsWith("[")) {
      inOrigin = /^\[remote\s+"origin"\s*\]$/.test(line);
      continue;
    }
    if (!inOrigin) continue;
    const m = /^url\s*=\s*(.*)$/.exec(line);
    if (m) return (m[1] ?? "").trim();
  }
  return undefined;
}

/** The git dir that holds `config` for a repo whose `.git` is a file (a worktree). */
function mainGitDir(dir: string, gitFile: string, fs: ScopeFs): string | undefined {
  const m = /^gitdir:\s*(.+)$/m.exec(gitFile);
  if (!m) return undefined;
  const target = (m[1] ?? "").trim();
  const gitDir = isAbsolute(target) ? target : resolve(dir, target);
  const common = fs.readFile(join(gitDir, "commondir"))?.trim();
  if (common) return isAbsolute(common) ? common : resolve(gitDir, common);
  const marker = `${sep}worktrees${sep}`;
  const at = gitDir.lastIndexOf(marker);
  return at < 0 ? gitDir : gitDir.slice(0, at);
}

function projectOfRepo(dir: string, hostname: string, fs: ScopeFs): string | undefined {
  const dotGit = join(dir, ".git");
  const st = fs.stat(dotGit);
  if (!st) return undefined;
  let gitDir: string | undefined;
  if (st.isDirectory) gitDir = dotGit;
  else if (st.isFile) {
    const text = fs.readFile(dotGit);
    gitDir = text === undefined ? undefined : mainGitDir(dir, text, fs);
  }
  if (gitDir === undefined) return undefined;
  const config = fs.readFile(join(gitDir, "config"));
  const url = config === undefined ? undefined : originUrl(config);
  return url === undefined ? undefined : parseOrigin(url, hostname);
}

function walk(
  dir: string,
  depth: number,
  scope: string,
  hostname: string,
  fs: ScopeFs,
  out: Map<string, ScopedRepo>,
): void {
  if (fs.stat(join(dir, ".git"))) {
    const project = projectOfRepo(dir, hostname, fs);
    if (project !== undefined) out.set(dir, { scope, dir, project });
    return;
  }
  if (depth >= MAX_DEPTH) return;
  let names: string[];
  try {
    names = fs.readdir(dir);
  } catch {
    return;
  }
  for (const name of names.sort()) {
    if (name.startsWith(".") || name === "node_modules") continue;
    const child = join(dir, name);
    if (!fs.stat(child)?.isDirectory) continue;
    walk(child, depth + 1, scope, hostname, fs, out);
  }
}

export function scanScopes(
  scopes: readonly string[],
  hostname: string,
  fs: ScopeFs = nodeScopeFs,
): ScopeMap {
  const byDir = new Map<string, ScopedRepo>();
  for (const raw of scopes) {
    const scope = resolve(raw);
    if (!fs.stat(scope)?.isDirectory) continue;
    const found = new Map<string, ScopedRepo>();
    walk(scope, 0, scope, hostname, fs, found);
    for (const repo of found.values()) {
      const have = byDir.get(repo.dir);
      if (!have || repo.scope.length > have.scope.length) {
        byDir.set(repo.dir, repo);
      }
    }
  }
  return { repos: [...byDir.values()] };
}

export function scopeForProject(map: ScopeMap, project: string): ScopedRepo | undefined {
  return map.repos.find((r) => r.project === project);
}

export function repoForPath(map: ScopeMap, absolutePath: string): ScopedRepo | undefined {
  const path = resolve(absolutePath);
  let best: ScopedRepo | undefined;
  for (const repo of map.repos) {
    const inside = path === repo.dir || path.startsWith(repo.dir + sep);
    if (inside && (!best || repo.dir.length > best.dir.length)) best = repo;
  }
  return best;
}
