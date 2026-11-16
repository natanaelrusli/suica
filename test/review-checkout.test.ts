import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { cloneSourceBranch } from "../src/agent-review.ts";
import type { Exec } from "../src/exec.ts";
import type { RestRunner } from "../src/gitlab.ts";
import type { MrDetailJson } from "../src/reviews.ts";

const expected = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const other = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const detail = JSON.parse(readFileSync(join(import.meta.dirname, "../contracts/mr-detail.v1.json"), "utf8")) as MrDetailJson;
const signal = new AbortController().signal;

type Call = { file: string; args: readonly string[]; options: Parameters<Exec>[2] };
function harness(initialHead: string, finalHead = expected) {
  const calls: Call[] = [];
  let revParseCount = 0;
  const exec: Exec = async (file, args, options) => {
    calls.push({ file, args, options });
    if (args[0] === "-C" && args[1] === "/repo" && args[2] === "rev-parse") {
      revParseCount++;
      return { stdout: revParseCount === 1 ? initialHead : finalHead, stderr: "" };
    }
    return { stdout: "", stderr: "" };
  };
  const rest: RestRunner = async (path) => {
    if (/\/merge_requests\/\d+$/.test(path)) return { source_project_id: 123 };
    if (path === "projects/123") return { ssh_url_to_repo: "git@gitlab.example:fork/p.git" };
    return { ssh_url_to_repo: "git@gitlab.example:g/p.git" };
  };
  return { calls, deps: { exec, rest, signal } };
}

const has = (call: Call, ...args: string[]) => expect(call.args).toEqual(expect.arrayContaining(args));

describe("cloneSourceBranch reviewed commit checkout", () => {
  it("detaches and verifies when the shallow clone already has the expected HEAD", async () => {
    const h = harness(expected);
    await expect(cloneSourceBranch(h.deps, detail, "/repo", undefined, expected)).resolves.toBe(expected);
    expect(h.calls.map((call) => (call.args.includes("clone") ? call.args.slice(6) : call.args.slice(2)))).toEqual([
      ["clone", "--depth=1", "--single-branch", "--no-tags", "--", "git@gitlab.example:fork/p.git", "/repo"],
      ["rev-parse", "HEAD"], ["checkout", "--detach", expected], ["rev-parse", "HEAD"],
    ]);
    expect(h.calls[0]?.options.signal).toBe(signal);
    expect(h.calls[2]?.options.signal).toBe(signal);
    expect(h.calls[3]?.options.signal).toBe(signal);
  });

  it("fetches the expected SHA before detaching when the branch moved", async () => {
    const h = harness(other);
    await expect(cloneSourceBranch(h.deps, detail, "/repo", undefined, expected)).resolves.toBe(expected);
    const fetch = h.calls.find((call) => call.args.includes("fetch"));
    expect(fetch).toBeDefined();
    has(fetch!, "fetch", "--depth=1", "--no-tags", "origin", expected);
    expect(fetch!.options.signal).toBe(signal);
    const checkout = h.calls.find((call) => call.args.includes("checkout"))!;
    has(checkout, "checkout", "--detach", expected);
    expect(checkout.options.signal).toBe(signal);
    expect(h.calls.at(-1)?.options.signal).toBe(signal);
  });

  it("rejects when fetching the expected SHA fails", async () => {
    const h = harness(other);
    const exec: Exec = async (file, args, options) => {
      h.calls.push({ file, args, options });
      if (args.includes("fetch")) throw Object.assign(new Error("fetch failed"), { code: 1 });
      if (args[2] === "rev-parse") return { stdout: other, stderr: "" };
      return { stdout: "", stderr: "" };
    };
    await expect(cloneSourceBranch({ ...h.deps, exec }, detail, "/repo", undefined, expected)).rejects.toThrow("checkout of the source branch failed");
  });

  it("rejects when final HEAD verification differs", async () => {
    const h = harness(expected, other);
    await expect(cloneSourceBranch(h.deps, detail, "/repo", undefined, expected)).rejects.toThrow("checkout of the source branch failed");
  });

  it("keeps legacy branch cloning without an expected SHA", async () => {
    const h = harness(expected);
    await expect(cloneSourceBranch(h.deps, detail, "/repo")).resolves.toBe(expected);
    has(h.calls[0]!, `--branch=${detail.sourceBranch}`);
    expect(h.calls.some((call) => call.args.includes("checkout"))).toBe(false);
    expect(h.calls.some((call) => call.args.includes("fetch"))).toBe(false);
    expect(h.calls[0]?.options.signal).toBe(signal);
  });

  it("uses the fork URL for exact SHA checkout even when branch names match", async () => {
    const h = harness(expected);
    const forkDetail = { ...detail, sourceBranch: detail.targetBranch };
    await expect(cloneSourceBranch(h.deps, forkDetail, "/repo", undefined, expected)).resolves.toBe(expected);
    expect(h.calls[0]?.args).toContain("git@gitlab.example:fork/p.git");
  });

  it.each([undefined, null])("refuses an MR without a valid source_project_id (%s)", async (sourceProjectId) => {
    const h = harness(expected);
    const rest: RestRunner = async (path) => /\/merge_requests\/\d+$/.test(path)
      ? { source_project_id: sourceProjectId }
      : { ssh_url_to_repo: "git@gitlab.example:g/p.git" };
    await expect(cloneSourceBranch({ ...h.deps, rest }, detail, "/repo", undefined, expected))
      .rejects.toThrow("no usable source project");
  });
});
