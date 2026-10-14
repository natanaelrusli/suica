import { defaultExec } from "./exec.ts";
import type { Exec } from "./exec.ts";

const IOREG_TIMEOUT_MS = 5000;
const NANOSECONDS_PER_SECOND = 1e9;

export function parseIdleSeconds(ioregOutput: string): number | null {
  const raw = /"HIDIdleTime"\s*=\s*(\d+)/.exec(ioregOutput)?.[1];
  return raw === undefined ? null : Number(raw) / NANOSECONDS_PER_SECOND;
}

/** Seconds since the last keyboard or mouse input; 0 (active) when it cannot be read. */
export async function readIdleSeconds(exec: Exec = defaultExec): Promise<number> {
  try {
    const { stdout } = await exec("ioreg", ["-c", "IOHIDSystem"], { timeoutMs: IOREG_TIMEOUT_MS });
    return parseIdleSeconds(stdout) ?? 0;
  } catch {
    // Unknown idle time is treated as "active": poll at the faster interval rather than slow down.
    return 0;
  }
}
