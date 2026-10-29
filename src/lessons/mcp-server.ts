// The lessons MCP server: newline-delimited JSON-RPC 2.0 over a pair of streams, hand-rolled so
// it needs no dependency. Any Coding Agent can ask it for the review Lessons that apply to a path.
// Scope isolation is the rule that matters: every tool resolves `path` to a lesson scope first and
// reads nothing outside it. Nothing but JSON-RPC frames is ever written to `output`.
import { statSync } from "node:fs";
import { basename, extname, isAbsolute, relative } from "node:path";
import { createInterface } from "node:readline";
import type { Readable, Writable } from "node:stream";
import type { Config } from "../config.ts";
import type { LessonReader, OccurrenceRow } from "../lesson-store.ts";
import { resolveScope } from "./hook.ts";
import { lessonsForFile, rankLessons, renderLessons } from "./match.ts";
import type { RankedLesson } from "./match.ts";
import { projectOfMrKey } from "./scopes.ts";
import type { ScopeMap } from "./scopes.ts";
import { estimateTokens } from "./usage.ts";
import type { UsageLog } from "./usage.ts";

export interface LessonsServerDeps {
  /** Read on every call, so a config change is picked up without a restart. */
  readonly config: () => Config["lessons"];
  /** Opened and closed per call, so a daemon migration between calls is picked up. */
  readonly openReader: () => LessonReader | undefined;
  readonly scan: () => ScopeMap;
  /** Where each answer that carries Lessons is noted; a failing log never turns into FAILED. */
  readonly usage: UsageLog;
  readonly now: () => number;
}

const SERVER_INFO = { name: "suica-lessons", version: "0.1.0" };
const DEFAULT_PROTOCOL = "2025-03-26";
const NONE = "No lessons apply here.";
const FAILED = "Lessons could not be read right now.";
const SEARCH_LIMIT = 10;
const OCCURRENCE_LIMIT = 20;

const PATH_PROPERTY = {
  type: "string",
  description: "Absolute path of a file or folder in the repository you are working in.",
};

const TOOLS = [
  {
    name: "lessons_for_path",
    description:
      "Lessons from past code reviews that apply to a file, or the top ones for a folder. Call it before changing code you have not seen lessons for.",
    inputSchema: {
      type: "object",
      properties: { path: PATH_PROPERTY },
      required: ["path"],
      additionalProperties: false,
    },
  },
  {
    name: "search_lessons",
    description:
      "Search the lessons of the scope holding `path` by words in the title or rule; every word must match. Results carry ids for get_lesson.",
    inputSchema: {
      type: "object",
      properties: {
        path: PATH_PROPERTY,
        query: { type: "string", description: "Words to find; all of them must match." },
        topic: { type: "string", description: "Only lessons with this topic." },
      },
      required: ["path", "query"],
      additionalProperties: false,
    },
  },
  {
    name: "get_lesson",
    description:
      "One lesson with where it was flagged (repo, MR, file and line, severity, outcome), if it is in the scope of `path`.",
    inputSchema: {
      type: "object",
      properties: {
        path: PATH_PROPERTY,
        id: { type: "integer", description: "A lesson id from the other tools." },
      },
      required: ["path", "id"],
      additionalProperties: false,
    },
  },
] as const;

/** A -32602 the caller sees as a JSON-RPC error. */
class InvalidParams extends Error {}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Exactly the allowed keys, each checked by `check`; anything else is invalid params. */
function parseArgs(
  raw: unknown,
  allowed: Readonly<Record<string, (value: unknown) => boolean>>,
  required: readonly string[],
): Record<string, unknown> {
  if (!isRecord(raw)) throw new InvalidParams("arguments must be an object");
  for (const [key, value] of Object.entries(raw)) {
    const check = allowed[key];
    if (check === undefined || !check(value)) throw new InvalidParams(`invalid argument: ${key}`);
  }
  for (const key of required) {
    if (raw[key] === undefined) throw new InvalidParams(`missing argument: ${key}`);
  }
  return raw;
}

const isPath = (v: unknown): boolean =>
  typeof v === "string" && v !== "" && !v.includes("\0") && isAbsolute(v);
const isWords = (v: unknown): boolean => typeof v === "string" && v.trim() !== "";
const isString = (v: unknown): boolean => typeof v === "string";
const isId = (v: unknown): boolean => typeof v === "number" && Number.isSafeInteger(v);

/**
 * A file or a folder? What exists decides (`statSync`); a path that does not exist yet (a file the
 * agent is about to create) is a file when its last segment has an extension, else a folder.
 */
function isFile(path: string): boolean {
  try {
    return statSync(path).isFile();
  } catch {
    return extname(basename(path)) !== "";
  }
}

function flat(text: string, max: number): string {
  const one = text.replace(/\s*[\r\n]+\s*/g, " ").trim();
  return one.length <= max ? one : `${one.slice(0, max - 1)}…`;
}

/** `renderLessons` per lesson, each line carrying the id `get_lesson` takes. */
function withIds(ranked: readonly RankedLesson[]): string {
  return ranked
    .map((r) => renderLessons([r]).replace(/^- /, `- #${String(r.lesson.id)} `))
    .join("\n");
}

/**
 * Where and how a Lesson was flagged. Never the finding text: a Finding Thread's text is written
 * by anyone with comment access, and this goes straight to the Coding Agent.
 */
function renderOccurrence(o: OccurrenceRow): string {
  const bang = o.mrKey.lastIndexOf("!");
  const mr = `${projectOfMrKey(o.mrKey)} !${bang < 0 ? "" : o.mrKey.slice(bang + 1)}`;
  const where = o.path === null ? "" : ` ${o.path}${o.line === null ? "" : `:${String(o.line)}`}`;
  return `- ${flat(mr, 200)} ${flat(o.mrUrl, 300)}${flat(where, 300) === "" ? "" : ` ${flat(where, 300)}`} [${flat(o.severity, 30)}, ${o.outcome}]`;
}

function text(body: string): Record<string, unknown> {
  return { content: [{ type: "text", text: body }], isError: false };
}

function runTool(name: string, rawArgs: unknown, deps: LessonsServerDeps): Record<string, unknown> {
  let args: Record<string, unknown>;
  switch (name) {
    case "lessons_for_path":
      args = parseArgs(rawArgs, { path: isPath }, ["path"]);
      break;
    case "search_lessons":
      args = parseArgs(rawArgs, { path: isPath, query: isWords, topic: isString }, [
        "path",
        "query",
      ]);
      break;
    case "get_lesson":
      args = parseArgs(rawArgs, { path: isPath, id: isId }, ["path", "id"]);
      break;
    default:
      throw new InvalidParams(`unknown tool: ${name}`);
  }
  const path = args["path"] as string;
  const config = deps.config();
  if (!config.enabled) return text(NONE);
  const found = resolveScope(path, config.scopes, deps.scan);
  if (found === undefined) return text(NONE);
  const reader = deps.openReader();
  if (reader === undefined) return text(NONE);
  // The one place an answer is logged: only a reply that carries at least one Lesson.
  const deliver = (body: string, lessonIds: readonly number[]): Record<string, unknown> => {
    try {
      deps.usage.append({
        at: deps.now(),
        project: found.repo?.project ?? null,
        scope: found.scope,
        source: "mcp",
        tool: name,
        ...(found.repo !== undefined && isFile(path)
          ? { file: relative(found.repo.dir, path) }
          : {}),
        lessonIds,
        tokens: estimateTokens(body),
      });
    } catch {
      // An unlogged answer is only a gap in the report.
    }
    return text(body);
  };
  const deliverRanked = (shown: readonly RankedLesson[]): Record<string, unknown> =>
    shown.length === 0
      ? text(NONE)
      : deliver(
          withIds(shown),
          shown.map((r) => r.lesson.id),
        );
  try {
    const ranked = (): RankedLesson[] => rankLessons(reader, found.scope, deps.now());
    if (name === "lessons_for_path") {
      if (!isFile(path)) {
        return deliverRanked(ranked().slice(0, config.perSession));
      }
      // A file's globs are relative to its repository; a file outside every repo has none.
      if (found.repo === undefined) return text(NONE);
      const shown = lessonsForFile(ranked(), relative(found.repo.dir, path), config.perFile);
      return deliverRanked(shown);
    }
    if (name === "search_lessons") {
      const words = (args["query"] as string).toLowerCase().split(/\s+/).filter(Boolean);
      const topic = typeof args["topic"] === "string" ? args["topic"].toLowerCase() : undefined;
      const hits = ranked()
        .filter((r) => {
          const hay = `${r.lesson.title}\n${r.lesson.rule}`.toLowerCase();
          if (!words.every((w) => hay.includes(w))) return false;
          return topic === undefined || r.lesson.topics.some((t) => t.toLowerCase() === topic);
        })
        .slice(0, SEARCH_LIMIT);
      return deliverRanked(hits);
    }
    // get_lesson: only a live lesson of the path's own scope; anything else looks like no lesson.
    const lesson = reader.lesson(args["id"] as number);
    if (lesson === undefined || lesson.scope !== found.scope || lesson.archived) {
      return text(NONE);
    }
    const occurrences = reader
      .occurrences(lesson.id)
      .sort((a, b) => b.at - a.at || b.id - a.id)
      .slice(0, OCCURRENCE_LIMIT);
    const lines = [
      `#${String(lesson.id)} ${flat(lesson.title, 120)}`,
      flat(lesson.rule, 1000),
      ...(lesson.topics.length === 0 ? [] : [`Topics: ${lesson.topics.join(", ")}`]),
      "Flagged in:",
      ...occurrences.map(renderOccurrence),
    ];
    return deliver(lines.join("\n"), [lesson.id]);
  } finally {
    reader.close();
  }
}

type Reply = Record<string, unknown>;

function failure(id: unknown, code: number, message: string): Reply {
  return { jsonrpc: "2.0", id, error: { code, message } };
}

/** The reply to one parsed message; undefined for a notification. Never throws. */
function handle(message: unknown, deps: LessonsServerDeps): Reply | undefined {
  if (!isRecord(message) || typeof message["method"] !== "string") {
    const id = isRecord(message) ? message["id"] : undefined;
    return failure(
      typeof id === "string" || typeof id === "number" ? id : null,
      -32600,
      "Invalid Request",
    );
  }
  const id = message["id"];
  if (id === undefined || id === null) return undefined;
  if (typeof id !== "string" && typeof id !== "number")
    return failure(null, -32600, "Invalid Request");
  const params = message["params"];
  switch (message["method"]) {
    case "initialize": {
      const version = isRecord(params) ? params["protocolVersion"] : undefined;
      return {
        jsonrpc: "2.0",
        id,
        result: {
          protocolVersion: typeof version === "string" ? version : DEFAULT_PROTOCOL,
          capabilities: { tools: {} },
          serverInfo: SERVER_INFO,
        },
      };
    }
    case "ping":
      return { jsonrpc: "2.0", id, result: {} };
    case "tools/list":
      return { jsonrpc: "2.0", id, result: { tools: TOOLS } };
    case "tools/call": {
      if (!isRecord(params) || typeof params["name"] !== "string") {
        return failure(id, -32602, "Invalid params");
      }
      try {
        return {
          jsonrpc: "2.0",
          id,
          result: runTool(params["name"], params["arguments"] ?? {}, deps),
        };
      } catch (error) {
        if (error instanceof InvalidParams) return failure(id, -32602, error.message);
        return {
          jsonrpc: "2.0",
          id,
          result: { content: [{ type: "text", text: FAILED }], isError: true },
        };
      }
    }
    default:
      return failure(id, -32601, "Method not found");
  }
}

function handleLine(line: string, deps: LessonsServerDeps): string | undefined {
  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch {
    return JSON.stringify(failure(null, -32700, "Parse error"));
  }
  if (Array.isArray(parsed)) {
    if (parsed.length === 0) return JSON.stringify(failure(null, -32600, "Invalid Request"));
    const replies = (parsed as unknown[]).flatMap((m) => handle(m, deps) ?? []);
    return replies.length === 0 ? undefined : JSON.stringify(replies);
  }
  const reply = handle(parsed, deps);
  return reply === undefined ? undefined : JSON.stringify(reply);
}

/** Serves until `input` ends. Requests are answered in order, one JSON line each. */
export async function serveLessons(
  input: Readable,
  output: Writable,
  deps: LessonsServerDeps,
): Promise<void> {
  const lines = createInterface({ input, crlfDelay: Infinity });
  for await (const raw of lines) {
    const line = raw.trim();
    if (line === "") continue;
    let reply: string | undefined;
    try {
      reply = handleLine(line, deps);
    } catch {
      reply = JSON.stringify(failure(null, -32603, "Internal error"));
    }
    if (reply !== undefined) output.write(`${reply}\n`);
  }
}
