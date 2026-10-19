import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { parse } from "yaml";
import { z } from "zod";
import { MODEL_CLI_CHOICES } from "./model-cli.ts";
import { errorMessage } from "./util.ts";

const positiveInt = z.number().int().positive();

const sendModeSchema = z.enum(["auto", "approval", "dry-run"]);
const clockSchema = z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/, "must be HH:MM (24 hours)");

export const configSchema = z
  .object({
    gitlab: z
      .object({
        hostname: z.string().min(1),
        glabPath: z.string().min(1).default("glab"),
        timeoutSeconds: positiveInt.default(60),
      })
      .strict(),
    polling: z
      .object({
        activeSeconds: positiveInt.default(120),
        idleSeconds: positiveInt.default(300),
        idleAfterSeconds: positiveInt.default(300),
        maxBackoffSeconds: positiveInt.default(900),
      })
      .strict()
      .default({}),
    notifications: z
      .object({
        summaryThreshold: positiveInt.default(4),
        ignoreAuthors: z.array(z.string()).default([]),
      })
      .strict()
      .default({}),
    teams: z
      .object({
        enabled: z.boolean().default(false),
        command: z.string().min(1).optional(),
        startTimeoutSeconds: positiveInt.default(30),
        callTimeoutSeconds: positiveInt.default(60),
        modes: z
          .object({
            nudge: sendModeSchema.default("approval"),
            notice: sendModeSchema.default("approval"),
            rereview: sendModeSchema.default("approval"),
          })
          .strict()
          .default({}),
        workingHours: z
          .object({
            start: clockSchema.default("09:00"),
            end: clockSchema.default("17:00"),
            days: z.array(z.number().int().min(1).max(7)).min(1).default([1, 2, 3, 4, 5]),
          })
          .strict()
          .refine((hours) => hours.start < hours.end, "start must be before end")
          .default({}),
        reminderAfterHours: positiveInt.default(24),
        noticeDebounceMinutes: positiveInt.default(10),
        rereviewAfterMinutes: positiveInt.default(10),
        maxMessagesPerReviewer: positiveInt.default(2),
        templatesPath: z.string().min(1).optional(),
        people: z.record(z.string(), z.string().email()).default({}),
      })
      .strict()
      .default({}),
    model: z
      .object({
        cli: z.enum(MODEL_CLI_CHOICES).default("auto"),
      })
      .strict()
      .default({}),
    review: z
      .object({
        auto: z.boolean().default(true),
        // approval: a ready review waits for the Owner; auto: it is posted as soon as it is ready.
        post: z.enum(["approval", "auto"]).default("approval"),
        // comment: one MR note; inline: findings on a line of the diff become threads there.
        postAs: z.enum(["comment", "inline"]).default("comment"),
        // A skill name only, as typed after the slash: it ends up in a prompt and a file path.
        skill: z
          .string()
          .regex(/^[\w-]+(:[\w-]+)?$/, "must be a skill name such as plugin:skill")
          .default("madhani:madhani-code-review"),
        // Passed as one argument after --model / -m; a leading letter or digit keeps it from being a flag.
        model: z
          .string()
          .regex(/^[A-Za-z0-9][\w.:[\]/-]*$/, "must be a model name such as sonnet, opus or haiku")
          .optional(),
        maxChangedLines: positiveInt.default(800),
        maxPerDay: positiveInt.default(10),
        timeoutMinutes: positiveInt.default(20),
      })
      .strict()
      .default({}),
    statePath: z.string().min(1).optional(),
  })
  .strict();

export type Config = z.infer<typeof configSchema>;

export class ConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ConfigError";
  }
}

export interface ConfigIssue {
  readonly path: string;
  readonly message: string;
}

export function validateConfig(
  raw: unknown,
): { ok: true; config: Config } | { ok: false; issues: ConfigIssue[] } {
  const result = configSchema.safeParse(raw);
  if (result.success) return { ok: true, config: result.data };
  return {
    ok: false,
    issues: result.error.issues.map((issue) => ({
      path: issue.path.join(".") || "(root)",
      message: issue.message,
    })),
  };
}

/** `~` and a leading `~/` mean the home folder; `~user` and a `~` later in the path are kept. */
export function expandHome(path: string): string {
  if (path === "~") return homedir();
  return path.startsWith("~/") ? `${homedir()}${path.slice(1)}` : path;
}

/**
 * The agent runs with the repository as its working folder, so an unexpanded `~/x` would be a
 * folder named `~` there. Expanded once at load time; the editor keeps the text as typed.
 */
function expandPaths(config: Config): Config {
  const { gitlab, teams, statePath } = config;
  return {
    ...config,
    gitlab: { ...gitlab, glabPath: expandHome(gitlab.glabPath) },
    teams: {
      ...teams,
      ...(teams.command === undefined ? {} : { command: expandHome(teams.command) }),
      ...(teams.templatesPath === undefined
        ? {}
        : { templatesPath: expandHome(teams.templatesPath) }),
    },
    ...(statePath === undefined ? {} : { statePath: expandHome(statePath) }),
  };
}

export function parseConfig(text: string): Config {
  let raw: unknown;
  try {
    raw = parse(text);
  } catch (error) {
    throw new ConfigError(`config is not valid YAML: ${errorMessage(error)}`);
  }
  const result = validateConfig(raw);
  if (!result.ok) {
    const problems = result.issues.map((issue) => `${issue.path}: ${issue.message}`);
    throw new ConfigError(`invalid config: ${problems.join("; ")}`);
  }
  return expandPaths(result.config);
}

export function loadConfig(path: string): Config {
  let text: string;
  try {
    text = readFileSync(path, "utf8");
  } catch (error) {
    throw new ConfigError(`cannot read config at ${path}: ${errorMessage(error)}`);
  }
  return parseConfig(text);
}

export function defaultConfigPath(env: NodeJS.ProcessEnv = process.env): string {
  const configured = env["SUICA_CONFIG"];
  if (configured !== undefined) return configured;
  if (env["MRA_CONFIG"] !== undefined) {
    throw new ConfigError("MRA_CONFIG is no longer read; rename it to SUICA_CONFIG");
  }
  return join(homedir(), ".config", "suica", "config.yaml");
}

export function defaultStatePath(): string {
  return join(homedir(), "Library", "Application Support", "suica", "state.db");
}
