import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { parse } from "yaml";
import { z } from "zod";
import { errorMessage } from "./util.ts";

const positiveInt = z.number().int().positive();

const configSchema = z
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

export function parseConfig(text: string): Config {
  let raw: unknown;
  try {
    raw = parse(text);
  } catch (error) {
    throw new ConfigError(`config is not valid YAML: ${errorMessage(error)}`);
  }
  const result = configSchema.safeParse(raw);
  if (!result.success) {
    const problems = result.error.issues.map(
      (issue) => `${issue.path.join(".") || "(root)"}: ${issue.message}`,
    );
    throw new ConfigError(`invalid config: ${problems.join("; ")}`);
  }
  return result.data;
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

export function defaultConfigPath(): string {
  return (
    process.env["MRA_CONFIG"] ?? join(homedir(), ".config", "mr-review-assistant", "config.yaml")
  );
}

export function defaultStatePath(): string {
  return join(homedir(), "Library", "Application Support", "mr-review-assistant", "state.db");
}
