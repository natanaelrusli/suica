import { existsSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { z } from "zod";
import { writeAtomically } from "./config-edit.ts";
import {
  DEFAULT_TEMPLATES,
  PLACEHOLDERS,
  TemplateError,
  validateTemplate,
} from "./teams/templates.ts";
import { TEMPLATE_NAMES } from "./teams/types.ts";
import type { TemplateName } from "./teams/types.ts";

/**
 * Message templates for the app: `suica templates show --json` lists them and
 * `suica templates set --json` saves or resets one. A saved template is checked the way the
 * agent checks it at startup, so the app can never write one that would stop the agent.
 */

const MAX_TEMPLATE_CHARS = 4000;

export interface TemplateJson {
  readonly name: TemplateName;
  /** The text the agent uses: the file's when there is one, else the built-in one. */
  readonly text: string;
  /** True when `<name>.txt` replaces the built-in template. */
  readonly custom: boolean;
  readonly defaultText: string;
}

/** See contracts/templates.v1.json. */
export interface TemplatesDocJson {
  readonly version: 1;
  /** The templates folder. */
  readonly path: string;
  readonly placeholders: readonly string[];
  readonly templates: readonly TemplateJson[];
}

export function showTemplates(directory: string): TemplatesDocJson {
  return {
    version: 1,
    path: directory,
    placeholders: PLACEHOLDERS,
    templates: TEMPLATE_NAMES.map((name) => {
      const file = join(directory, `${name}.txt`);
      const custom = existsSync(file);
      return {
        name,
        text: custom ? readFileSync(file, "utf8") : DEFAULT_TEMPLATES[name],
        custom,
        defaultText: DEFAULT_TEMPLATES[name],
      };
    }),
  };
}

const requestSchema = z
  .object({
    name: z.enum(TEMPLATE_NAMES),
    /** Null removes the file, so the built-in template applies again. */
    text: z.string().max(MAX_TEMPLATE_CHARS).nullable(),
  })
  .strict();

export type TemplateSaveJson =
  | { readonly status: "saved" | "reset" }
  | { readonly status: "invalid" | "bad-request" | "failed"; readonly message: string };

export function parseTemplateRequest(text: string): z.infer<typeof requestSchema> | undefined {
  try {
    const parsed = requestSchema.safeParse(JSON.parse(text));
    return parsed.success ? parsed.data : undefined;
  } catch {
    return undefined;
  }
}

/** The file name comes from the fixed list of template names, never from the request text. */
export function saveTemplate(
  directory: string,
  request: z.infer<typeof requestSchema>,
): TemplateSaveJson {
  const file = join(directory, `${request.name}.txt`);
  if (request.text === null) {
    try {
      rmSync(file, { force: true });
    } catch {
      return { status: "failed", message: "cannot remove the template file" };
    }
    return { status: "reset" };
  }
  try {
    validateTemplate(`${request.name}.txt`, request.text);
  } catch (error) {
    if (error instanceof TemplateError) return { status: "invalid", message: error.message };
    throw error;
  }
  try {
    writeAtomically(file, request.text, "cannot write the template file");
  } catch (error) {
    return { status: "failed", message: error instanceof Error ? error.message : "write failed" };
  }
  return { status: "saved" };
}
