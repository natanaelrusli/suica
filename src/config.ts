import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { parse } from "yaml";
import { z } from "zod";
import { APPROVE_BY } from "./approval-judge.ts";
import { APPROVE_WHEN } from "./inline-review.ts";
import { MODEL_CLI_CHOICES } from "./model-cli.ts";
import { BUILT_IN_AGENTS, parseCustomAgent } from "./office/generic.ts";
import { REVIEW_EFFORTS } from "./review-runner.ts";
import { errorMessage } from "./util.ts";

const positiveInt = z.number().int().positive();
/** review.approveRules end up in a prompt: a few short lines. */
const APPROVE_RULES_MAX = 20;
const APPROVE_RULE_MAX = 500;

// Passed as one argument after --model / -m; a leading letter or digit keeps it from being a flag.
const modelSchema = z
  .string()
  .regex(/^[A-Za-z0-9][\w.:[\]/-]*$/, "must be a model name such as sonnet, opus or haiku");

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
        maxBackoffSeconds: positiveInt.default(300),
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
            // The Owner asked for an Agent Review's findings to reach the Author without a stop.
            findings: sendModeSchema.default("auto"),
            // The Owner asked for the Author to hear about an approval without a stop as well.
            approved: sendModeSchema.default("auto"),
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
        // The name the agent introduces itself with in Teams ({{agent.name}}).
        agentName: z.string().trim().min(1).default("Suica"),
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
        // Approve the MR as the Owner once a review that is ready to approve is posted; such a
        // review is posted at once, even with post: approval. Off: the Owner approves with one
        // click in the app.
        approve: z.boolean().default(true),
        // What may be left for a review to be ready to approve: minor (Minor or Nit findings),
        // nit (Nit findings only) or clean (no findings).
        approveWhen: z.enum(APPROVE_WHEN).default("minor"),
        // Who decides that a review is ready to approve: agent (a model run reads the review,
        // by approveWhen and approveRules; it fails closed) or rules (the review's headings).
        approveBy: z.enum(APPROVE_BY).default("agent"),
        // The Owner's own rules for the agent, one per line; they win over approveWhen.
        approveRules: z.array(z.string().max(APPROVE_RULE_MAX)).max(APPROVE_RULES_MAX).default([]),
        // A skill name only, as typed after the slash: it ends up in a prompt and a file path.
        skill: z
          .string()
          .regex(/^[\w-]+(:[\w-]+)?$/, "must be a skill name such as plugin:skill")
          .default("madhani:madhani-code-review"),
        model: modelSchema.optional(),
        // How hard the CLI thinks: claude --effort, codex model_reasoning_effort (max is xhigh there).
        effort: z.enum(REVIEW_EFFORTS).default("medium"),
        maxChangedLines: positiveInt.default(800),
        maxPerDay: positiveInt.default(10),
        rereviewAfterMinutes: positiveInt.default(10),
        timeoutMinutes: positiveInt.default(20),
        // How many reviews run at once, each with its own CLI process and checkout.
        concurrency: z.number().int().min(1).max(4).default(2),
      })
      .strict()
      .default({}),
    // Agent Fix: answers Reviewer threads on the Owner's own MRs; nothing is pushed before the Owner confirms.
    fix: z
      .object({
        // Watch the Owner's MRs and queue fixes by themselves.
        auto: z.boolean().default(true),
        model: modelSchema.optional(),
        effort: z.enum(REVIEW_EFFORTS).default("medium"),
        timeoutMinutes: positiveInt.default(20),
        maxPerDay: positiveInt.default(10),
      })
      .strict()
      .default({}),
    office: z
      .object({
        // Which built-in adapters look for Coding Agents on this Mac.
        agents: z.array(z.enum(BUILT_IN_AGENTS)).default([...BUILT_IN_AGENTS]),
        // More Coding Agents: `name|process|log glob|cwd key|activity key`, one per entry.
        custom: z
          .array(
            z.string().superRefine((entry, ctx) => {
              const parsed = parseCustomAgent(entry);
              if (typeof parsed === "string") ctx.addIssue({ code: "custom", message: parsed });
            }),
          )
          .default([]),
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
