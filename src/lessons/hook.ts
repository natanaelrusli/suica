// The Claude Code hook's answer: Lessons as context when a session starts and per file the agent
// reads or writes. Pure apart from the seen store's files; it never answers a permission decision.
import {
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { isAbsolute, join, relative, resolve, sep } from "node:path";
import type { Config } from "../config.ts";
import type { LessonReader } from "../lesson-store.ts";
import { lessonsForFile, rankLessons, renderLessons } from "./match.ts";
import type { RankedLesson } from "./match.ts";
import { repoForPath } from "./scopes.ts";
import type { ScopeMap, ScopedRepo } from "./scopes.ts";
import { estimateTokens } from "./usage.ts";
import type { UsageLog, UsageSource } from "./usage.ts";

export const SESSION_INTRO =
  "Lessons from past code reviews in this folder. More come per file as you read; ask the `suica-lessons` MCP server for others.";
const FILE_INTRO = "Lessons from past code reviews for this file:";

const FILE_TOOLS: Readonly<Record<string, readonly string[]>> = {
  PostToolUse: ["Read"],
  PreToolUse: ["Write", "Edit", "MultiEdit"],
};

export interface HookInput {
  readonly hook_event_name: "SessionStart" | "PostToolUse" | "PreToolUse";
  readonly session_id: string;
  readonly cwd: string;
  readonly tool_name?: string;
  readonly tool_input?: { readonly file_path?: string };
  /** SessionStart only: "startup", "resume", "clear" or "compact". */
  readonly source?: string;
}

export interface SeenStore {
  get(sessionId: string): ReadonlySet<number>;
  add(sessionId: string, ids: readonly number[]): void;
  /** Forgets the session's lessons, for a new context window. */
  reset(sessionId: string): void;
}

export interface HookDeps {
  readonly config: Config["lessons"];
  readonly hostname: string;
  readonly reader: LessonReader | undefined;
  readonly seen: SeenStore;
  /** Where each delivery is noted; a failing log never costs the agent its Lessons. */
  readonly usage: UsageLog;
  readonly now: number;
  /** The scope map; called only when an answer needs it. */
  readonly scan: () => ScopeMap;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseInput(input: unknown): HookInput | undefined {
  if (!isRecord(input)) return undefined;
  const event = input["hook_event_name"];
  const sessionId = input["session_id"];
  const cwd = input["cwd"];
  if (event !== "SessionStart" && event !== "PostToolUse" && event !== "PreToolUse") {
    return undefined;
  }
  if (typeof sessionId !== "string" || typeof cwd !== "string") return undefined;
  const toolName = input["tool_name"];
  const toolInput = input["tool_input"];
  const source = input["source"];
  const filePath = isRecord(toolInput) ? toolInput["file_path"] : undefined;
  return {
    hook_event_name: event,
    session_id: sessionId,
    cwd,
    ...(typeof toolName === "string" ? { tool_name: toolName } : {}),
    ...(typeof filePath === "string" ? { tool_input: { file_path: filePath } } : {}),
    ...(typeof source === "string" ? { source } : {}),
  };
}

/** An absolute, normalized path; a relative one only against an absolute cwd. */
function absolutePath(path: string, cwd: string): string | undefined {
  if (path === "" || path.includes("\0")) return undefined;
  if (isAbsolute(path)) return resolve(path);
  if (cwd === "" || cwd.includes("\0") || !isAbsolute(cwd)) return undefined;
  return resolve(cwd, path);
}

interface Target {
  /** The lesson scope: the configured folder, resolved, as `scanScopes` stores it. */
  readonly scope: string;
  /** The repo holding the cwd (session start) or the file; undefined for a session outside any. */
  readonly repo?: ScopedRepo;
  /** Path relative to the repo for a file event; undefined for a session start. */
  readonly file?: string;
}

/**
 * The lesson scope an absolute path belongs to: its repository's scope, else (a folder in a scope
 * but outside its repos) the deepest configured scope folder holding it. `scan` is called only
 * when needed. Shared with the MCP server so both resolve scopes alike.
 */
export function resolveScope(
  path: string,
  scopes: readonly string[],
  scan: () => ScopeMap,
): { readonly scope: string; readonly repo?: ScopedRepo } | undefined {
  const absolute = resolve(path);
  const repo = repoForPath(scan(), absolute);
  if (repo !== undefined) return { scope: repo.scope, repo };
  let best: string | undefined;
  for (const raw of scopes) {
    const scope = resolve(raw);
    const inside = absolute === scope || absolute.startsWith(scope + sep);
    if (inside && (best === undefined || scope.length > best.length)) best = scope;
  }
  return best === undefined ? undefined : { scope: best };
}

function target(input: HookInput, deps: HookDeps): Target | undefined {
  if (input.hook_event_name === "SessionStart") {
    const cwd = absolutePath(input.cwd, "");
    if (cwd === undefined) return undefined;
    const found = resolveScope(cwd, deps.config.scopes, deps.scan);
    return found === undefined
      ? undefined
      : { scope: found.scope, ...(found.repo === undefined ? {} : { repo: found.repo }) };
  }
  const tools = FILE_TOOLS[input.hook_event_name] ?? [];
  if (input.tool_name === undefined || !tools.includes(input.tool_name)) return undefined;
  const raw = input.tool_input?.file_path;
  const path = raw === undefined ? undefined : absolutePath(raw, input.cwd);
  if (path === undefined) return undefined;
  const repo = repoForPath(deps.scan(), path);
  if (repo === undefined) return undefined;
  const file = relative(repo.dir, path);
  // repoForPath already keeps the path inside the repo; this guards the relative form too.
  if (file === "" || file === ".." || file.startsWith("../") || isAbsolute(file)) return undefined;
  return { scope: repo.scope, repo, file };
}

function answer(input: unknown, deps: HookDeps): string {
  if (!deps.config.enabled || deps.reader === undefined) return "";
  const parsed = parseInput(input);
  if (parsed === undefined) return "";
  const where = target(parsed, deps);
  if (where === undefined) return "";
  if (parsed.source === "compact" || parsed.source === "clear") {
    // A new context window: what the session was shown before is gone from it.
    deps.seen.reset(parsed.session_id);
  }
  const seen = deps.seen.get(parsed.session_id);
  const fresh = rankLessons(deps.reader, where.scope, deps.now).filter(
    (r) => !seen.has(r.lesson.id),
  );
  const shown: RankedLesson[] =
    where.file === undefined
      ? fresh.slice(0, deps.config.perSession)
      : lessonsForFile(fresh, where.file, deps.config.perFile);
  if (shown.length === 0) return "";
  try {
    deps.seen.add(
      parsed.session_id,
      shown.map((r) => r.lesson.id),
    );
  } catch {
    // Not remembering only means a lesson may come again.
  }
  const intro = where.file === undefined ? SESSION_INTRO : FILE_INTRO;
  const additionalContext = `${intro}\n${renderLessons(shown)}`;
  try {
    const source: UsageSource =
      where.file === undefined
        ? "session"
        : parsed.hook_event_name === "PostToolUse"
          ? "read"
          : "edit";
    deps.usage.append({
      at: deps.now,
      project: where.repo?.project ?? null,
      scope: where.scope,
      source,
      ...(SESSION_ID.test(parsed.session_id) ? { sessionId: parsed.session_id } : {}),
      ...(where.file === undefined ? {} : { file: where.file }),
      lessonIds: shown.map((r) => r.lesson.id),
      tokens: estimateTokens(additionalContext),
    });
  } catch {
    // An unlogged delivery is only a gap in the report.
  }
  return JSON.stringify({
    hookSpecificOutput: { hookEventName: parsed.hook_event_name, additionalContext },
  });
}

/** "" or the hook's JSON answer with `additionalContext`; never throws. */
export function answerHook(input: unknown, deps: HookDeps): string {
  try {
    return answer(input, deps);
  } catch {
    return "";
  }
}

const SESSION_ID = /^[\w-]{1,100}$/;
const SEEN_MAX_AGE_MS = 86_400_000;

/**
 * The lessons already handed to each session, one `<dir>/<sessionId>.json` per session. A session
 * id that does not match SESSION_ID is never used as a file name: its lessons are still shown, but
 * not remembered. Files older than a day are removed when the store is opened. Every failure is
 * swallowed: forgetting only means a lesson may be shown twice.
 */
export function fileSeenStore(dir: string, now: number): SeenStore {
  try {
    for (const name of readdirSync(dir)) {
      if (!name.endsWith(".json") && !name.endsWith(".tmp")) continue;
      const path = join(dir, name);
      try {
        if (statSync(path).mtimeMs < now - SEEN_MAX_AGE_MS) rmSync(path, { force: true });
      } catch {
        // Gone already, or not ours to remove.
      }
    }
  } catch {
    // No folder yet.
  }
  const file = (sessionId: string): string | undefined =>
    SESSION_ID.test(sessionId) ? join(dir, `${sessionId}.json`) : undefined;
  const get = (sessionId: string): Set<number> => {
    const path = file(sessionId);
    if (path === undefined) return new Set();
    try {
      const raw: unknown = JSON.parse(readFileSync(path, "utf8"));
      const ids: unknown[] = Array.isArray(raw) ? raw : [];
      return new Set(ids.filter((n): n is number => Number.isInteger(n)));
    } catch {
      return new Set();
    }
  };
  return {
    get,
    add(sessionId, ids) {
      const path = file(sessionId);
      if (path === undefined || ids.length === 0) return;
      try {
        mkdirSync(dir, { recursive: true, mode: 0o700 });
        const all = [...new Set([...get(sessionId), ...ids])];
        const temporary = `${path}.${String(process.pid)}.tmp`;
        writeFileSync(temporary, JSON.stringify(all), { mode: 0o600 });
        renameSync(temporary, path);
      } catch {
        // See above.
      }
    },
    reset(sessionId) {
      const path = file(sessionId);
      if (path === undefined) return;
      try {
        rmSync(path, { force: true });
      } catch {
        // See above.
      }
    },
  };
}

/** Claude Code pipes the hook's input; a terminal (someone running it by hand) is not waited on. */
export function shouldReadStdin(stdin: { readonly isTTY?: boolean }): boolean {
  return stdin.isTTY !== true;
}

/**
 * The scope map the daemon caches after each scan (`lesson-scopes.json`, a `ScopeMap`); undefined
 * when missing or malformed. Each repo's scope is recomputed from the current config as the
 * deepest configured folder holding it, and a repo under none is left out, so a folder the Owner
 * just added (or nested) takes effect before the daemon scans again.
 */
export function readScopeCache(path: string, scopes: readonly string[]): ScopeMap | undefined {
  let raw: unknown;
  try {
    raw = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return undefined;
  }
  if (!isRecord(raw) || !Array.isArray(raw["repos"])) return undefined;
  const configured = [...new Set(scopes.filter((s) => s !== "").map((s) => resolve(s)))];
  const deepest = (dir: string): string | undefined => {
    let best: string | undefined;
    for (const scope of configured) {
      const inside = dir === scope || dir.startsWith(scope === sep ? sep : scope + sep);
      if (inside && (best === undefined || scope.length > best.length)) best = scope;
    }
    return best;
  };
  const repos: ScopedRepo[] = [];
  for (const entry of raw["repos"] as unknown[]) {
    if (!isRecord(entry)) return undefined;
    const { scope, dir, project } = entry;
    if (typeof scope !== "string" || typeof dir !== "string" || typeof project !== "string") {
      return undefined;
    }
    if (!isAbsolute(dir)) continue;
    const current = deepest(resolve(dir));
    if (current === undefined) continue;
    repos.push({ scope: current, dir, project });
  }
  return { repos };
}
