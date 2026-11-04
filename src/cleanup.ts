import { existsSync, lstatSync, readdirSync, rmSync, truncateSync } from "node:fs";
import { dirname, join } from "node:path";
import { cleanFixDirs } from "./fix-runner.ts";
import type { Store } from "./store.ts";

export interface CleanupPaths {
  readonly statePath: string;
  /** ~/Library/Logs/suica */
  readonly logsDir: string;
  /** ~/Library/Application Support/Suica/update, as update.ts spells it. */
  readonly updateDir: string;
}

export interface CleanupJson {
  readonly version: 1;
  readonly status: "cleaned";
  readonly freedBytes: number;
}

/** Bytes under a file or folder; 0 when it is missing. Links are not followed. */
export function sizeOf(path: string): number {
  try {
    const stat = lstatSync(path);
    if (!stat.isDirectory()) return stat.size;
    return readdirSync(path).reduce((sum, name) => sum + sizeOf(join(path, name)), 0);
  } catch {
    return 0;
  }
}

/**
 * Deletes what the app can rebuild or no longer needs: the agent usage and exchange rate caches,
 * migration backups of the database, update downloads (unless an app waits to be swapped in),
 * leftover fix checkouts and the log files' contents, then compacts the database.
 * Config, templates, lessons usage and the database rows stay.
 */
export function cleanUp(store: Store, paths: CleanupPaths): CleanupJson {
  const dir = dirname(paths.statePath);
  const db = [paths.statePath, `${paths.statePath}-wal`, `${paths.statePath}-shm`];
  const backups = existsSync(dir)
    ? readdirSync(dir)
        .filter((name) => name.startsWith("state.db.before-"))
        .map((name) => join(dir, name))
    : [];
  const removed = [
    join(dir, "agent-usage-cache.json"),
    join(dir, "exchange-rate.json"),
    ...backups,
    // A staged app is an update the Owner has not relaunched into yet.
    ...(existsSync(join(paths.updateDir, "staged", "Suica.app")) ? [] : [paths.updateDir]),
  ];
  const logs = ["stdout.log", "stderr.log"].map((name) => join(paths.logsDir, name));
  const fixes = join(dir, "fixes");
  const measured = [...removed, ...logs, fixes, ...db];
  const before = measured.reduce((sum, path) => sum + sizeOf(path), 0);

  for (const path of removed) rmSync(path, { recursive: true, force: true });
  // launchd opens the logs for appending, so the agent keeps writing at the new end.
  for (const path of logs) if (existsSync(path)) truncateSync(path, 0);
  cleanFixDirs(store, paths.statePath);
  store.compact();

  const after = measured.reduce((sum, path) => sum + sizeOf(path), 0);
  return { version: 1, status: "cleaned", freedBytes: Math.max(0, before - after) };
}
