// `node src/lessons-hook.ts`: the Claude Code hook for SessionStart, PostToolUse (Read) and
// PreToolUse (Write/Edit/MultiEdit). Reads the hook's JSON on stdin and prints Lessons as
// `additionalContext`, or nothing. It must start fast, so it loads only the config, the read-only
// lessons reader and the matching code, never the daemon's runtime; any failure prints nothing
// and exits 0, so it can never block a read or an edit.
import { dirname, join } from "node:path";
import { defaultConfigPath, defaultStatePath, loadConfig } from "./config.ts";
import { openLessonsReadOnly } from "./lesson-store.ts";
import { answerHook, fileSeenStore, readScopeCache, shouldReadStdin } from "./lessons/hook.ts";
import { scanScopes } from "./lessons/scopes.ts";
import { fileUsageLog } from "./lessons/usage.ts";

/** Hook input is a small JSON object; anything bigger is not one we answer. */
const STDIN_MAX_BYTES = 1_048_576;

async function readStdin(): Promise<string | undefined> {
  if (!shouldReadStdin(process.stdin)) return undefined;
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of process.stdin) {
    const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk));
    size += bytes.length;
    if (size > STDIN_MAX_BYTES) return undefined;
    chunks.push(bytes);
  }
  return Buffer.concat(chunks).toString("utf8");
}

async function main(): Promise<string> {
  const text = await readStdin();
  if (text === undefined) return "";
  let input: unknown;
  try {
    input = JSON.parse(text);
  } catch {
    return "";
  }
  const config = loadConfig(defaultConfigPath());
  if (!config.lessons.enabled) return "";
  const statePath = config.statePath ?? defaultStatePath();
  const stateDir = dirname(statePath);
  const reader = openLessonsReadOnly(statePath);
  if (reader === undefined) return "";
  try {
    const now = Date.now();
    const { scopes } = config.lessons;
    const { hostname } = config.gitlab;
    return answerHook(input, {
      config: config.lessons,
      hostname,
      reader,
      seen: fileSeenStore(join(stateDir, "lessons-seen"), now),
      usage: fileUsageLog(join(stateDir, "lessons-usage"), now),
      now,
      // The daemon normally provides the cache after each scan; without it every call walks the folders.
      scan: () =>
        readScopeCache(join(stateDir, "lesson-scopes.json"), scopes) ??
        scanScopes(scopes, hostname),
    });
  } finally {
    reader.close();
  }
}

let answer = "";
try {
  answer = await main();
} catch {
  answer = "";
}
if (answer !== "") process.stdout.write(answer);
process.exitCode = 0;
