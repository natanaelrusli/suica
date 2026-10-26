import {
  chmodSync,
  existsSync,
  mkdirSync,
  renameSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import type { Exec } from "../exec.ts";
import type { DetectedCli } from "../model-cli.ts";

/** `suica lessons install|uninstall|status`: the Claude Code hooks and the MCP server registrations. */

export const MCP_NAME = "suica-lessons";
const HOOK_MARKER = "lessons-hook.ts";
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

export interface InstallPlan {
  readonly settingsPath: string;
  readonly hooks: readonly { event: string; matcher: string }[];
  readonly mcp: readonly ("claude" | "codex")[];
}

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

export function hookCommand(paths: LessonsPaths): string {
  return `"${paths.node}" "${paths.hook}"`;
}

export function planInstall(home: string, clis: readonly DetectedCli[]): InstallPlan {
  const installed = (id: string) => clis.some((cli) => cli.id === id && cli.path !== null);
  return {
    settingsPath: settingsPathFor(home),
    hooks: HOOKS.map((hook) => ({ ...hook })),
    mcp: (["claude", "codex"] as const).filter(installed),
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

function render(settings: Json, original: string | undefined): string {
  const indent = original === undefined ? "  " : detectIndent(original);
  const newline = original === undefined || original.endsWith("\n") ? "\n" : "";
  return `${JSON.stringify(settings, null, indent)}${newline}`;
}

function isOurs(hook: unknown, command?: string): boolean {
  return (
    isObject(hook) &&
    typeof hook["command"] === "string" &&
    (hook["command"].includes(HOOK_MARKER) || hook["command"] === command)
  );
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

/** Our entry for `command`, placed where the first of our old entries for the event sat. */
export function installHooks(settingsText: string | undefined, command: string): string {
  const settings = settingsText === undefined ? {} : parseSettings(settingsText);
  const hooks = hooksOf(settings) ?? {};
  for (const spec of HOOKS) {
    const entry = { type: "command", command, timeout: HOOK_TIMEOUT_SECONDS };
    const groups = groupsOf(hooks, spec.event) ?? [];
    const next: unknown[] = [];
    let placed = false;
    for (const group of groups) {
      if (!isObject(group) || !Array.isArray(group["hooks"])) {
        next.push(group);
        continue;
      }
      const members: unknown[] = [];
      let touched = false;
      for (const hook of group["hooks"] as unknown[]) {
        if (!isOurs(hook)) {
          members.push(hook);
          continue;
        }
        touched = true;
        if (!placed && matcherOf(group) === spec.matcher) {
          members.push(entry);
          placed = true;
        }
      }
      // A group we emptied goes; one the user left empty stays.
      if (touched && members.length === 0) continue;
      next.push(touched ? { ...group, hooks: members } : group);
    }
    if (!placed) {
      const target = next.find(
        (group): group is Json =>
          isObject(group) && Array.isArray(group["hooks"]) && matcherOf(group) === spec.matcher,
      );
      if (target !== undefined) {
        (target["hooks"] as unknown[]).push(entry);
      } else {
        next.push(
          spec.matcher === "" ? { hooks: [entry] } : { matcher: spec.matcher, hooks: [entry] },
        );
      }
    }
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

function hasAllHooks(settingsText: string): boolean {
  const hooks = hooksOf(parseSettings(settingsText));
  if (hooks === undefined) return false;
  return HOOKS.every((spec) =>
    (groupsOf(hooks, spec.event) ?? []).some(
      (group) =>
        isObject(group) &&
        matcherOf(group) === spec.matcher &&
        Array.isArray(group["hooks"]) &&
        (group["hooks"] as unknown[]).some((hook) => isOurs(hook)),
    ),
  );
}

/** Temp file in the same folder, then rename; keeps the file's mode (0600 for a new file). */
export function writeSettingsAtomic(path: string, text: string): void {
  const existing = existsSync(path);
  const mode = existing ? statSync(path).mode & 0o777 : 0o600;
  mkdirSync(dirname(path), { recursive: true });
  const temp = join(dirname(path), `.settings.json.${process.pid}.${Date.now()}.tmp`);
  try {
    writeFileSync(temp, text, { mode });
    chmodSync(temp, mode);
    renameSync(temp, path);
  } catch (error) {
    rmSync(temp, { force: true });
    throw error;
  }
}

function readSettings(path: string): string | undefined {
  return existsSync(path) ? readFileSync(path, "utf8") : undefined;
}

export interface InstallResult {
  readonly status: "installed" | "invalid-settings";
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

export function mcpCommands(id: "claude" | "codex", paths: LessonsPaths): string[] {
  const { add } = mcpArgs(id, paths);
  return [`${id} ${add.join(" ")}`];
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
  const current = readSettings(settingsPath);
  let next: string;
  try {
    next = installHooks(current, hookCommand(paths));
  } catch (error) {
    if (error instanceof InvalidSettings) {
      return {
        status: "invalid-settings",
        settingsPath,
        changed: false,
        registered: [],
        skipped: [],
        failed: [],
      };
    }
    throw error;
  }
  const changed = next !== current;
  if (changed) writeSettingsAtomic(settingsPath, next);
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
  return { status: "installed", settingsPath, changed, registered, skipped, failed };
}

export interface UninstallResult {
  readonly status: "uninstalled" | "invalid-settings";
  readonly hookRemoved: boolean;
  readonly removed: readonly string[];
}

export async function applyUninstall(
  home: string,
  exec: Exec,
  clis: readonly DetectedCli[],
  paths: LessonsPaths,
): Promise<UninstallResult> {
  const settingsPath = settingsPathFor(home);
  const current = readSettings(settingsPath);
  let hookRemoved = false;
  if (current !== undefined) {
    try {
      const next = uninstallHooks(current, hookCommand(paths));
      if (next !== current) {
        writeSettingsAtomic(settingsPath, next);
        hookRemoved = true;
      }
    } catch (error) {
      if (error instanceof InvalidSettings)
        return { status: "invalid-settings", hookRemoved: false, removed: [] };
      throw error;
    }
  }
  const removed: string[] = [];
  for (const id of ["claude", "codex"] as const) {
    const bin = pathOf(clis, id);
    if (bin === null) continue;
    try {
      await exec(bin, mcpArgs(id, paths).remove, { timeoutMs: CLI_TIMEOUT_MS });
      removed.push(id);
    } catch {
      // Not registered.
    }
  }
  return { status: "uninstalled", hookRemoved, removed };
}

export interface LessonsStatus {
  readonly hook: boolean;
  readonly mcp: { readonly claude: boolean; readonly codex: boolean };
}

async function registered(exec: Exec, bin: string | null): Promise<boolean> {
  if (bin === null) return false;
  try {
    const { stdout } = await exec(bin, ["mcp", "list"], { timeoutMs: CLI_TIMEOUT_MS });
    return stdout.split("\n").some((line) => line.trimStart().startsWith(MCP_NAME));
  } catch {
    return false;
  }
}

/** Best effort: anything that cannot be read counts as not installed. */
export async function lessonsStatus(
  home: string,
  exec: Exec,
  clis: readonly DetectedCli[],
): Promise<LessonsStatus> {
  let hook = false;
  try {
    const text = readSettings(settingsPathFor(home));
    hook = text !== undefined && hasAllHooks(text);
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
