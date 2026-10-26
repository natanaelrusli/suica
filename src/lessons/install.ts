import {
  chmodSync,
  lstatSync,
  realpathSync,
  mkdirSync,
  renameSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { execFailure } from "../exec.ts";
import type { Exec } from "../exec.ts";
import type { DetectedCli } from "../model-cli.ts";

/** `suica lessons install|uninstall|status`: the Claude Code hooks and the MCP server registrations. */

export const MCP_NAME = "suica-lessons";
const CLI_TIMEOUT_MS = 30_000;
const HOOK_TIMEOUT_SECONDS = 5;

export class InvalidSettings extends Error {
  constructor(message: string) {
    super(message);
    this.name = "InvalidSettings";
  }
}

interface HookSpec {
  readonly event: string;
  readonly matcher: string;
}

const HOOKS: readonly HookSpec[] = [
  { event: "SessionStart", matcher: "" },
  { event: "PostToolUse", matcher: "Read" },
  { event: "PreToolUse", matcher: "Write|Edit|MultiEdit" },
];

/** settings.json cannot be read (permissions, a folder in its place). */
export class UnreadableSettings extends Error {
  constructor(message: string) {
    super(message);
    this.name = "UnreadableSettings";
  }
}

export interface InstallPlan {
  readonly settingsPath: string;
  readonly hooks: readonly { event: string; matcher: string }[];
  readonly mcp: readonly ("claude" | "codex")[];
  /** The hook command written into settings.json. */
  readonly command: string;
  /** Every CLI call that would run, in order: each `remove` precedes its `add`. */
  readonly commands: readonly string[];
  readonly note: string;
}

const REWRITE_NOTE =
  "settings.json is rewritten as formatted JSON: its keys and hooks are kept, but comments and unusual spacing are not.";

export interface LessonsPaths {
  readonly node: string;
  /** Absolute path of `src/cli.ts` in this installation. */
  readonly cli: string;
  /** Absolute path of `src/lessons-hook.ts` in this installation. */
  readonly hook: string;
}

export function settingsPathFor(home: string): string {
  return join(home, ".claude", "settings.json");
}

/** Single quotes keep spaces, `"`, `$` and backticks literal; an inner `'` becomes `'\\''`. */
function shellQuote(path: string): string {
  return `'${path.replaceAll("'", "'\\''")}'`;
}

export function hookCommand(paths: LessonsPaths): string {
  return `${shellQuote(paths.node)} ${shellQuote(paths.hook)}`;
}

const SINGLE_QUOTED = String.raw`'(?:[^']|'\\'')*'`;
/** Our shape: the current single-quoted form, or the earlier double-quoted one. */
const OUR_COMMAND = new RegExp(
  `^(?:${SINGLE_QUOTED} '(?:[^']|'\\\\'')*/src/lessons-hook\\.ts'|"[^"]*" "[^"]*/src/lessons-hook\\.ts")$`,
);

export function planInstall(
  home: string,
  clis: readonly DetectedCli[],
  paths: LessonsPaths,
): InstallPlan {
  const installed = (id: string) => clis.some((cli) => cli.id === id && cli.path !== null);
  const mcp = (["claude", "codex"] as const).filter(installed);
  return {
    settingsPath: settingsPathFor(home),
    hooks: HOOKS.map((hook) => ({ ...hook })),
    mcp,
    command: hookCommand(paths),
    commands: mcp.flatMap((id) => {
      const { remove, add } = mcpArgs(id, paths);
      return [`${id} ${remove.join(" ")}`, `${id} ${add.join(" ")}`];
    }),
    note: REWRITE_NOTE,
  };
}

type Json = Record<string, unknown>;

function isObject(value: unknown): value is Json {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseSettings(text: string): Json {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new InvalidSettings("settings.json is not valid JSON");
  }
  if (!isObject(parsed)) throw new InvalidSettings("settings.json is not a JSON object");
  return parsed;
}

/** The file's own indentation, 2 spaces when it has none to copy. */
function detectIndent(text: string): string {
  const found = /^([ \t]+)"/m.exec(text);
  return found?.[1] ?? "  ";
}

// The file is re-serialised, so comments-free JSON is kept as the same value but its text may be
// reformatted (indentation and trailing newline are preserved).
function render(settings: Json, original: string | undefined): string {
  const indent = original === undefined ? "  " : detectIndent(original);
  const newline = original === undefined || original.endsWith("\n") ? "\n" : "";
  return `${JSON.stringify(settings, null, indent)}${newline}`;
}

function isOurs(hook: unknown, command?: string): boolean {
  if (!isObject(hook) || hook["type"] !== "command" || typeof hook["command"] !== "string") {
    return false;
  }
  return hook["command"] === command || OUR_COMMAND.test(hook["command"]);
}

function matcherOf(group: Json): string {
  return typeof group["matcher"] === "string" ? group["matcher"] : "";
}

function hooksOf(settings: Json): Json | undefined {
  const hooks = settings["hooks"];
  if (hooks === undefined) return undefined;
  if (!isObject(hooks)) throw new InvalidSettings('"hooks" is not an object');
  return hooks;
}

function groupsOf(hooks: Json, event: string): unknown[] | undefined {
  const groups = hooks[event];
  if (groups === undefined) return undefined;
  if (!Array.isArray(groups)) throw new InvalidSettings(`"hooks.${event}" is not an array`);
  return groups as unknown[];
}

/**
 * Our own group per event, never merged into a user's: an old group made only of our entries is
 * replaced where it stood, ours inside a mixed group are dropped, and a new group is appended
 * when none was there.
 */
export function installHooks(settingsText: string | undefined, command: string): string {
  const settings = settingsText === undefined ? {} : parseSettings(settingsText);
  const hooks = hooksOf(settings) ?? {};
  for (const spec of HOOKS) {
    const entry = { type: "command", command, timeout: HOOK_TIMEOUT_SECONDS };
    const fresh =
      spec.matcher === "" ? { hooks: [entry] } : { matcher: spec.matcher, hooks: [entry] };
    const next: unknown[] = [];
    let placed = false;
    for (const group of groupsOf(hooks, spec.event) ?? []) {
      if (!isObject(group) || !Array.isArray(group["hooks"])) {
        next.push(group);
        continue;
      }
      const members = (group["hooks"] as unknown[]).filter((hook) => !isOurs(hook, command));
      if (members.length === (group["hooks"] as unknown[]).length) {
        next.push(group);
      } else if (members.length > 0) {
        next.push({ ...group, hooks: members });
      } else if (!placed && matcherOf(group) === spec.matcher) {
        next.push(fresh);
        placed = true;
      }
    }
    if (!placed) next.push(fresh);
    hooks[spec.event] = next;
  }
  settings["hooks"] = hooks;
  return render(settings, settingsText);
}

/** Removes only our entries, and only the groups, arrays and keys that removal emptied. */
export function uninstallHooks(settingsText: string, command: string): string {
  const settings = parseSettings(settingsText);
  const hooks = hooksOf(settings);
  if (hooks === undefined) return settingsText;
  let changed = false;
  let hooksEmptied = false;
  for (const event of Object.keys(hooks)) {
    const groups = groupsOf(hooks, event);
    if (groups === undefined) continue;
    const next: unknown[] = [];
    let eventTouched = false;
    for (const group of groups) {
      if (!isObject(group) || !Array.isArray(group["hooks"])) {
        next.push(group);
        continue;
      }
      const members = (group["hooks"] as unknown[]).filter((hook) => !isOurs(hook, command));
      if (members.length === (group["hooks"] as unknown[]).length) {
        next.push(group);
        continue;
      }
      eventTouched = true;
      if (members.length > 0) next.push({ ...group, hooks: members });
    }
    if (!eventTouched) continue;
    changed = true;
    if (next.length === 0) {
      delete hooks[event];
      hooksEmptied = true;
    } else {
      hooks[event] = next;
    }
  }
  if (!changed) return settingsText;
  if (hooksEmptied && Object.keys(hooks).length === 0) delete settings["hooks"];
  return render(settings, settingsText);
}

function hasAllHooks(settingsText: string, command: string): boolean {
  const hooks = hooksOf(parseSettings(settingsText));
  if (hooks === undefined) return false;
  return HOOKS.every((spec) =>
    (groupsOf(hooks, spec.event) ?? []).some(
      (group) =>
        isObject(group) &&
        matcherOf(group) === spec.matcher &&
        Array.isArray(group["hooks"]) &&
        (group["hooks"] as unknown[]).some(
          (hook) => isOurs(hook) && isObject(hook) && hook["command"] === command,
        ),
    ),
  );
}

/**
 * Where settings.json really lives: a symlink (dotfiles) is followed so the link stays a link.
 * A link to nothing is refused rather than creating its target.
 */
function resolveTarget(path: string): string {
  let info;
  try {
    info = lstatSync(path);
  } catch (error) {
    if (execFailure(error).code === "ENOENT") return path;
    throw new UnreadableSettings(String(error));
  }
  if (!info.isSymbolicLink()) return path;
  try {
    return realpathSync(path);
  } catch {
    throw new InvalidSettings("settings.json is a symlink to a file that does not exist");
  }
}

/** Temp file in the target's folder, then rename; keeps the target's mode (0600 for a new file). */
export function writeSettingsAtomic(path: string, text: string): void {
  const target = resolveTarget(path);
  let mode = 0o600;
  try {
    mode = statSync(target).mode & 0o777;
  } catch {
    // A new file.
  }
  mkdirSync(dirname(target), { recursive: true });
  const temp = join(dirname(target), `.settings.json.${process.pid}.${Date.now()}.tmp`);
  try {
    writeFileSync(temp, text, { mode, flag: "wx" });
    chmodSync(temp, mode);
    renameSync(temp, target);
  } catch (error) {
    rmSync(temp, { force: true });
    throw error;
  }
}

/** The text of settings.json, undefined when absent; other failures become UnreadableSettings. */
function readSettings(path: string): string | undefined {
  const target = resolveTarget(path);
  try {
    return readFileSync(target, "utf8");
  } catch (error) {
    if (execFailure(error).code === "ENOENT") return undefined;
    throw new UnreadableSettings(String(error));
  }
}

type SettingsError = "invalid-settings" | "unreadable-settings";

function settingsError(error: unknown): SettingsError {
  if (error instanceof InvalidSettings) return "invalid-settings";
  if (error instanceof UnreadableSettings) return "unreadable-settings";
  throw error;
}

export interface InstallResult {
  readonly status: "installed" | "partial" | SettingsError;
  readonly settingsPath: string;
  /** False when settings.json already had exactly our entries. */
  readonly changed: boolean;
  readonly registered: readonly string[];
  readonly skipped: readonly string[];
  readonly failed: readonly string[];
}

function mcpArgs(id: "claude" | "codex", paths: LessonsPaths): { remove: string[]; add: string[] } {
  const scope = id === "claude" ? ["--scope", "user"] : [];
  return {
    remove: ["mcp", "remove", ...scope, MCP_NAME],
    add: ["mcp", "add", ...scope, MCP_NAME, "--", paths.node, paths.cli, "lessons", "mcp"],
  };
}

function pathOf(clis: readonly DetectedCli[], id: string): string | null {
  return clis.find((cli) => cli.id === id)?.path ?? null;
}

/** Writes the hooks (never over unparseable settings), then registers the server with each CLI found. */
export async function applyInstall(
  home: string,
  exec: Exec,
  clis: readonly DetectedCli[],
  paths: LessonsPaths,
): Promise<InstallResult> {
  const settingsPath = settingsPathFor(home);
  const refused = (status: SettingsError): InstallResult => ({
    status,
    settingsPath,
    changed: false,
    registered: [],
    skipped: [],
    failed: [],
  });
  let current: string | undefined;
  let next: string;
  try {
    current = readSettings(settingsPath);
    next = installHooks(current, hookCommand(paths));
    if (next !== current) writeSettingsAtomic(settingsPath, next);
  } catch (error) {
    return refused(settingsError(error));
  }
  const registered: string[] = [];
  const skipped: string[] = [];
  const failed: string[] = [];
  for (const id of ["claude", "codex"] as const) {
    const bin = pathOf(clis, id);
    if (bin === null) {
      skipped.push(id);
      continue;
    }
    const args = mcpArgs(id, paths);
    try {
      await exec(bin, args.remove, { timeoutMs: CLI_TIMEOUT_MS });
    } catch {
      // Not registered yet is the normal case.
    }
    try {
      await exec(bin, args.add, { timeoutMs: CLI_TIMEOUT_MS });
      registered.push(id);
    } catch {
      failed.push(id);
    }
  }
  if (pathOf(clis, "gemini") !== null) skipped.push("gemini");
  return {
    status: failed.length > 0 ? "partial" : "installed",
    settingsPath,
    changed: next !== current,
    registered,
    skipped,
    failed,
  };
}

export interface UninstallResult {
  readonly status: "uninstalled" | "partial" | SettingsError;
  readonly hookRemoved: boolean;
  readonly removed: readonly string[];
  readonly failed: readonly string[];
}

/** A `remove` that failed only because the server was not registered. */
function wasNotRegistered(error: unknown): boolean {
  const text = `${execFailure(error).stderr ?? ""}\n${error instanceof Error ? error.message : ""}`;
  return /not found|no mcp server|no server|does not exist|not registered|unknown server/i.test(
    text,
  );
}

export async function applyUninstall(
  home: string,
  exec: Exec,
  clis: readonly DetectedCli[],
  paths: LessonsPaths,
): Promise<UninstallResult> {
  const settingsPath = settingsPathFor(home);
  let hookRemoved = false;
  try {
    const current = readSettings(settingsPath);
    if (current !== undefined) {
      const next = uninstallHooks(current, hookCommand(paths));
      if (next !== current) {
        writeSettingsAtomic(settingsPath, next);
        hookRemoved = true;
      }
    }
  } catch (error) {
    return { status: settingsError(error), hookRemoved: false, removed: [], failed: [] };
  }
  const removed: string[] = [];
  const failed: string[] = [];
  for (const id of ["claude", "codex"] as const) {
    const bin = pathOf(clis, id);
    if (bin === null) continue;
    try {
      await exec(bin, mcpArgs(id, paths).remove, { timeoutMs: CLI_TIMEOUT_MS });
      removed.push(id);
    } catch (error) {
      if (!wasNotRegistered(error)) failed.push(id);
    }
  }
  return { status: failed.length > 0 ? "partial" : "uninstalled", hookRemoved, removed, failed };
}

export interface LessonsStatus {
  readonly hook: boolean;
  readonly mcp: { readonly claude: boolean; readonly codex: boolean };
}

async function registered(exec: Exec, bin: string | null): Promise<boolean> {
  if (bin === null) return false;
  try {
    const { stdout } = await exec(bin, ["mcp", "list"], { timeoutMs: CLI_TIMEOUT_MS });
    return stdout.split("\n").some((line) => line.trimStart().split(/[\s:]/)[0] === MCP_NAME);
  } catch {
    return false;
  }
}

/** Best effort: anything that cannot be read counts as not installed. `hook` needs this install's command. */
export async function lessonsStatus(
  home: string,
  exec: Exec,
  clis: readonly DetectedCli[],
  paths: LessonsPaths,
): Promise<LessonsStatus> {
  let hook = false;
  try {
    const text = readSettings(settingsPathFor(home));
    hook = text !== undefined && hasAllHooks(text, hookCommand(paths));
  } catch {
    hook = false;
  }
  return {
    hook,
    mcp: {
      claude: await registered(exec, pathOf(clis, "claude")),
      codex: await registered(exec, pathOf(clis, "codex")),
    },
  };
}
