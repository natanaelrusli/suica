import { basename } from "node:path";
import type { ProcInfo } from "./types.ts";

/** The program of a command line: up to the first ` -flag`, so a path with spaces stays whole. */
export function executableOf(command: string): string {
  const at = command.search(/\s-/);
  return (at === -1 ? command : command.slice(0, at)).trim();
}

/** True when the command line runs a program called `name` (as `claude`, not `claude-mem`). */
export function runs(command: string, name: string): boolean {
  const executable = executableOf(command);
  const first = executable.split(/\s/)[0] ?? "";
  return basename(executable) === name || basename(first) === name;
}

export function processesRunning(procs: readonly ProcInfo[], name: string): ProcInfo[] {
  return procs.filter((proc) => runs(proc.command, name));
}
