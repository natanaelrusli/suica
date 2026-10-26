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
import { isAbsolute, join, relative, resolve } from "node:path";
import type { Config } from "../config.ts";
import type { LessonReader } from "../lesson-store.ts";
import { lessonsForFile, rankLessons, renderLessons } from "./match.ts";
import type { RankedLesson } from "./match.ts";
import { repoForPath } from "./scopes.ts";
import type { ScopeMap, ScopedRepo } from "./scopes.ts";

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
}

export interface SeenStore {
  get(sessionId: string): ReadonlySet<number>;
  add(sessionId: string, ids: readonly number[]): void;
}

export interface HookDeps {
  readonly config: Config["lessons"];
  readonly hostname: string;
  readonly reader: LessonReader | undefined;
  readonly seen: SeenStore;
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
  const filePath = isRecord(toolInput) ? toolInput["file_path"] : undefined;
  return {
    hook_event_name: event,
    session_id: sessionId,
    cwd,
    ...(typeof toolName === "string" ? { tool_name: toolName } : {}),
    ...(typeof filePath === "string" ? { tool_input: { file_path: filePath } } : {}),
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
  readonly repo: ScopedRepo;
  /** Path relative to the repo for a file event; undefined for a session start. */
  readonly file?: string;
}

function target(input: HookInput, deps: HookDeps): Target | undefined {
  if (input.hook_event_name === "SessionStart") {
    const cwd = absolutePath(input.cwd, "");
    const repo = cwd === undefined ? undefined : repoForPath(deps.scan(), cwd);
    return repo === undefined ? undefined : { repo };
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
  return { repo, file };
}

function answer(input: unknown, deps: HookDeps): string {
  if (!deps.config.enabled || deps.reader === undefined) return "";
  const parsed = parseInput(input);
  if (parsed === undefined) return "";
  const where = target(parsed, deps);
  if (where === undefined) return "";
  const seen = deps.seen.get(parsed.session_id);
  const fresh = rankLessons(deps.reader, where.repo.scope, deps.now).filter(
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
  return JSON.stringify({
    hookSpecificOutput: {
      hookEventName: parsed.hook_event_name,
      additionalContext: `${intro}\n${renderLessons(shown)}`,
    },
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
  };
}

/**
 * The scope map the daemon caches after each scan (`lesson-scopes.json`, a `ScopeMap`), with
 * repos of scopes no longer configured left out; undefined when missing or malformed.
 */
export function readScopeCache(path: string, scopes: readonly string[]): ScopeMap | undefined {
  let raw: unknown;
  try {
    raw = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return undefined;
  }
  if (!isRecord(raw) || !Array.isArray(raw["repos"])) return undefined;
  const configured = new Set(scopes.map((s) => resolve(s)));
  const repos: ScopedRepo[] = [];
  for (const entry of raw["repos"] as unknown[]) {
    if (!isRecord(entry)) return undefined;
    const { scope, dir, project } = entry;
    if (typeof scope !== "string" || typeof dir !== "string" || typeof project !== "string") {
      return undefined;
    }
    if (!isAbsolute(dir) || !configured.has(scope)) continue;
    repos.push({ scope, dir, project });
  }
  return { repos };
}
