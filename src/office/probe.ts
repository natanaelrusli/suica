import { spawnSync } from "node:child_process";
import { homedir } from "node:os";
import type { ProcInfo, Probe } from "./types.ts";

function run(file: string, args: readonly string[]): string {
  const result = spawnSync(file, [...args], {
    encoding: "utf8",
    timeout: 5_000,
    maxBuffer: 16 * 1024 * 1024,
  });
  return result.status === 0 || result.stdout !== "" ? result.stdout : "";
}

/** The machine as detection sees it: `ps` for processes, `lsof` for a process's folder. */
export function realProbe(now = Date.now()): Probe {
  let cached: ProcInfo[] | undefined;
  return {
    home: homedir(),
    now,
    pidAlive(pid) {
      try {
        process.kill(pid, 0);
        return true;
      } catch (error) {
        return (error as NodeJS.ErrnoException).code === "EPERM";
      }
    },
    processes() {
      cached ??= run("ps", ["-axo", "pid=,ppid=,command="])
        .split("\n")
        .flatMap((line) => {
          const match = /^\s*(\d+)\s+(\d+)\s+(.*)$/.exec(line);
          return match?.[1] === undefined || match[2] === undefined || match[3] === undefined
            ? []
            : [{ pid: Number(match[1]), ppid: Number(match[2]), command: match[3] }];
        });
      return cached;
    },
    cwdOf(pid) {
      const line = run("lsof", ["-a", "-d", "cwd", "-p", String(pid), "-Fn"])
        .split("\n")
        .find((candidate) => candidate.startsWith("n"));
      return line === undefined ? null : line.slice(1);
    },
    openFiles(pid) {
      return run("lsof", ["-p", String(pid), "-Fn"])
        .split("\n")
        .filter((line) => line.startsWith("n/"))
        .map((line) => line.slice(1));
    },
  };
}
