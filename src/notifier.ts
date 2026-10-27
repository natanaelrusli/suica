import { homedir } from "node:os";
import { join } from "node:path";
import { defaultExec, execFailure } from "./exec.ts";
import type { Exec } from "./exec.ts";
import type { Notification, NotificationAction } from "./format.ts";

export interface Notifier {
  notify(notification: Notification): Promise<void>;
}

const NOTIFY_TIMEOUT_MS = 10_000;
// A notification with buttons keeps terminal-notifier running until it is answered.
const ANSWER_TIMEOUT_SECONDS = 3600;
// Long enough for terminal-notifier to fail to start (missing, not authorised), short enough that
// the poll never waits for the Owner.
const LAUNCH_GRACE_MS = 1500;
const OPENABLE = /^(?:https?|suica):\/\//;

/**
 * The copy of terminal-notifier that scripts/install-macos-app.sh builds with the Suica icon:
 * macOS takes a notification's icon from the app that sends it.
 */
export function suicaNotifierPath(home = homedir()): string {
  return join(home, "Applications", "Suica Notifier.app", "Contents", "MacOS", "terminal-notifier");
}

export interface NotifierOptions {
  /** Notifier programs to try in order; the Suica one, then the plain `terminal-notifier`. */
  readonly binaries?: readonly string[];
  /** The command that runs the suica CLI, for buttons that act on an MR; they are left out without it. */
  readonly cli?: readonly string[];
  readonly launchGraceMs?: number;
}

/**
 * terminal-notifier reads option values through NSUserDefaults, which misreads a value starting
 * with `[`, `(`, `{` or a quote and exits 2. It strips one leading backslash, so always add one.
 */
function escapeValue(value: string): string {
  return `\\${value}`;
}

/** Button titles travel as one comma-separated option, so a title cannot hold a comma. */
function buttonTitle(action: NotificationAction): string {
  return action.title.replaceAll(",", " ");
}

/**
 * `terminal-notifier` when installed (a click opens the MR, buttons act on it), otherwise
 * `osascript` (no click-through, no buttons). Text always travels as process arguments, never
 * inside script source.
 */
export function createNotifier(exec: Exec = defaultExec, options: NotifierOptions = {}): Notifier {
  const binaries = options.binaries ?? [suicaNotifierPath(), "terminal-notifier"];
  const cli = options.cli;

  async function perform(action: NotificationAction): Promise<void> {
    if ("open" in action) {
      if (OPENABLE.test(action.open))
        await exec("open", [action.open], { timeoutMs: NOTIFY_TIMEOUT_MS });
      return;
    }
    const [program, ...prefix] = cli ?? [];
    if (program === undefined) return;
    await exec(program, [...prefix, ...action.suica], { timeoutMs: 60_000 });
  }

  async function respond(
    answer: string,
    actions: readonly NotificationAction[],
    url: string | undefined,
  ): Promise<void> {
    try {
      if (answer === "@ACTIONCLICKED") {
        if (url !== undefined) await perform({ title: "", open: url });
        return;
      }
      const chosen = actions.find((action) => buttonTitle(action) === answer);
      if (chosen !== undefined) await perform(chosen);
    } catch {
      // A button that fails has no one to tell: the Owner sees the unchanged MR in Suica.
    }
  }

  /** Starts the notification and returns once it is up, not once it is answered. */
  async function show(
    binary: string,
    notification: Notification,
    actions: readonly NotificationAction[],
  ): Promise<void> {
    const { title, body, url, sound } = notification;
    const args = [
      "-title",
      escapeValue(title),
      "-message",
      escapeValue(body),
      ...(sound === undefined ? [] : ["-sound", sound]),
    ];
    if (actions.length === 0) {
      await exec(binary, [...args, ...(url === undefined ? [] : ["-open", url])], {
        timeoutMs: NOTIFY_TIMEOUT_MS,
      });
      return;
    }
    // With buttons, terminal-notifier reports a click on the body itself instead of opening -open.
    const answered = exec(
      binary,
      [
        ...args,
        "-action",
        actions.map(buttonTitle).join(","),
        "-timeout",
        String(ANSWER_TIMEOUT_SECONDS),
      ],
      { timeoutMs: (ANSWER_TIMEOUT_SECONDS + 10) * 1000 },
    ).then(({ stdout }) => respond(stdout.trim(), actions, url));
    let timer: NodeJS.Timeout | undefined;
    const grace = new Promise<void>((resolve) => {
      timer = setTimeout(resolve, options.launchGraceMs ?? LAUNCH_GRACE_MS);
    });
    try {
      await Promise.race([answered, grace]);
    } finally {
      clearTimeout(timer);
    }
    // Past the grace period a later failure (the timeout, a dismissed banner) is not a delivery failure.
    answered.catch(() => undefined);
  }

  return {
    async notify(notification) {
      const { title, body } = notification;
      const actions = (notification.actions ?? []).filter(
        (action) => !("suica" in action) || cli !== undefined,
      );
      for (const [index, binary] of binaries.entries()) {
        try {
          await show(binary, notification, actions);
          return;
        } catch (error) {
          // The Suica notifier asks for its own permission: until it is granted, the next one shows.
          const last = index === binaries.length - 1;
          if (last && execFailure(error).code !== "ENOENT") throw error;
        }
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
