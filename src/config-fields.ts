import { FIX_WATCH } from "./config.ts";
import { APPROVE_BY } from "./approval-judge.ts";
import { APPROVE_WHEN } from "./inline-review.ts";
import { MODEL_CLI_CHOICES } from "./model-cli.ts";
import { REVIEW_EFFORTS } from "./review-runner.ts";

/** `level`: an `enum` whose options run from least to most, shown as a slider. */
export type FieldType =
  "string" | "int" | "bool" | "enum" | "level" | "clock" | "weekdays" | "stringList" | "emailMap";

export interface ConfigField {
  readonly path: readonly string[];
  readonly type: FieldType;
  readonly label: string;
  readonly help: string;
  readonly options?: readonly string[]; // enum and level only
  /** int only: what the number counts; seconds, minutes and hours make it a duration. */
  readonly unit?: string;
  /** int only, when the schema caps it; every int is at least 1. */
  readonly max?: number;
  /** string only: a host name (no scheme) or a file or folder path, for the editor's input. */
  readonly format?: "hostname" | "path";
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
    format: "hostname",
  },
  {
    path: ["gitlab", "glabPath"],
    type: "string",
    label: "glab executable",
    help: "glab executable",
    format: "path",
  },
  {
    path: ["gitlab", "timeoutSeconds"],
    type: "int",
    label: "glab timeout",
    help: "Timeout for one glab call",
    unit: "seconds",
  },
  {
    path: ["polling", "activeSeconds"],
    type: "int",
    label: "Active poll interval",
    help: "Poll interval while you are at the Mac",
    unit: "seconds",
  },
  {
    path: ["polling", "idleSeconds"],
    type: "int",
    label: "Idle poll interval",
    help: "Poll interval while idle",
    unit: "seconds",
  },
  {
    path: ["polling", "idleAfterSeconds"],
    type: "int",
    label: "Idle after",
    help: "No keyboard or mouse input for this long counts as idle",
    unit: "seconds",
  },
  {
    path: ["polling", "maxBackoffSeconds"],
    type: "int",
    label: "Maximum backoff",
    help: "Cap for the exponential backoff after failed polls",
    unit: "seconds",
  },
  {
    path: ["notifications", "summaryThreshold"],
    type: "int",
    label: "Summary threshold",
    help: "More notifications than this in one poll become one summary",
    unit: "notifications",
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
    format: "path",
  },
  {
    path: ["teams", "startTimeoutSeconds"],
    type: "int",
    label: "Teams start timeout",
    help: "Timeout for the Teams MCP to start",
    unit: "seconds",
  },
  {
    path: ["teams", "callTimeoutSeconds"],
    type: "int",
    label: "Teams call timeout",
    help: "Timeout for one Teams MCP call",
    unit: "seconds",
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
    path: ["teams", "modes", "findings"],
    type: "enum",
    label: "Findings notice mode",
    help: "How the Review Notice with an Agent Review's findings sends: auto, approval or dry-run",
    options: SEND_MODES,
  },
  {
    path: ["teams", "modes", "approved"],
    type: "enum",
    label: "Approval notice mode",
    help: "How the Review Notice after you approve an MR sends: auto, approval or dry-run. It goes out at the first poll that sees the approval",
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
    label: "Reminder after",
    help: "Reminder if the Reviewer is still UNREVIEWED this long after the nudge",
    unit: "hours",
  },
  {
    path: ["teams", "noticeDebounceMinutes"],
    type: "int",
    label: "Notice debounce",
    help: "Review Notice after this long without further change by you",
    unit: "minutes",
  },
  {
    path: ["teams", "rereviewAfterMinutes"],
    type: "int",
    label: "Re-review after",
    help: "Re-review Nudge after your latest push has stood this long without a newer one",
    unit: "minutes",
  },
  {
    path: ["teams", "maxMessagesPerReviewer"],
    type: "int",
    label: "Messages per Reviewer",
    help: "At most this many messages per MR per Reviewer",
    unit: "messages",
  },
  {
    path: ["teams", "templatesPath"],
    type: "string",
    label: "Templates folder",
    help: "Folder with template files",
    placeholder: "~/.config/suica/templates",
    format: "path",
  },
  {
    path: ["teams", "people"],
    type: "emailMap",
    label: "People",
    help: "GitLab username to email, for people Teams cannot find by name",
  },
  {
    path: ["teams", "agentName"],
    type: "string",
    label: "Agent name",
    help: "The name the agent introduces itself with in Teams messages ({{agent.name}})",
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
    help: "Review every MR waiting for you that the agent has not reviewed yet, oldest first, and again after a new Review Request; reviews wait in the app until you post them, apart from one the agent approves (review.approve)",
  },
  {
    path: ["review", "post"],
    type: "enum",
    label: "Posting",
    help: "approval: a ready review waits until you post it, unless the agent approves it (review.approve); auto: it is posted to GitLab as you as soon as it is ready",
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
    path: ["review", "approve"],
    type: "bool",
    label: "Approve automatically when ready",
    help: "Approve the MR as you at the reviewed commit, and resolve your threads, once an Agent Review is ready to approve (review.approveWhen). Such a review is posted at once, even with Posting set to approval. Off: approve with one click in the app",
  },
  {
    path: ["review", "approveWhen"],
    type: "enum",
    label: "Ready to approve when",
    help: "What a review may leave and still be ready to approve: minor (only Minor or Nit findings), nit (only Nit findings) or clean (no findings). Open items of a re-review's Previous review section count the same way",
    options: APPROVE_WHEN,
  },
  {
    path: ["review", "approveBy"],
    type: "enum",
    label: "Ready to approve decided by",
    help: "agent: a second model run reads the review and decides by Ready to approve when and your approval rules, and never approves when it fails; rules: the review's severity headings decide",
    options: APPROVE_BY,
  },
  {
    path: ["review", "approveRules"],
    type: "stringList",
    label: "Approval rules",
    help: "Your own rules for the agent that decides, one per line; they win over Ready to approve when. For example: A Major the Author documents as an accepted risk does not hold up approval",
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
    path: ["review", "effort"],
    type: "level",
    label: "Review effort",
    help: "How hard the CLI thinks during a review: claude --effort, or Codex reasoning effort (max is xhigh there). Higher levels take longer and use more tokens",
    options: REVIEW_EFFORTS,
  },
  {
    path: ["review", "maxChangedLines"],
    type: "int",
    label: "Largest MR",
    help: "Larger MRs are skipped",
    unit: "changed lines",
  },
  {
    path: ["review", "maxPerDay"],
    type: "int",
    label: "Automatic reviews per day",
    help: "At most this many automatic reviews in 24 hours; reviews you start yourself do not count",
    unit: "reviews",
  },
  {
    path: ["review", "rereviewAfterMinutes"],
    type: "int",
    label: "Re-review after",
    help: "Re-review an MR after the Author's latest push has stood this long without a newer one",
    unit: "minutes",
  },
  {
    path: ["review", "timeoutMinutes"],
    type: "int",
    label: "Review timeout",
    help: "A review run is stopped after this long",
    unit: "minutes",
  },
  {
    path: ["review", "concurrency"],
    type: "int",
    label: "Reviews at once",
    help: "How many Agent Reviews run at the same time, 1 to 4, each with its own CLI process and checkout",
    unit: "reviews",
    max: 4,
  },
  {
    path: ["fix", "auto"],
    type: "bool",
    label: "Watch my MRs",
    help: "Answer new Reviewer threads on your own MRs with an Agent Fix until the MR is approved. A fix waits for you: nothing is committed, pushed or replied before you confirm",
  },
  {
    path: ["fix", "watch"],
    type: "enum",
    label: "Which MRs to watch",
    help: "all: every MR of yours is watched unless you press Unwatch on it. chosen: only MRs you press Watch on. Fix findings now works on every MR either way",
    options: FIX_WATCH,
  },
  {
    path: ["fix", "pipelines"],
    type: "bool",
    label: "Fix failed pipelines",
    help: "With Watch my MRs on, also start an Agent Fix when the head pipeline of one of your MRs fails. It reads the failed jobs' logs and waits for you like any fix",
  },
  {
    path: ["fix", "model"],
    type: "string",
    label: "Fix model",
    help: "Model the CLI writes fixes with, such as sonnet, opus or haiku for Claude Code, or a full model name; empty uses the CLI's default",
    placeholder: "CLI default",
  },
  {
    path: ["fix", "effort"],
    type: "level",
    label: "Fix effort",
    help: "How hard the CLI thinks during a fix: claude --effort, or Codex reasoning effort (max is xhigh there). Higher levels take longer and use more tokens",
    options: REVIEW_EFFORTS,
  },
  {
    path: ["fix", "timeoutMinutes"],
    type: "int",
    label: "Fix timeout",
    help: "A fix run is stopped after this long",
    unit: "minutes",
  },
  {
    path: ["fix", "maxPerDay"],
    type: "int",
    label: "Automatic fixes per day",
    help: "At most this many automatic fixes in 24 hours; fixes you start yourself do not count",
    unit: "fixes",
  },
  {
    path: ["office", "agents"],
    type: "stringList",
    label: "Coding agents to show",
    help: "Which agents the Office looks for on this Mac: claude, codex and gemini",
  },
  {
    path: ["office", "custom"],
    type: "stringList",
    label: "More coding agents",
    help: "One per line as name|process|log glob|cwd key|activity key: the program's name, a JSONL log pattern such as ~/.aider/*.jsonl, and the dotted keys of the working folder and the activity in a log line",
  },
  {
    path: ["statePath"],
    type: "string",
    label: "State file",
    help: "SQLite state file",
    placeholder: "~/Library/Application Support/suica/state.db",
    restartNote: "A new path starts with an empty history and a fresh baseline.",
    format: "path",
  },
];
