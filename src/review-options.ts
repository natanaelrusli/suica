import { readFileSync, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { parse } from "yaml";
import { MODEL_NAME, SKILL_NAME } from "./config.ts";
import { clean } from "./format.ts";
import type { ModelCliId } from "./model-cli.ts";

/** What the Owner can pick for an Agent Review; see contracts/review-options.v1.json. */
export interface ReviewOptionsJson {
  readonly version: 1;
  /** The CLI the models are for; null when none is installed. */
  readonly cli: ModelCliId | null;
  readonly defaults: { readonly skill: string; readonly model: string | null };
  readonly skills: readonly SkillJson[];
  readonly models: readonly ModelJson[];
}

export interface SkillJson {
  /** As typed after the slash: `plugin:skill`, or a bare name for a personal skill. */
  readonly name: string;
  readonly description: string;
  readonly source: "user" | "plugin";
  readonly plugin: string | null;
  /** Only the configured default can be missing: it is listed so the app can say so. */
  readonly missing: boolean;
}

export interface ModelJson {
  readonly name: string;
  readonly label: string;
  readonly description: string;
}

const DESCRIPTION_MAX = 300;

/** Claude Code has no local model list; its aliases follow the newest model of each tier. */
const CLAUDE_MODELS: readonly ModelJson[] = [
  { name: "opus", label: "Opus", description: "Most capable; slowest and uses the most tokens" },
  { name: "sonnet", label: "Sonnet", description: "Balanced speed and depth" },
  { name: "haiku", label: "Haiku", description: "Fastest and lightest, for small MRs" },
];

function list(dir: string): string[] {
  try {
    return readdirSync(dir);
  } catch {
    return [];
  }
}

function readJson(path: string): unknown {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return undefined;
  }
}

function record(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

/** The front matter's `description`, on one line; empty when the file has none. */
function skillDescription(file: string): string | undefined {
  let text: string;
  try {
    text = readFileSync(file, "utf8");
  } catch {
    return undefined;
  }
  const match = /^---\r?\n([\s\S]*?)\r?\n---/.exec(text);
  if (match === null) return "";
  try {
    const description = record(parse(match[1] ?? ""))["description"];
    return typeof description === "string" ? clean(description, DESCRIPTION_MAX) : "";
  } catch {
    return "";
  }
}

/** `0.10.0` sorts after `0.9.0`. */
function byVersion(a: string, b: string): number {
  return a.localeCompare(b, undefined, { numeric: true });
}

/**
 * Plugin name and folder of every plugin Claude Code loads for the user: the user-scoped entries of
 * `installed_plugins.json` that `enabledPlugins` does not turn off. Without that file, the newest
 * version of each plugin in the cache.
 */
function pluginDirs(home: string): { plugin: string; dir: string }[] {
  const plugins = join(home, ".claude", "plugins");
  const installed = record(readJson(join(plugins, "installed_plugins.json")))["plugins"];
  if (installed === undefined) {
    const cache = join(plugins, "cache");
    return list(cache).flatMap((marketplace) =>
      list(join(cache, marketplace)).flatMap((plugin) => {
        const newest = list(join(cache, marketplace, plugin))
          .sort(byVersion)
          .at(-1);
        return newest === undefined
          ? []
          : [{ plugin, dir: join(cache, marketplace, plugin, newest) }];
      }),
    );
  }
  const enabled = record(
    record(readJson(join(home, ".claude", "settings.json")))["enabledPlugins"],
  );
  return Object.entries(record(installed)).flatMap(([key, entries]) => {
    if (enabled[key] === false || !Array.isArray(entries)) return [];
    const entry = entries.map(record).find((item) => (item["scope"] ?? "user") === "user");
    const dir = entry?.["installPath"];
    return typeof dir === "string" ? [{ plugin: key.split("@")[0] ?? key, dir }] : [];
  });
}

/** Names containing "review" first, then by name. */
function reviewFirst(a: SkillJson, b: SkillJson): number {
  const rank = (skill: SkillJson): number => (skill.name.includes("review") ? 0 : 1);
  return rank(a) - rank(b) || a.name.localeCompare(b.name);
}

/**
 * The Claude Code skills a review can follow: personal ones in `~/.claude/skills` and those of the
 * loaded plugins. Names the config would refuse are left out. The default is always listed.
 */
export function listSkills(defaultSkill: string, home: string = homedir()): SkillJson[] {
  const found = new Map<string, SkillJson>();
  const add = (name: string, file: string, plugin: string | null): void => {
    if (!SKILL_NAME.test(name) || found.has(name)) return;
    const description = skillDescription(file);
    if (description === undefined) return;
    found.set(name, {
      name,
      description,
      source: plugin === null ? "user" : "plugin",
      plugin,
      missing: false,
    });
  };
  const personal = join(home, ".claude", "skills");
  for (const name of list(personal)) add(name, join(personal, name, "SKILL.md"), null);
  for (const { plugin, dir } of pluginDirs(home)) {
    for (const name of list(join(dir, "skills"))) {
      add(`${plugin}:${name}`, join(dir, "skills", name, "SKILL.md"), plugin);
    }
  }
  if (!found.has(defaultSkill)) {
    const [first, second] = defaultSkill.split(":");
    found.set(defaultSkill, {
      name: defaultSkill,
      description: "",
      source: second === undefined ? "user" : "plugin",
      plugin: second === undefined ? null : (first ?? null),
      missing: true,
    });
  }
  return [...found.values()].sort(reviewFirst);
}

/** Codex's own list of the models it offers, from its cache; empty when there is none. */
function codexModels(home: string): ModelJson[] {
  const models = record(readJson(join(home, ".codex", "models_cache.json")))["models"];
  if (!Array.isArray(models)) return [];
  return models.map(record).flatMap((model) => {
    const { slug, display_name: label, description, visibility } = model;
    if (visibility !== "list" || typeof slug !== "string" || !MODEL_NAME.test(slug)) return [];
    return [
      {
        name: slug,
        label: typeof label === "string" ? clean(label, 60) : slug,
        description: typeof description === "string" ? clean(description, DESCRIPTION_MAX) : "",
      },
    ];
  });
}

/** The models the CLI can review with; the configured default is always listed. */
export function listModels(
  cli: ModelCliId | null,
  defaultModel: string | undefined,
  home: string = homedir(),
): ModelJson[] {
  const models = cli === "claude" ? [...CLAUDE_MODELS] : cli === "codex" ? codexModels(home) : [];
  if (defaultModel !== undefined && !models.some((model) => model.name === defaultModel)) {
    models.push({ name: defaultModel, label: defaultModel, description: "" });
  }
  return models;
}

export function buildReviewOptions(
  review: { readonly skill: string; readonly model?: string | undefined },
  cli: ModelCliId | null,
  home: string = homedir(),
): ReviewOptionsJson {
  return {
    version: 1,
    cli,
    defaults: { skill: review.skill, model: review.model ?? null },
    skills: listSkills(review.skill, home),
    models: cli === null ? [] : listModels(cli, review.model, home),
  };
}
