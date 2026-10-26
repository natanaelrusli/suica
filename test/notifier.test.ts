import { describe, expect, it } from "vitest";
import type { Exec } from "../src/exec.ts";
import { createNotifier, suicaNotifierPath } from "../src/notifier.ts";
import type { Notifier } from "../src/notifier.ts";

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

const plain = (exec: Exec): Notifier => createNotifier(exec, { binaries: ["terminal-notifier"] });

describe("createNotifier", () => {
  it("uses terminal-notifier and opens the URL on click", async () => {
    const { calls, exec } = recordingExec();
    await plain(exec).notify({ title: "T", body: "B", url: "https://x/y" });
    expect(calls).toEqual([
      ["terminal-notifier", "-title", "\\T", "-message", "\\B", "-open", "https://x/y"],
    ]);
  });

  it("passes a suica:// link through for the app to open", async () => {
    const { calls, exec } = recordingExec();
    await plain(exec).notify({ title: "T", body: "B", url: "suica://message/12" });
    expect(calls).toEqual([
      ["terminal-notifier", "-title", "\\T", "-message", "\\B", "-open", "suica://message/12"],
    ]);
  });

  it("escapes the first character of the title and message, which terminal-notifier would misread", async () => {
    const { calls, exec } = recordingExec();
    await plain(exec).notify({ title: "(T)", body: "[ABC-1] fix", url: "https://x/y" });
    expect(calls).toEqual([
      ["terminal-notifier", "-title", "\\(T)", "-message", "\\[ABC-1] fix", "-open", "https://x/y"],
    ]);
  });

  it("omits -open when there is no URL", async () => {
    const { calls, exec } = recordingExec();
    await plain(exec).notify({ title: "T", body: "B" });
    expect(calls[0]).toEqual(["terminal-notifier", "-title", "\\T", "-message", "\\B"]);
  });

  it("falls back to osascript and passes the text as arguments, never as script source", async () => {
    const { calls, exec } = recordingExec({ terminalNotifierMissing: true });
    await plain(exec).notify({ title: 'T"; do shell script "x', body: "B" });
    const fallback = calls[1] ?? [];
    expect(fallback[0]).toBe("osascript");
    expect(fallback.slice(-2)).toEqual(['T"; do shell script "x', "B"]);
    const script = fallback.slice(1, -2).join("\n");
    expect(script).not.toContain("do shell script");
  });

  it("propagates failures other than a missing terminal-notifier", async () => {
    const { calls, exec } = recordingExec({ failWith: { code: 1 } });
    await expect(plain(exec).notify({ title: "T", body: "B" })).rejects.toThrow();
    expect(calls).toHaveLength(1);
  });

  it("plays the notification's sound", async () => {
    const { calls, exec } = recordingExec();
    await plain(exec).notify({ title: "T", body: "B", sound: "Basso" });
    expect(calls[0]).toEqual([
      "terminal-notifier",
      "-title",
      "\\T",
      "-message",
      "\\B",
      "-sound",
      "Basso",
    ]);
  });

  it("prefers the Suica-branded notifier and falls back to the plain one", async () => {
    const suica = suicaNotifierPath("/Users/me");
    expect(suica).toBe(
      "/Users/me/Applications/Suica Notifier.app/Contents/MacOS/terminal-notifier",
    );
    const calls: string[] = [];
    const exec: Exec = (file) => {
      calls.push(file);
      return file === suica
        ? Promise.reject(Object.assign(new Error("spawn ENOENT"), { code: "ENOENT" }))
        : Promise.resolve({ stdout: "", stderr: "" });
    };
    await createNotifier(exec, { binaries: [suica, "terminal-notifier"] }).notify({
      title: "T",
      body: "B",
    });
    expect(calls).toEqual([suica, "terminal-notifier"]);
  });

  describe("buttons", () => {
    const review = { title: "Review dengan agen", suica: ["review", "queue", "g/p!7", "--json"] };
    const notification = { title: "T", body: "B", url: "https://x/y", actions: [review] };

    function answering(answer: string): { calls: string[][]; exec: Exec } {
      const calls: string[][] = [];
      const exec: Exec = (file, args) => {
        calls.push([file, ...args]);
        return Promise.resolve({
          stdout: file === "terminal-notifier" ? `${answer}\n` : "",
          stderr: "",
        });
      };
      return { calls, exec };
    }
    const settle = () => new Promise((resolve) => setTimeout(resolve, 5));

    it("shows the buttons and waits for an answer instead of -open", async () => {
      const { calls, exec } = answering("@CLOSED");
      await createNotifier(exec, {
        binaries: ["terminal-notifier"],
        cli: ["node", "cli.ts"],
      }).notify(notification);
      expect(calls[0]).toEqual([
        "terminal-notifier",
        "-title",
        "\\T",
        "-message",
        "\\B",
        "-action",
        "Review dengan agen",
        "-timeout",
        "3600",
      ]);
    });

    it("runs the suica CLI for the button that was clicked", async () => {
      const { calls, exec } = answering("Review dengan agen");
      await createNotifier(exec, {
        binaries: ["terminal-notifier"],
        cli: ["node", "cli.ts"],
      }).notify(notification);
      await settle();
      expect(calls[1]).toEqual(["node", "cli.ts", "review", "queue", "g/p!7", "--json"]);
    });

    it("opens the link when the body is clicked", async () => {
      const { calls, exec } = answering("@ACTIONCLICKED");
      await createNotifier(exec, {
        binaries: ["terminal-notifier"],
        cli: ["node", "cli.ts"],
      }).notify(notification);
      await settle();
      expect(calls[1]).toEqual(["open", "https://x/y"]);
    });

    it("never opens a link that is not http, https or suica", async () => {
      const { calls, exec } = answering("@ACTIONCLICKED");
      await createNotifier(exec, { binaries: ["terminal-notifier"] }).notify({
        title: "T",
        body: "B",
        url: "file:///etc/passwd",
        actions: [{ title: "Buka", open: "file:///x" }],
      });
      await settle();
      expect(calls).toHaveLength(1);
    });

    it("leaves out buttons that need the CLI when there is none", async () => {
      const { calls, exec } = recordingExec();
      await plain(exec).notify(notification);
      expect(calls[0]).toEqual([
        "terminal-notifier",
        "-title",
        "\\T",
        "-message",
        "\\B",
        "-open",
        "https://x/y",
      ]);
    });

    it("does not wait for the answer", async () => {
      const exec: Exec = () => new Promise(() => undefined);
      await createNotifier(exec, {
        binaries: ["terminal-notifier"],
        cli: ["node", "cli.ts"],
        launchGraceMs: 5,
      }).notify(notification);
    });

    it("reports a notifier that fails to start", async () => {
      const exec: Exec = () => Promise.reject(Object.assign(new Error("exit 1"), { code: 1 }));
      await expect(
        createNotifier(exec, { binaries: ["terminal-notifier"], cli: ["node", "cli.ts"] }).notify(
          notification,
        ),
      ).rejects.toThrow();
    });
  });

  it("falls back to the next notifier when the Suica one is refused permission", async () => {
    const calls: string[] = [];
    const exec: Exec = (file) => {
      calls.push(file);
      return file === "suica-notifier"
        ? Promise.reject(Object.assign(new Error("exit 3"), { code: 3 }))
        : Promise.resolve({ stdout: "", stderr: "" });
    };
    await createNotifier(exec, { binaries: ["suica-notifier", "terminal-notifier"] }).notify({
      title: "T",
      body: "B",
    });
    expect(calls).toEqual(["suica-notifier", "terminal-notifier"]);
  });
});
