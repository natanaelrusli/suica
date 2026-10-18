import { accessSync, constants, statSync } from "node:fs";
import { homedir } from "node:os";
import { delimiter, dirname, join } from "node:path";

/** The coding agent CLIs that can run language model work, in the order `auto` tries them. */
export const MODEL_CLI_IDS = ["claude", "codex", "gemini"] as const;
export type ModelCliId = (typeof MODEL_CLI_IDS)[number];

export const MODEL_CLI_CHOICES = ["auto", ...MODEL_CLI_IDS] as const;
export type ModelCliChoice = (typeof MODEL_CLI_CHOICES)[number];

const NAMES: Readonly<Record<ModelCliId, string>> = {
  claude: "Claude Code",
  codex: "Codex",
  gemini: "Gemini CLI",
};

export interface DetectedCli {
  readonly id: ModelCliId;
  readonly name: string;
  /** Absolute path of the executable; null when it was not found. */
  readonly path: string | null;
}

export type IsExecutable = (path: string) => boolean;

export const isExecutableFile: IsExecutable = (path) => {
  try {
    accessSync(path, constants.X_OK);
    return statSync(path).isFile();
  } catch {
    return false;
  }
};

/**
 * Folders to look in. The LaunchAgent's PATH has only the system and Homebrew folders, so the
 * places the installers of these CLIs use are added, and so is the folder of the `node` running
 * Suica, where `npm install -g` puts them under nvm.
 */
export function searchDirs(
  env: NodeJS.ProcessEnv = process.env,
  home: string = homedir(),
  nodePath: string = process.execPath,
): string[] {
  const fromPath = (env["PATH"] ?? "").split(delimiter).filter((dir) => dir !== "");
  const extra = [".local/bin", ".claude/local", ".npm-global/bin", ".bun/bin", ".volta/bin"].map(
    (dir) => join(home, dir),
  );
  return [
    ...new Set([...fromPath, ...extra, dirname(nodePath), "/opt/homebrew/bin", "/usr/local/bin"]),
  ];
}

export function detectModelClis(
  dirs: readonly string[] = searchDirs(),
  isExecutable: IsExecutable = isExecutableFile,
): DetectedCli[] {
  return MODEL_CLI_IDS.map((id) => ({
    id,
    name: NAMES[id],
    path: dirs.map((dir) => join(dir, id)).find(isExecutable) ?? null,
  }));
}

/** `auto` is the first installed CLI; a named one is used only when it is installed. */
export function resolveModelCli(
  choice: ModelCliChoice,
  detected: readonly DetectedCli[],
): ModelCliId | null {
  const installed = detected.filter((cli) => cli.path !== null);
  const found = choice === "auto" ? installed[0] : installed.find((cli) => cli.id === choice);
  return found?.id ?? null;
}
