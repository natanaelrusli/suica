import { defaultExec, execFailure } from "./exec.ts";
import type { Exec } from "./exec.ts";
import type { Notification } from "./format.ts";

export interface Notifier {
  notify(notification: Notification): Promise<void>;
}

const NOTIFY_TIMEOUT_MS = 10_000;

/**
 * terminal-notifier reads option values through NSUserDefaults, which misreads a value starting
 * with `[`, `(`, `{` or a quote and exits 2. It strips one leading backslash, so always add one.
 */
function escapeValue(value: string): string {
  return `\\${value}`;
}

/**
 * `terminal-notifier` when installed (a click opens the MR), otherwise `osascript`
 * (no click-through). Text always travels as process arguments, never inside script source.
 */
export function createNotifier(exec: Exec = defaultExec): Notifier {
  return {
    async notify(notification) {
      const { title, body, url } = notification;
      try {
        await exec(
          "terminal-notifier",
          [
            "-title",
            escapeValue(title),
            "-message",
            escapeValue(body),
            ...(url === undefined ? [] : ["-open", url]),
          ],
          { timeoutMs: NOTIFY_TIMEOUT_MS },
        );
        return;
      } catch (error) {
        if (execFailure(error).code !== "ENOENT") throw error;
      }
      await exec(
        "osascript",
        [
          "-e",
          "on run argv",
          "-e",
          "display notification (item 2 of argv) with title (item 1 of argv)",
          "-e",
          "end run",
          title,
          body,
        ],
        { timeoutMs: NOTIFY_TIMEOUT_MS },
      );
    },
  };
}
