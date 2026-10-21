import { mkdirSync, utimesSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import type { ProcInfo, Probe } from "../src/office/types.ts";

export const NOW = 1_792_550_000_000;

export interface FakeProbeOptions {
  readonly home: string;
  readonly alive?: readonly number[];
  readonly procs?: readonly ProcInfo[];
  readonly cwds?: Readonly<Record<number, string>>;
}

export function fakeProbe(options: FakeProbeOptions): Probe {
  const alive = new Set([...(options.alive ?? []), ...(options.procs ?? []).map((p) => p.pid)]);
  return {
    home: options.home,
    now: NOW,
    pidAlive: (pid) => alive.has(pid),
    processes: () => options.procs ?? [],
    cwdOf: (pid) => options.cwds?.[pid] ?? null,
  };
}

/** Writes a file (creating folders) and sets its modification time. */
export function put(path: string, text: string, mtime?: number): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, text);
  if (mtime !== undefined) utimesSync(path, mtime / 1000, mtime / 1000);
}

export const lines = (...entries: unknown[]): string =>
  `${entries.map((entry) => JSON.stringify(entry)).join("\n")}\n`;
