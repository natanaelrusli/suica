import { basename } from "node:path";

const MAX = 80;

export function clip(text: string, max: number): string {
  return text.length <= max ? text : `${text.slice(0, max - 1)}…`;
}

function field(input: unknown, ...keys: string[]): string | undefined {
  if (typeof input !== "object" || input === null) return undefined;
  const record = input as Record<string, unknown>;
  for (const key of keys) {
    const value = record[key];
    if (typeof value === "string" && value !== "") return value;
  }
  return undefined;
}

/** `Running npm test`: the first line of a command, whitespace collapsed. */
export function describeCommand(command: string): string {
  const first = command.trim().split("\n")[0] ?? "";
  return clip(`Running ${first.replace(/\s+/g, " ")}`, MAX);
}

const FILE_KEYS = ["file_path", "notebook_path", "path", "absolute_path"];

function onFile(verb: string, input: unknown): string {
  const file = field(input, ...FILE_KEYS);
  return file === undefined ? `${verb} files` : `${verb} ${clip(basename(file), 48)}`;
}

/** What a tool call is doing, named by action and target; never prompt or message text. */
export function describeTool(name: string, input: unknown): string {
  switch (name) {
    case "Edit":
    case "MultiEdit":
    case "NotebookEdit":
    case "replace":
    case "apply_patch":
      return onFile("Editing", input);
    case "Write":
    case "write_file":
      return onFile("Writing", input);
    case "Read":
    case "read_file":
    case "read_many_files":
      return onFile("Reading", input);
    case "Bash":
    case "run_shell_command":
    case "shell":
    case "exec_command": {
      const command = field(input, "command", "cmd");
      return command === undefined ? "Running a command" : describeCommand(command);
    }
    case "Grep":
    case "search_file_content": {
      const pattern = field(input, "pattern", "query");
      return pattern === undefined ? "Searching" : clip(`Searching ${pattern}`, MAX);
    }
    case "Glob":
    case "glob":
    case "list_directory": {
      const pattern = field(input, "pattern", "path");
      return pattern === undefined ? "Finding files" : clip(`Finding ${pattern}`, MAX);
    }
    case "WebFetch":
    case "WebSearch":
    case "web_fetch":
    case "google_web_search":
      return "Browsing the web";
    case "Task":
    case "Agent":
      return "Running a subagent";
    case "TodoWrite":
      return "Planning";
    default:
      if (name.startsWith("mcp__")) return `Using ${name.split("__").at(-1) ?? name}`;
      return clip(`Using ${name}`, MAX);
  }
}
