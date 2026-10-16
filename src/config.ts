import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { parse } from "yaml";
import { z } from "zod";
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
        maxMessagesPerReviewer: positiveInt.default(2),
        templatesPath: z.string().min(1).optional(),
        people: z.record(z.string(), z.string().email()).default({}),
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
  return result.config;
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
