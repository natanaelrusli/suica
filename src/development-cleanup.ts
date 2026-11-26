import { execFileSync } from "node:child_process";
import { existsSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join, resolve } from "node:path";

export interface PortListener {
  readonly pid: number;
  readonly owner: string;
  readonly program: string;
  readonly protected: boolean;
  readonly cwd: string | null;
  readonly startedAt: string | null;
  readonly command: string | null;
  readonly endpoints: readonly string[];
  readonly ports: readonly string[];
}

export interface PortScan {
  readonly version: 1;
  readonly status: "ok" | "partial" | "failed";
  readonly error: string | null;
  readonly listeners: readonly PortListener[];
}

type Command = (file: string, args: readonly string[]) => string;
const systemCommand: Command = (file, args) =>
  execFileSync(file, [...args], { encoding: "utf8", timeout: 10_000, maxBuffer: 16 * 1024 * 1024 });

function parseLsof(text: string): Array<{
  pid: number;
  owner: string;
  program: string;
  ports: Set<string>;
  endpoints: Set<string>;
}> {
  const rows: Array<{
    pid: number;
    owner: string;
    program: string;
    ports: Set<string>;
    endpoints: Set<string>;
  }> = [];
  let current: (typeof rows)[number] | undefined;
  for (const line of text.split("\n")) {
    const tag = line[0];
    const value = line.slice(1);
    if (tag === "p") {
      if (current) rows.push(current);
      current = {
        pid: Number(value),
        owner: "",
        program: "",
        ports: new Set(),
        endpoints: new Set(),
      };
    } else if (current && tag === "c") current.program = value;
    else if (current && tag === "u") current.owner = value;
    // The lsof query is already filtered to TCP listeners; field order is not fixed.
    else if (current && tag === "n") {
      const port = /:(\d+)$/.exec(value)?.[1];
      if (port) {
        current.ports.add(port);
        current.endpoints.add(value);
      }
    }
  }
  if (current) rows.push(current);
  return rows.filter((row) => row.pid > 0 && row.ports.size > 0);
}

function processStart(command: Command, pid: number): string | null {
  try {
    return command("ps", ["-p", String(pid), "-o", "lstart="]).trim() || null;
  } catch {
    return null;
  }
}

function processCommandLine(command: Command, pid: number): string | null {
  try {
    return command("ps", ["-p", String(pid), "-o", "command="]).trim() || null;
  } catch {
    return null;
  }
}

function processCwd(command: Command, pid: number): string | null {
  try {
    return (
      command("lsof", ["-a", "-d", "cwd", "-p", String(pid), "-Fn"])
        .split("\n")
        .find((line) => line.startsWith("n"))
        ?.slice(1) ?? null
    );
  } catch {
    return null;
  }
}

export function scanPorts(command: Command = systemCommand): PortScan {
  let raw: string;
  let partial = false;
  try {
    raw = command("lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-FpcunT"]);
  } catch (error) {
    const stdout =
      typeof error === "object" && error !== null && "stdout" in error ? String(error.stdout) : "";
    const status =
      typeof error === "object" && error !== null && "status" in error ? error.status : null;
    if (!stdout && status === 1) return { version: 1, status: "ok", error: null, listeners: [] };
    if (!stdout) return { version: 1, status: "failed", error: String(error), listeners: [] };
    raw = stdout;
    partial = true;
  }
  const rows = parseLsof(raw);
  const commands = new Map(rows.map((row) => [row.pid, processCommandLine(command, row.pid)]));
  const listeners = rows.map((row) => ({
    pid: row.pid,
    owner: row.owner,
    program: row.program,
    protected:
      /Suica\.app\/|\/suica\/src\/(?:main|cli)\.ts(?:\s|$)/i.test(commands.get(row.pid) ?? "") ||
      row.program.toLowerCase().includes("suica"),
    cwd: processCwd(command, row.pid),
    startedAt: processStart(command, row.pid),
    command: commands.get(row.pid) ?? null,
    endpoints: [...row.endpoints].sort(),
    ports: [...row.ports].sort((a, b) => Number(a) - Number(b)),
  }));
  if (
    rows.some((row) => !row.owner || !row.program) ||
    listeners.some((row) => row.startedAt === null || row.cwd === null) ||
    [...commands.values()].some((line) => line === null)
  )
    partial = true;
  return {
    version: 1,
    status: partial ? "partial" : "ok",
    error: partial ? "Some listener details could not be read." : null,
    listeners,
  };
}

export type StopResult = {
  version: 1;
  status:
    | "stopped"
    | "still-running"
    | "permission-denied"
    | "port-reopened"
    | "identity-changed"
    | "protected"
    | "not-found";
  message: string;
};

export async function stopPortProcess(
  input: { pid: number; startedAt: string; ports: readonly string[]; force?: boolean },
  options: {
    scan?: () => PortScan;
    kill?: (pid: number, signal: NodeJS.Signals) => void;
    wait?: (ms: number) => Promise<void>;
    suicaPids?: readonly number[];
  } = {},
): Promise<StopResult> {
  const scan = options.scan ?? scanPorts;
  const kill = options.kill ?? ((pid, signal) => process.kill(pid, signal));
  const wait = options.wait ?? ((ms) => new Promise((resolveWait) => setTimeout(resolveWait, ms)));
  if (options.suicaPids?.includes(input.pid))
    return { version: 1, status: "protected", message: "Suica processes are protected." };
  const current = scan();
  const processRow = current.listeners.find((row) => row.pid === input.pid);
  const requestedPorts = [...input.ports].sort((a, b) => Number(a) - Number(b));
  const currentPorts = processRow
    ? [...processRow.ports].sort((a, b) => Number(a) - Number(b))
    : [];
  if (
    (current.status !== "ok" && current.status !== "partial") ||
    !processRow ||
    processRow.protected ||
    !processRow.owner ||
    !processRow.program ||
    !processRow.cwd ||
    !processRow.startedAt ||
    processRow.startedAt !== input.startedAt ||
    processRow.owner !== String(process.getuid?.() ?? "") ||
    requestedPorts.length === 0 ||
    new Set(requestedPorts).size !== requestedPorts.length ||
    requestedPorts.some((port) => !/^\d{1,5}$/.test(port)) ||
    requestedPorts.join(",") !== currentPorts.join(",")
  )
    return {
      version: 1,
      status: "identity-changed",
      message: "The selected process or listener changed. Refresh and select it again.",
    };
  if (!Number.isSafeInteger(input.pid) || input.pid < 2 || !input.startedAt)
    return {
      version: 1,
      status: "identity-changed",
      message: "The selected process identity or port list is invalid.",
    };
  const signal = input.force ? "SIGKILL" : "SIGTERM";
  try {
    kill(input.pid, signal);
  } catch (error) {
    const code = typeof error === "object" && error !== null && "code" in error ? error.code : "";
    return {
      version: 1,
      status: code === "EPERM" || code === "EACCES" ? "permission-denied" : "not-found",
      message: String(error),
    };
  }
  await wait(1_000);
  const after = scan();
  if (after.status !== "ok")
    return {
      version: 1,
      status: "still-running",
      message: "The process was signalled, but listener state could not be confirmed.",
    };
  if (after.listeners.some((row) => row.pid === input.pid && row.startedAt === input.startedAt))
    return {
      version: 1,
      status: "still-running",
      message: `The listener is still running after ${signal}.`,
    };
  if (requestedPorts.some((port) => after.listeners.some((row) => row.ports.includes(port))))
    return {
      version: 1,
      status: "port-reopened",
      message: "The selected process stopped, but another process reopened a selected port.",
    };
  return {
    version: 1,
    status: "stopped",
    message: "The process stopped and the selected ports are clear.",
  };
}

function git(cwd: string, args: readonly string[]): string {
  return execFileSync("git", [...args], {
    cwd,
    encoding: "utf8",
    timeout: 30_000,
    maxBuffer: 16 * 1024 * 1024,
  });
}
function commonDir(repo: string): string {
  return resolve(repo, git(repo, ["rev-parse", "--git-common-dir"]).trim());
}
type WorktreeRow = {
  path: string;
  head: string;
  branch: string | null;
  locked: boolean;
  detached: boolean;
  prunable: boolean;
};
function worktreeRows(repo: string): WorktreeRow[] {
  const raw = execFileSync("git", ["worktree", "list", "--porcelain", "-z"], {
    cwd: repo,
    encoding: "utf8",
    timeout: 30_000,
  });
  return raw
    .split("\0")
    .filter(Boolean)
    .reduce<WorktreeRow[]>((rows, field) => {
      if (field.startsWith("worktree "))
        rows.push({
          path: field.slice(9),
          head: "",
          branch: null,
          locked: false,
          detached: false,
          prunable: false,
        });
      else {
        const row = rows.at(-1);
        if (!row) return rows;
        if (field.startsWith("HEAD ")) row.head = field.slice(5);
        else if (field.startsWith("branch "))
          row.branch = field.slice(7).replace(/^refs\/heads\//, "");
        else if (field === "locked" || field.startsWith("locked ")) row.locked = true;
        else if (field === "detached") row.detached = true;
        else if (field === "prunable" || field.startsWith("prunable ")) row.prunable = true;
      }
      return rows;
    }, []);
}

function resolveTargetRef(repo: string, target: string): string {
  const candidates =
    target.startsWith("refs/heads/") || target.startsWith("refs/remotes/")
      ? [target].filter((ref) => ref.startsWith("refs/heads/") || ref.startsWith("refs/remotes/"))
      : [`refs/heads/${target}`, `refs/remotes/${target}`];
  for (const ref of candidates) {
    try {
      git(repo, ["check-ref-format", ref]);
      git(repo, ["show-ref", "--verify", "--quiet", ref]);
      return ref;
    } catch {
      /* Try the other concrete branch namespace. */
    }
  }
  throw new Error("Target must be an existing local or remote branch ref.");
}

export interface WorktreeEntry {
  path: string;
  head: string;
  branch: string | null;
  target: string;
  targetCommit: string | null;
  status: "merged" | "unmerged" | "ineligible" | "unverified" | "prunable";
  reason: string | null;
  ignoredOutput: string[];
}
export function fetchWorktreeTarget(
  repo: string,
  target: string,
): {
  version: 1;
  status: "fetched" | "failed";
  target: string;
  targetCommit: string | null;
  refreshedAt: string;
  error: string | null;
} {
  try {
    const ref = resolveTargetRef(resolve(repo), target);
    if (!ref.startsWith("refs/remotes/"))
      throw new Error("Select a remote tracking branch before fetching.");
    const remote = ref.slice("refs/remotes/".length).split("/")[0] ?? "";
    git(resolve(repo), ["fetch", remote]);
    return {
      version: 1,
      status: "fetched",
      target,
      targetCommit: git(resolve(repo), ["rev-parse", "--verify", `${ref}^{commit}`]).trim(),
      refreshedAt: new Date().toISOString(),
      error: null,
    };
  } catch (error) {
    return {
      version: 1,
      status: "failed",
      target,
      targetCommit: null,
      refreshedAt: new Date().toISOString(),
      error: String(error),
    };
  }
}
// Regenerable build output that may be discarded with a merged checkout; anything else ignored (.env, local data) blocks removal.
const DISPOSABLE_IGNORED = new Set([
  "node_modules",
  "dist",
  "build",
  "out",
  ".next",
  ".nuxt",
  ".turbo",
  ".cache",
  ".parcel-cache",
  ".vite",
  "coverage",
  "target",
  ".build",
  "__pycache__",
  ".pytest_cache",
  ".DS_Store",
  "test-results",
  "playwright-report",
  "storybook-static",
  "next-env.d.ts",
  ".eslintcache",
]);
const isDisposable = (part: string) =>
  DISPOSABLE_IGNORED.has(part) || /^dist-[\w-]+$/.test(part) || part.endsWith(".tsbuildinfo");
export function inspectWorktrees(
  repoInput: string,
  targetInput?: string,
): {
  version: 1;
  status: "ok" | "failed";
  commonDir: string | null;
  defaultTarget: string | null;
  targetRef: string | null;
  entries: WorktreeEntry[];
  error: string | null;
} {
  try {
    const repo = resolve(repoInput);
    const common = commonDir(repo);
    let defaultTarget = "";
    try {
      defaultTarget = git(repo, ["symbolic-ref", "-q", "refs/remotes/origin/HEAD"])
        .trim()
        .replace(/^refs\/remotes\//, "");
    } catch {
      /* No remote default is available. */
    }
    const rows = worktreeRows(repo);
    const target =
      targetInput ||
      defaultTarget ||
      rows[0]?.branch ||
      git(repo, ["symbolic-ref", "--short", "HEAD"]).trim();
    const targetRef = resolveTargetRef(repo, target);
    const targetCommit = git(repo, ["rev-parse", "--verify", `${targetRef}^{commit}`]).trim();
    const entries = rows.map((row, index): WorktreeEntry => {
      const isMain = index === 0;
      if (row.prunable)
        return {
          path: row.path,
          head: row.head,
          branch: row.branch,
          target,
          targetCommit,
          status: "prunable",
          reason: "Folder is missing; prune to drop the stale Git entry.",
          ignoredOutput: [],
        };
      const protectedReason = isMain
        ? "Main checkout is protected."
        : row.locked
          ? "Worktree is locked."
          : row.detached
            ? "Detached worktree is protected."
            : null;
      if (protectedReason)
        return {
          path: row.path,
          head: row.head,
          branch: row.branch,
          target,
          targetCommit,
          status: "ineligible",
          reason: protectedReason,
          ignoredOutput: [],
        };
      let reason: string | null = null;
      let status: string;
      // "matching" lists ignored folders such as node_modules/ as one line without walking them (about 30x faster).
      try {
        status = git(row.path, ["status", "--porcelain", "--ignored=matching"]);
      } catch (error) {
        return {
          path: row.path,
          head: row.head,
          branch: row.branch,
          target,
          targetCommit,
          status: "ineligible",
          reason: `Could not verify checkout contents: ${String(error)}`,
          ignoredOutput: [],
        };
      }
      // These markers are all per-worktree, so they live directly in the worktree's own Git directory.
      const gitDir = resolve(row.path, git(row.path, ["rev-parse", "--git-dir"]).trim());
      if (!reason) {
        const unfinished = [
          "MERGE_HEAD",
          "REBASE_HEAD",
          "CHERRY_PICK_HEAD",
          "REVERT_HEAD",
          "BISECT_LOG",
          "rebase-apply",
          "rebase-merge",
          "sequencer",
        ].find((name) => existsSync(join(gitDir, name)));
        if (unfinished) reason = `Git operation is unfinished (${unfinished}).`;
      }
      const ignoredOutput = status
        .split("\n")
        .filter((line) => line.startsWith("!! "))
        .map((line) => line.slice(3));
      const modified = status.split("\n").filter((line) => line && !line.startsWith("!! "));
      // Judge each reported entry by its own name: an ignored .env inside a tracked build/ folder still blocks.
      const unknownIgnored = ignoredOutput.filter(
        (path) => !isDisposable(path.replace(/\/$/, "").split("/").at(-1) ?? ""),
      );
      if (!reason && modified.length) reason = "Modified or untracked files are present.";
      if (!reason && unknownIgnored.length)
        reason = `Unclassified ignored files: ${unknownIgnored.slice(0, 5).join(", ")}${unknownIgnored.length > 5 ? ` and ${unknownIgnored.length - 5} more` : ""}`;
      if (!reason && row.branch === null) reason = "No linked branch is available.";
      if (!reason && row.branch && targetRef === `refs/heads/${row.branch}`)
        reason = "Target is the candidate branch.";
      let merged = false;
      if (!reason) {
        try {
          git(repo, ["merge-base", "--is-ancestor", row.head, targetCommit]);
          merged = true;
        } catch {
          merged = false;
        }
      }
      if (!reason && !merged)
        reason =
          "No ancestry evidence confirms this checkout is merged; squash and rebase merges remain unverified.";
      return {
        path: row.path,
        head: row.head,
        branch: row.branch,
        target,
        targetCommit,
        status: reason
          ? reason.startsWith("No ancestry evidence")
            ? "unverified"
            : "ineligible"
          : "merged",
        reason,
        ignoredOutput,
      };
    });
    return {
      version: 1,
      status: "ok",
      commonDir: common,
      defaultTarget: defaultTarget || null,
      targetRef,
      entries,
      error: null,
    };
  } catch (error) {
    return {
      version: 1,
      status: "failed",
      commonDir: null,
      defaultTarget: null,
      targetRef: null,
      entries: [],
      error: String(error),
    };
  }
}

export function removeWorktree(
  input: {
    repo: string;
    path: string;
    target: string;
    targetCommit: string;
    previewBranch: string;
    previewHead: string;
    refreshedAt?: string;
  },
  options: {
    activeFiles?: (path: string) => "active" | "none" | "unknown";
    portScan?: () => PortScan;
  } = {},
): {
  version: 1;
  status: "removed" | "skipped";
  path: string;
  branch: string | null;
  reason: string | null;
} {
  const repo = resolve(input.repo);
  let targetRef: string;
  try {
    targetRef = resolveTargetRef(repo, input.target);
  } catch (error) {
    return { version: 1, status: "skipped", path: input.path, branch: null, reason: String(error) };
  }
  const isRemoteTarget = targetRef.startsWith("refs/remotes/");
  const refreshTime = input.refreshedAt ? Date.parse(input.refreshedAt) : NaN;
  if (
    isRemoteTarget &&
    (!Number.isFinite(refreshTime) ||
      Date.now() - refreshTime > 5 * 60_000 ||
      refreshTime > Date.now() + 30_000)
  )
    return {
      version: 1,
      status: "skipped",
      path: input.path,
      branch: null,
      reason:
        "Fetch the selected remote target successfully, then refresh the worktree list before removal.",
    };
  const canonical = (path: string) => {
    try {
      return realpathSync(path);
    } catch {
      return resolve(path);
    }
  };
  const verifyPreview = () => {
    const snapshot = inspectWorktrees(repo, input.target);
    const row = snapshot.entries.find(
      (candidate) => canonical(candidate.path) === canonical(input.path),
    );
    // The target may advance after preview; the merge check is redone against the new tip either way.
    const targetMoved = row?.targetCommit !== input.targetCommit;
    if (
      !row ||
      row.status !== "merged" ||
      row.branch !== input.previewBranch ||
      row.head !== input.previewHead ||
      (targetMoved && !isAncestor(repo, input.targetCommit, row.targetCommit ?? ""))
    )
      throw new Error(
        row?.reason ?? "Worktree branch, HEAD, contents, or target changed since preview.",
      );
    return row;
  };
  let entry: WorktreeEntry;
  try {
    entry = verifyPreview();
  } catch (error) {
    return { version: 1, status: "skipped", path: input.path, branch: null, reason: String(error) };
  }
  const activeFiles =
    options.activeFiles ??
    ((path: string): "active" | "none" | "unknown" => {
      try {
        return execFileSync("lsof", ["+D", path, "-t"], {
          encoding: "utf8",
          timeout: 10_000,
        }).trim()
          ? "active"
          : "none";
      } catch (error) {
        return typeof error === "object" &&
          error !== null &&
          "status" in error &&
          error.status === 1
          ? "none"
          : "unknown";
      }
    });
  const fileUse = activeFiles(entry.path);
  if (fileUse === "active")
    return {
      version: 1,
      status: "skipped",
      path: entry.path,
      branch: entry.branch,
      reason: "Files in this worktree are in use.",
    };
  if (fileUse === "unknown")
    return {
      version: 1,
      status: "skipped",
      path: entry.path,
      branch: entry.branch,
      reason: "Could not verify active files.",
    };
  const resolvedPath = resolve(entry.path);
  const portScan = (options.portScan ?? scanPorts)();
  // Only a listener whose folder is unknown could be hiding in this worktree.
  if (portScan.status === "failed" || portScan.listeners.some((listener) => listener.cwd === null))
    return {
      version: 1,
      status: "skipped",
      path: entry.path,
      branch: entry.branch,
      reason: "Could not verify active development listeners.",
    };
  const activeServer = portScan.listeners.find(
    (listener) =>
      listener.cwd &&
      (resolve(listener.cwd) === resolvedPath ||
        resolve(listener.cwd).startsWith(`${resolvedPath}/`)),
  );
  if (activeServer)
    return {
      version: 1,
      status: "skipped",
      path: entry.path,
      branch: entry.branch,
      reason: `A TCP listener from PID ${activeServer.pid} is using this worktree.`,
    };
  try {
    if (isRemoteTarget) {
      try {
        git(repo, ["fetch", targetRef.slice("refs/remotes/".length).split("/")[0] ?? ""]);
      } catch (error) {
        return {
          version: 1,
          status: "skipped",
          path: entry.path,
          branch: entry.branch,
          reason: `Could not refresh target before removal: ${String(error)}`,
        };
      }
    }
    entry = verifyPreview();
    git(repo, ["worktree", "remove", entry.path]);
    return { version: 1, status: "removed", path: entry.path, branch: entry.branch, reason: null };
  } catch (error) {
    return {
      version: 1,
      status: "skipped",
      path: entry.path,
      branch: entry.branch,
      reason: String(error),
    };
  }
}

function isAncestor(repo: string, ancestor: string, descendant: string): boolean {
  try {
    git(repo, ["merge-base", "--is-ancestor", ancestor, descendant]);
    return true;
  } catch {
    return false;
  }
}

export function pruneWorktrees(repoInput: string): {
  version: 1;
  status: "pruned" | "failed";
  pruned: string[];
  error: string | null;
} {
  try {
    const repo = resolve(repoInput);
    const stale = worktreeRows(repo)
      .filter((row) => row.prunable)
      .map((row) => row.path);
    git(repo, ["worktree", "prune"]);
    const left = new Set(worktreeRows(repo).map((row) => row.path));
    return {
      version: 1,
      status: "pruned",
      pruned: stale.filter((path) => !left.has(path)),
      error: null,
    };
  } catch (error) {
    return { version: 1, status: "failed", pruned: [], error: String(error) };
  }
}

export function currentUser(): string {
  return basename(homedir());
}
