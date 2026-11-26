import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  fetchWorktreeTarget,
  inspectWorktrees,
  pruneWorktrees,
  removeWorktree,
  scanPorts,
  stopPortProcess,
} from "../src/development-cleanup.ts";

const roots: string[] = [];
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

describe("ports cleanup", () => {
  it("groups listeners and reports partial scans when process metadata is missing", () => {
    const fake = (file: string, args: readonly string[]) => {
      if (file === "lsof" && args[0] === "-nP")
        return "p23\ncnode\nu501\nn*:3000\nTST=LISTEN\nn[::1]:5173\np24\ncpython\nTST=LISTEN\nn127.0.0.1:8080\n";
      if (args.includes("cwd")) return "p23\nn/tmp/project\n";
      if (args.includes("command=")) return "node fixture-server.js";
      if (args[0] === "-p") return "Mon Nov 23 10:00:00 2026";
      throw new Error("unexpected fixture command");
    };
    const result = scanPorts(fake);
    expect(result.status).toBe("partial");
    expect(result.listeners).toHaveLength(2);
    expect(result.listeners[0]?.ports).toEqual(["3000", "5173"]);
    expect(result.listeners[0]?.endpoints).toEqual(["*:3000", "[::1]:5173"]);
    expect(result.listeners[0]?.cwd).toBe("/tmp/project");
    expect(result.listeners[0]?.command).toBe("node fixture-server.js");
  });

  it("sends SIGKILL only when forced", async () => {
    const listener = {
      pid: 23,
      owner: String(process.getuid?.()),
      program: "node",
      protected: false,
      cwd: "/tmp",
      startedAt: "same",
      command: "node",
      endpoints: ["*:3000"],
      ports: ["3000"],
    };
    const signals: string[] = [];
    let calls = 0;
    const result = await stopPortProcess(
      { pid: 23, startedAt: "same", ports: ["3000"], force: true },
      {
        scan: () => ({
          version: 1,
          status: "ok",
          error: null,
          listeners: ++calls === 1 ? [listener] : [],
        }),
        kill: (_pid, signal) => {
          signals.push(signal);
        },
        wait: async () => {},
      },
    );
    expect(result.status).toBe("stopped");
    expect(signals).toEqual(["SIGKILL"]);
  });

  it("refuses to signal a changed process identity", async () => {
    const result = await stopPortProcess(
      { pid: 23, startedAt: "old", ports: ["3000"] },
      {
        scan: () => ({
          version: 1,
          status: "ok",
          error: null,
          listeners: [
            {
              pid: 23,
              owner: String(process.getuid?.()),
              program: "node",
              protected: false,
              cwd: "/tmp",
              startedAt: "new",
              command: "node",
              endpoints: ["*:3000"],
              ports: ["3000"],
            },
          ],
        }),
        kill: () => {
          throw new Error("must not signal");
        },
      },
    );
    expect(result.status).toBe("identity-changed");
  });

  it("allows stopping a fully known target when unrelated process metadata is partial and requires exact ports", async () => {
    const target = {
      pid: 23,
      owner: String(process.getuid?.()),
      program: "node",
      protected: false,
      cwd: "/tmp/project",
      startedAt: "same",
      command: "node",
      endpoints: ["*:3000"],
      ports: ["3000"],
    };
    let scans = 0;
    const result = await stopPortProcess(
      { pid: 23, startedAt: "same", ports: ["3000"] },
      {
        scan: () =>
          ++scans === 1
            ? {
                version: 1,
                status: "partial",
                error: "unrelated metadata unavailable",
                listeners: [target],
              }
            : { version: 1, status: "ok", error: null, listeners: [] },
        kill: () => {},
        wait: async () => {},
      },
    );
    expect(result.status).toBe("stopped");
    const subset = await stopPortProcess(
      { pid: 23, startedAt: "same", ports: ["3000"] },
      {
        scan: () => ({
          version: 1,
          status: "ok",
          error: null,
          listeners: [{ ...target, ports: ["3000", "5173"], endpoints: ["*:3000", "*:5173"] }],
        }),
        kill: () => {
          throw new Error("must not signal a partial port selection");
        },
      },
    );
    expect(subset.status).toBe("identity-changed");
  });

  it("reports a process that survives SIGTERM and a port reopened by another process", async () => {
    const listener = {
      pid: 23,
      owner: String(process.getuid?.()),
      program: "node",
      protected: false,
      cwd: "/tmp",
      startedAt: "same",
      command: "node",
      endpoints: ["*:3000"],
      ports: ["3000"],
    };
    const scan = (rows: (typeof listener)[]) => ({
      version: 1 as const,
      status: "ok" as const,
      error: null,
      listeners: rows,
    });
    const stillRunning = await stopPortProcess(
      { pid: 23, startedAt: "same", ports: ["3000"] },
      {
        scan: () => scan([listener]),
        kill: () => {},
        wait: async () => {},
      },
    );
    expect(stillRunning.status).toBe("still-running");
    let calls = 0;
    const reopened = await stopPortProcess(
      { pid: 23, startedAt: "same", ports: ["3000"] },
      {
        scan: () =>
          ++calls === 1 ? scan([listener]) : scan([{ ...listener, pid: 24, startedAt: "other" }]),
        kill: () => {},
        wait: async () => {},
      },
    );
    expect(reopened.status).toBe("port-reopened");
  });

  it("distinguishes a permission-denied signal", async () => {
    const listener = {
      pid: 23,
      owner: String(process.getuid?.()),
      program: "node",
      protected: false,
      cwd: "/tmp",
      startedAt: "same",
      command: "node",
      endpoints: ["*:3000"],
      ports: ["3000"],
    };
    const result = await stopPortProcess(
      { pid: 23, startedAt: "same", ports: ["3000"] },
      {
        scan: () => ({ version: 1, status: "ok", error: null, listeners: [listener] }),
        kill: () => {
          throw Object.assign(new Error("denied"), { code: "EPERM" });
        },
      },
    );
    expect(result.status).toBe("permission-denied");
  });
});

describe("worktree cleanup", () => {
  it("marks only clean linked ancestors eligible and keeps target commits explicit", () => {
    const root = mkdtempSync(join(tmpdir(), "suica-worktrees-"));
    roots.push(root);
    const repo = join(root, "repo");
    mkdirSync(repo);
    const git = (...args: string[]) => execFileSync("git", args, { cwd: repo, stdio: "ignore" });
    git("init", "-b", "main");
    git("config", "user.email", "fixture@example.test");
    git("config", "user.name", "Fixture");
    writeFileSync(join(repo, "base"), "base");
    git("add", "base");
    git("commit", "-m", "base");
    const path = join(root, "linked");
    git("worktree", "add", "-b", "finished", path);
    writeFileSync(join(path, "work"), "finished");
    git("-C", path, "add", "work");
    git("-C", path, "commit", "-m", "finished");
    git("merge", "--no-ff", "finished", "-m", "merge");
    const listing = inspectWorktrees(repo, "main");
    const candidate = listing.entries.find((entry) => entry.branch === "finished");
    expect(candidate?.status).toBe("merged");
    expect(candidate?.targetCommit).toBeTruthy();
    expect(inspectWorktrees(repo, "HEAD").status).toBe("failed");
    git("branch", "topic/target");
    expect(inspectWorktrees(repo, "topic/target").status).toBe("ok");
    expect(
      removeWorktree(
        {
          repo,
          path,
          target: "main",
          targetCommit: candidate?.targetCommit ?? "",
          previewBranch: "finished",
          previewHead: candidate?.head ?? "",
        },
        {
          activeFiles: () => "none",
          portScan: () => ({ version: 1, status: "ok", error: null, listeners: [] }),
        },
      ).status,
    ).toBe("removed");
    expect(
      execFileSync("git", ["branch", "--list", "finished"], { cwd: repo, encoding: "utf8" }).trim(),
    ).toBe("finished");
    const pathAgain = join(root, "linked-again");
    git("worktree", "add", pathAgain, "finished");
    expect(
      removeWorktree(
        {
          repo,
          path: pathAgain,
          target: "origin/main",
          targetCommit: candidate?.targetCommit ?? "",
          previewBranch: "finished",
          previewHead: candidate?.head ?? "",
        },
        {
          activeFiles: () => "none",
          portScan: () => ({ version: 1, status: "ok", error: null, listeners: [] }),
        },
      ).status,
    ).toBe("skipped");
    writeFileSync(join(pathAgain, "dirty"), "untracked");
    expect(
      inspectWorktrees(repo, "main").entries.find((entry) => entry.branch === "finished")?.status,
    ).toBe("ineligible");
    const unfinished = join(root, "unfinished");
    git("worktree", "add", "-b", "unfinished", unfinished);
    writeFileSync(join(unfinished, "later"), "not merged");
    execFileSync("git", ["-C", unfinished, "add", "later"]);
    execFileSync("git", ["-C", unfinished, "commit", "-m", "unmerged"]);
    expect(
      inspectWorktrees(repo, "main").entries.find((entry) => entry.branch === "unfinished")?.status,
    ).toBe("unverified");
    const sequencer = join(root, "sequencer");
    git("worktree", "add", "-b", "sequencer-test", sequencer);
    mkdirSync(
      execFileSync("git", ["-C", sequencer, "rev-parse", "--git-path", "sequencer"], {
        encoding: "utf8",
      }).trim(),
      { recursive: true },
    );
    expect(
      inspectWorktrees(repo, "main").entries.find((entry) => entry.branch === "sequencer-test")
        ?.reason,
    ).toContain("sequencer");
  });

  function fixtureRepo() {
    const root = mkdtempSync(join(tmpdir(), "suica-worktrees-"));
    roots.push(root);
    const repo = join(root, "repo");
    mkdirSync(repo);
    const git = (...args: string[]) => execFileSync("git", args, { cwd: repo, stdio: "ignore" });
    git("init", "-b", "main");
    git("config", "user.email", "fixture@example.test");
    git("config", "user.name", "Fixture");
    writeFileSync(join(repo, "base"), "base");
    git("add", "base");
    git("commit", "-m", "base");
    return { root, repo, git };
  }
  const noActivity = {
    activeFiles: () => "none" as const,
    portScan: () => ({ version: 1 as const, status: "ok" as const, error: null, listeners: [] }),
  };

  it("still removes a merged checkout after the target advances, but not after it is rewritten", () => {
    const { root, repo, git } = fixtureRepo();
    const path = join(root, "done");
    git("worktree", "add", "-b", "done", path);
    const preview = inspectWorktrees(repo, "main").entries.find((entry) => entry.branch === "done");
    expect(preview?.status).toBe("merged");
    writeFileSync(join(repo, "later"), "later");
    git("add", "later");
    git("commit", "-m", "trunk moved on");
    const input = {
      repo,
      path,
      target: "main",
      targetCommit: preview?.targetCommit ?? "",
      previewBranch: "done",
      previewHead: preview?.head ?? "",
    };
    expect(removeWorktree(input, noActivity).status).toBe("removed");
    const other = join(root, "other");
    // Branch from the base commit so the checkout stays merged into the rewritten target too.
    git("worktree", "add", "-b", "other", other, "HEAD~1");
    const second = inspectWorktrees(repo, "main").entries.find((entry) => entry.branch === "other");
    expect(second?.status).toBe("merged");
    git("reset", "--hard", "HEAD~1");
    git("commit", "--allow-empty", "-m", "rewritten");
    expect(
      inspectWorktrees(repo, "main").entries.find((entry) => entry.branch === "other")?.status,
    ).toBe("merged");
    const rewritten = removeWorktree(
      {
        ...input,
        path: other,
        targetCommit: second?.targetCommit ?? "",
        previewBranch: "other",
        previewHead: second?.head ?? "",
      },
      noActivity,
    );
    expect(rewritten.status).toBe("skipped");
    expect(rewritten.reason).toContain("changed since preview");
  });

  it("collapses disposable ignored folders and blocks local environment files", () => {
    const { root, repo, git } = fixtureRepo();
    writeFileSync(join(repo, ".gitignore"), "node_modules/\ndist/\n.env\n");
    git("add", ".gitignore");
    git("commit", "-m", "ignore");
    const path = join(root, "built");
    git("worktree", "add", "-b", "built", path);
    for (const dir of ["node_modules/a/b", "dist"]) mkdirSync(join(path, dir), { recursive: true });
    for (let i = 0; i < 50; i += 1) writeFileSync(join(path, "node_modules/a/b", `f${i}`), "x");
    writeFileSync(join(path, "dist/app.js"), "x");
    const entry = () =>
      inspectWorktrees(repo, "main").entries.find((row) => row.branch === "built");
    expect(entry()?.status).toBe("merged");
    expect(entry()?.ignoredOutput).toEqual(["dist/", "node_modules/"]);
    writeFileSync(join(path, ".env"), "SECRET=1");
    expect(entry()?.reason).toContain(".env");
  });

  it("does not treat a secret inside a tracked build folder as disposable", () => {
    const { root, repo, git } = fixtureRepo();
    writeFileSync(join(repo, ".gitignore"), ".env\n");
    mkdirSync(join(repo, "build"));
    writeFileSync(join(repo, "build/keep"), "tracked");
    git("add", ".");
    git("commit", "-m", "tracked build folder");
    const path = join(root, "secret");
    git("worktree", "add", "-b", "secret", path);
    writeFileSync(join(path, "build/.env"), "SECRET=1");
    const entry = inspectWorktrees(repo, "main").entries.find((row) => row.branch === "secret");
    expect(entry?.status).toBe("ineligible");
    expect(entry?.reason).toContain("build/.env");
  });

  it("removes against a remote target only after a recent fetch", () => {
    const { root, repo, git } = fixtureRepo();
    const origin = join(root, "origin.git");
    execFileSync("git", ["clone", "--bare", repo, origin], { stdio: "ignore" });
    git("remote", "add", "origin", origin);
    git("fetch", "origin");
    const path = join(root, "shipped");
    git("worktree", "add", "-b", "shipped", path);
    const fetched = fetchWorktreeTarget(repo, "origin/main");
    expect(fetched.status).toBe("fetched");
    const scan = inspectWorktrees(repo, "origin/main");
    expect(scan.targetRef).toBe("refs/remotes/origin/main");
    const row = scan.entries.find((entry) => entry.branch === "shipped");
    const input = {
      repo,
      path,
      target: "origin/main",
      targetCommit: row?.targetCommit ?? "",
      previewBranch: "shipped",
      previewHead: row?.head ?? "",
    };
    const stale = removeWorktree(
      { ...input, refreshedAt: new Date(Date.now() - 10 * 60_000).toISOString() },
      noActivity,
    );
    expect(stale.status).toBe("skipped");
    expect(removeWorktree({ ...input, refreshedAt: fetched.refreshedAt }, noActivity).status).toBe(
      "removed",
    );
  });

  it("reports a deleted checkout as prunable and prunes only stale entries", () => {
    const { root, repo, git } = fixtureRepo();
    const gone = join(root, "gone");
    git("worktree", "add", "-b", "gone", gone);
    const kept = join(root, "kept");
    git("worktree", "add", "-b", "kept", kept);
    rmSync(gone, { recursive: true, force: true });
    const scan = inspectWorktrees(repo, "main");
    expect(scan.targetRef).toBe("refs/heads/main");
    expect(scan.entries.find((row) => row.branch === "gone")?.status).toBe("prunable");
    expect(pruneWorktrees(repo).pruned.map((path) => path.endsWith("/gone"))).toEqual([true]);
    expect(inspectWorktrees(repo, "main").entries.map((row) => row.branch)).toEqual([
      "main",
      "kept",
    ]);
  });
});
