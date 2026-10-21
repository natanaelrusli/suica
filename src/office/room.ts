import { readFileSync, realpathSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

function real(path: string): string {
  try {
    return realpathSync(path);
  } catch {
    return resolve(path);
  }
}

/** The repository root a `.git` entry in `dir` stands for, or undefined when there is none. */
function rootOf(dir: string): string | undefined {
  const marker = join(dir, ".git");
  let stat;
  try {
    stat = statSync(marker);
  } catch {
    return undefined;
  }
  if (stat.isDirectory()) return dir;
  let text: string;
  try {
    text = readFileSync(marker, "utf8");
  } catch {
    return dir;
  }
  const gitdir = /^gitdir:\s*(.+)$/m.exec(text)?.[1]?.trim();
  if (gitdir === undefined) return dir;
  // A linked worktree's gitdir is <repo>/.git/worktrees/<name>; a submodule's is not.
  const target = resolve(dir, gitdir);
  const at = target.indexOf("/.git/worktrees/");
  return at === -1 ? dir : real(target.slice(0, at));
}

/**
 * A Session's Room: the git repository root of its working folder, the main repository for a
 * linked worktree, else the folder itself. The home folder's own repository (dotfiles) is never a
 * Room for the projects under it.
 */
export function roomFor(cwd: string, home: string): string {
  const start = real(cwd);
  const realHome = real(home);
  let dir = start;
  for (;;) {
    if (dir !== realHome || start === realHome) {
      const root = rootOf(dir);
      if (root !== undefined) return root;
    }
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  // A removed Claude worktree folder no longer has a .git file to follow.
  const marker = "/.claude/worktrees/";
  const at = start.indexOf(marker);
  return at > 0 ? start.slice(0, at) : start;
}
