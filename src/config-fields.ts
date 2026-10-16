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
    path: ["statePath"],
    type: "string",
    label: "State file",
    help: "SQLite state file",
    placeholder: "~/Library/Application Support/suica/state.db",
    restartNote: "A new path starts with an empty history and a fresh baseline.",
  },
];
