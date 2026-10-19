import { MODEL_CLI_CHOICES } from "./model-cli.ts";

export type FieldType =
  "string" | "int" | "bool" | "enum" | "clock" | "weekdays" | "stringList" | "emailMap";

export interface ConfigField {
  readonly path: readonly string[];
  readonly type: FieldType;
  readonly label: string;
  readonly help: string;
  readonly options?: readonly string[]; // enum only
  readonly placeholder?: string; // optional keys whose default is computed at runtime
  readonly restartNote?: string;
}

const SEND_MODES = ["auto", "approval", "dry-run"] as const;

/** Every leaf of the config schema in README table order; config-fields.test.ts keeps it in sync. */
export const CONFIG_FIELDS: readonly ConfigField[] = [
  {
    path: ["gitlab", "hostname"],
    type: "string",
    label: "GitLab host",
    help: "GitLab host passed to glab --hostname",
  },
  {
    path: ["gitlab", "glabPath"],
    type: "string",
    label: "glab executable",
    help: "glab executable",
  },
  {
    path: ["gitlab", "timeoutSeconds"],
    type: "int",
    label: "glab timeout (seconds)",
    help: "Timeout for one glab call",
  },
  {
    path: ["polling", "activeSeconds"],
    type: "int",
    label: "Active poll interval (seconds)",
    help: "Poll interval while you are at the Mac",
  },
  {
    path: ["polling", "idleSeconds"],
    type: "int",
    label: "Idle poll interval (seconds)",
    help: "Poll interval while idle",
  },
  {
    path: ["polling", "idleAfterSeconds"],
    type: "int",
    label: "Idle after (seconds)",
    help: "No keyboard or mouse input for this long counts as idle",
  },
  {
    path: ["polling", "maxBackoffSeconds"],
    type: "int",
    label: "Maximum backoff (seconds)",
    help: "Cap for the exponential backoff after failed polls",
  },
  {
    path: ["notifications", "summaryThreshold"],
    type: "int",
    label: "Summary threshold",
    help: "More notifications than this in one poll become one summary",
  },
  {
    path: ["notifications", "ignoreAuthors"],
    type: "stringList",
    label: "Ignored authors",
    help: "GitLab usernames whose comments never alert (for example bots)",
  },
  {
    path: ["teams", "enabled"],
    type: "bool",
    label: "Teams enabled",
    help: "Switch the Teams flows on",
  },
  {
    path: ["teams", "command"],
    type: "string",
    label: "Teams MCP command",
    help: "Command that starts the Teams MCP server",
    placeholder: "~/.config/teams-mcp/run.sh",
  },
  {
    path: ["teams", "startTimeoutSeconds"],
    type: "int",
    label: "Teams start timeout (seconds)",
    help: "Timeout for the Teams MCP to start",
  },
  {
    path: ["teams", "callTimeoutSeconds"],
    type: "int",
    label: "Teams call timeout (seconds)",
    help: "Timeout for one Teams MCP call",
  },
  {
    path: ["teams", "modes", "nudge"],
    type: "enum",
    label: "Nudge mode",
    help: "How the nudge flow sends: auto, approval or dry-run",
    options: SEND_MODES,
  },
  {
    path: ["teams", "modes", "notice"],
    type: "enum",
    label: "Notice mode",
    help: "How the Review Notice flow sends: auto, approval or dry-run",
    options: SEND_MODES,
  },
  {
    path: ["teams", "modes", "rereview"],
    type: "enum",
    label: "Re-review mode",
    help: "How the Re-review Nudge flow sends: auto, approval or dry-run",
    options: SEND_MODES,
  },
  {
    path: ["teams", "workingHours", "start"],
    type: "clock",
    label: "Working hours start",
    help: "Messages only go out inside these hours (Mac local time)",
  },
  {
    path: ["teams", "workingHours", "end"],
    type: "clock",
    label: "Working hours end",
    help: "Messages only go out inside these hours (Mac local time)",
  },
  {
    path: ["teams", "workingHours", "days"],
    type: "weekdays",
    label: "Working days",
    help: "ISO weekdays, Monday is 1 and Sunday is 7",
  },
  {
    path: ["teams", "reminderAfterHours"],
    type: "int",
    label: "Reminder after (hours)",
    help: "Reminder if the Reviewer is still UNREVIEWED this long after the nudge",
  },
  {
    path: ["teams", "noticeDebounceMinutes"],
    type: "int",
    label: "Notice debounce (minutes)",
    help: "Review Notice after this long without further change by you",
  },
  {
    path: ["teams", "rereviewAfterMinutes"],
    type: "int",
    label: "Re-review after (minutes)",
    help: "Re-review Nudge after your latest push has stood this long without a newer one",
  },
  {
    path: ["teams", "maxMessagesPerReviewer"],
    type: "int",
    label: "Messages per Reviewer",
    help: "At most this many messages per MR per Reviewer",
  },
  {
    path: ["teams", "templatesPath"],
    type: "string",
    label: "Templates folder",
    help: "Folder with template files",
    placeholder: "~/.config/suica/templates",
  },
  {
    path: ["teams", "people"],
    type: "emailMap",
    label: "People",
    help: "GitLab username to email, for people Teams cannot find by name",
  },
  {
    path: ["model", "cli"],
    type: "enum",
    label: "Model CLI",
    help: "Which coding agent CLI runs language model work: auto (the first installed of claude, codex, gemini), claude, codex or gemini",
    options: MODEL_CLI_CHOICES,
  },
  {
    path: ["review", "auto"],
    type: "bool",
    label: "Review automatically",
    help: "Review every MR waiting for you that the agent has not reviewed yet, oldest first, and again after a new Review Request; reviews wait in the app until you post them",
  },
  {
    path: ["review", "post"],
    type: "enum",
    label: "Posting",
    help: "approval: a ready review waits until you post it; auto: it is posted to GitLab as you as soon as it is ready",
    options: ["approval", "auto"],
  },
  {
    path: ["review", "postAs"],
    type: "enum",
    label: "Post as",
    help: "comment: the review is one comment on the MR; inline: each finding that names a line of the reviewed diff becomes a thread on that line, and the rest is one comment. The app asks each time; automatic posting and suica review post use this",
    options: ["comment", "inline"],
  },
  {
    path: ["review", "skill"],
    type: "string",
    label: "Review skill",
    help: "Claude Code skill the review follows, as typed after the slash (plugin:skill)",
  },
  {
    path: ["review", "model"],
    type: "string",
    label: "Review model",
    help: "Model the CLI reviews with, such as sonnet, opus or haiku for Claude Code, or a full model name; empty uses the CLI's default",
    placeholder: "CLI default",
  },
  {
    path: ["review", "maxChangedLines"],
    type: "int",
    label: "Largest MR (changed lines)",
    help: "Larger MRs are skipped",
  },
  {
    path: ["review", "maxPerDay"],
    type: "int",
    label: "Automatic reviews per day",
    help: "At most this many automatic reviews in 24 hours; reviews you start yourself do not count",
  },
  {
    path: ["review", "timeoutMinutes"],
    type: "int",
    label: "Review timeout (minutes)",
    help: "A review run is stopped after this long",
  },
  {
    path: ["statePath"],
    type: "string",
    label: "State file",
    help: "SQLite state file",
    placeholder: "~/Library/Application Support/suica/state.db",
    restartNote: "A new path starts with an empty history and a fresh baseline.",
  },
];
