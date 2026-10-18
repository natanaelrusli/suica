import { execFile } from "node:child_process";
import { promisify } from "node:util";

export interface ExecResult {
  readonly stdout: string;
  readonly stderr: string;
}

export interface ExecOptions {
  readonly timeoutMs: number;
  /** Working folder of the child; the caller's when absent. */
  readonly cwd?: string;
  /** Kills the child when aborted. */
  readonly signal?: AbortSignal;
}

export type Exec = (
  file: string,
  args: readonly string[],
  options: ExecOptions,
) => Promise<ExecResult>;

const execFileAsync = promisify(execFile);
const MAX_BUFFER_BYTES = 16 * 1024 * 1024;

export const defaultExec: Exec = async (file, args, options) => {
  const { stdout, stderr } = await execFileAsync(file, [...args], {
    timeout: options.timeoutMs,
    ...(options.cwd === undefined ? {} : { cwd: options.cwd }),
    ...(options.signal === undefined ? {} : { signal: options.signal }),
    maxBuffer: MAX_BUFFER_BYTES,
    encoding: "utf8",
  });
  return { stdout, stderr };
};

export interface ExecFailure {
  code?: string | number;
  killed?: boolean;
  stderr?: string;
}

/** Narrows the error thrown by `execFile` without trusting its shape. */
export function execFailure(error: unknown): ExecFailure {
  const failure: ExecFailure = {};
  if (typeof error !== "object" || error === null) return failure;
  if ("code" in error && (typeof error.code === "string" || typeof error.code === "number")) {
    failure.code = error.code;
  }
  if ("killed" in error && typeof error.killed === "boolean") failure.killed = error.killed;
  if ("stderr" in error && typeof error.stderr === "string") failure.stderr = error.stderr;
  return failure;
}
