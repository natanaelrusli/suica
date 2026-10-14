import { describe, expect, it } from "vitest";
import type { Exec } from "../src/exec.ts";
import { createNotifier } from "../src/notifier.ts";

function recordingExec(options: { terminalNotifierMissing?: boolean; failWith?: object } = {}): {
  calls: string[][];
  exec: Exec;
} {
  const calls: string[][] = [];
  const exec: Exec = (file, args) => {
    calls.push([file, ...args]);
    if (options.failWith !== undefined) {
      return Promise.reject(Object.assign(new Error("exec failed"), options.failWith));
    }
    if (file === "terminal-notifier" && options.terminalNotifierMissing === true) {
      return Promise.reject(Object.assign(new Error("spawn ENOENT"), { code: "ENOENT" }));
    }
    return Promise.resolve({ stdout: "", stderr: "" });
  };
  return { calls, exec };
}

describe("createNotifier", () => {
  it("uses terminal-notifier and opens the URL on click", async () => {
    const { calls, exec } = recordingExec();
    await createNotifier(exec).notify({ title: "T", body: "B", url: "https://x/y" });
    expect(calls).toEqual([
      ["terminal-notifier", "-title", "T", "-message", "B", "-open", "https://x/y"],
    ]);
  });

  it("omits -open when there is no URL", async () => {
    const { calls, exec } = recordingExec();
    await createNotifier(exec).notify({ title: "T", body: "B" });
    expect(calls[0]).toEqual(["terminal-notifier", "-title", "T", "-message", "B"]);
  });

  it("falls back to osascript and passes the text as arguments, never as script source", async () => {
    const { calls, exec } = recordingExec({ terminalNotifierMissing: true });
    await createNotifier(exec).notify({ title: 'T"; do shell script "x', body: "B" });
    const fallback = calls[1] ?? [];
    expect(fallback[0]).toBe("osascript");
    expect(fallback.slice(-2)).toEqual(['T"; do shell script "x', "B"]);
    const script = fallback.slice(1, -2).join("\n");
    expect(script).not.toContain("do shell script");
  });

  it("propagates failures other than a missing terminal-notifier", async () => {
    const { calls, exec } = recordingExec({ failWith: { code: 1 } });
    await expect(createNotifier(exec).notify({ title: "T", body: "B" })).rejects.toThrow();
    expect(calls).toHaveLength(1);
  });
});
