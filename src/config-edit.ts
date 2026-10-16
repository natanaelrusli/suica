import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, realpathSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { isMap, parse, parseDocument } from "yaml";
import type { Document } from "yaml";
import { z } from "zod";
import { validateConfig } from "./config.ts";
import type { ConfigIssue } from "./config.ts";
import { CONFIG_FIELDS } from "./config-fields.ts";
import type { ConfigField } from "./config-fields.ts";
import { TemplateError, defaultTemplatesPath, loadTemplates } from "./teams/templates.ts";
import { errorMessage } from "./util.ts";

export interface FieldJson extends ConfigField {
  /** As written in the file, null when absent. */
  readonly value: unknown;
  /** After defaults; null when absent or when the config is invalid. */
  readonly effective: unknown;
}

/** The document `suica config show --json` prints; see contracts/config.v1.json. */
export interface ConfigDocJson {
  readonly version: 1;
  readonly path: string;
  readonly exists: boolean;
  /** Of the file bytes, hex; null when the file does not exist. */
  readonly sha256: string | null;
  /** A YAML syntax error is one issue at "(root)". */
  readonly issues: readonly ConfigIssue[];
  readonly fields: readonly FieldJson[];
}

function valueAt(root: unknown, path: readonly string[]): unknown {
  let current = root;
  for (const key of path) {
    if (typeof current !== "object" || current === null || Array.isArray(current)) return null;
    current = (current as Record<string, unknown>)[key];
  }
  return current ?? null;
}

export function showConfig(path: string): ConfigDocJson {
  let bytes: Buffer;
  try {
    bytes = readFileSync(path);
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    const issues: ConfigIssue[] =
      code === "ENOENT"
        ? []
        : [{ path: "(root)", message: `cannot read config: ${errorMessage(error)}` }];
    return build(path, code !== "ENOENT", null, issues, null, null);
  }
  const sha256 = createHash("sha256").update(bytes).digest("hex");
  let raw: unknown;
  try {
    raw = parse(bytes.toString("utf8"));
  } catch (error) {
    const issue = { path: "(root)", message: `config is not valid YAML: ${errorMessage(error)}` };
    return build(path, true, sha256, [issue], null, null);
  }
  const result = validateConfig(raw);
  return build(
    path,
    true,
    sha256,
    result.ok ? [] : result.issues,
    raw,
    result.ok ? result.config : null,
  );
}

function build(
  path: string,
  exists: boolean,
  sha256: string | null,
  issues: readonly ConfigIssue[],
  raw: unknown,
  config: unknown,
): ConfigDocJson {
  return {
    version: 1,
    path,
    exists,
    sha256,
    issues,
    fields: CONFIG_FIELDS.map((field) => ({
      ...field,
      value: valueAt(raw, field.path),
      effective: valueAt(config, field.path),
    })),
  };
}

export interface ConfigEdit {
  readonly path: readonly string[];
  /** null removes the key. */
  readonly value: unknown;
}

export interface SaveRequest {
  /** sha256 of the file the editor was loaded from; null when it did not exist. */
  readonly baseSha256: string | null;
  readonly edits: readonly ConfigEdit[];
}

export interface SaveResultJson {
  readonly status: "saved" | "invalid" | "conflict" | "bad-request";
  readonly issues: readonly ConfigIssue[];
  /** Of the file written; null unless the status is "saved". */
  readonly sha256: string | null;
}

const saveRequestSchema = z
  .object({
    baseSha256: z
      .string()
      .regex(/^[0-9a-f]{64}$/)
      .nullable(),
    edits: z.array(
      z
        .object({
          path: z.array(z.string()).min(1),
          value: z.unknown().refine((value) => value !== undefined),
        })
        .strict(),
    ),
  })
  .strict();

/** undefined when the text is not a well-formed request (the caller answers bad-request). */
export function parseSaveRequest(text: string): SaveRequest | undefined {
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch {
    return undefined;
  }
  const result = saveRequestSchema.safeParse(raw);
  return result.success ? result.data : undefined;
}

const fail = (
  status: SaveResultJson["status"],
  ...issues: readonly ConfigIssue[]
): SaveResultJson => ({ status, issues, sha256: null });

const sha256Of = (data: string | Buffer): string => createHash("sha256").update(data).digest("hex");

/** Removes each mapping along `path` that has just become empty, innermost first. */
function pruneEmptyParents(doc: Document, path: readonly string[]): void {
  for (let length = path.length - 1; length >= 1; length--) {
    const prefix = path.slice(0, length);
    const node = doc.getIn(prefix, true);
    if (!isMap(node) || node.items.length > 0) return;
    doc.deleteIn(prefix);
  }
}

/** Checks, edits and writes the config file. Throws a path-free Error only when the write fails. */
export function applyConfigEdits(path: string, request: SaveRequest): SaveResultJson {
  const known = new Set(CONFIG_FIELDS.map((field) => field.path.join("\u0000")));
  for (const { path: editPath } of request.edits) {
    if (!known.has(editPath.join("\u0000"))) {
      return fail("bad-request", { path: editPath.join("."), message: "unknown field" });
    }
  }

  let currentText: string | null = null;
  let currentSha: string | null = null;
  try {
    const bytes = readFileSync(path);
    currentText = bytes.toString("utf8");
    currentSha = sha256Of(bytes);
  } catch (error) {
    // A file that exists but cannot be read is never overwritten.
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
      return fail("invalid", { path: "(root)", message: "cannot read the config file" });
    }
  }
  if (currentSha !== request.baseSha256) return fail("conflict");

  const doc = parseDocument(currentText ?? "");
  if (doc.errors.length > 0) {
    return fail("invalid", { path: "(root)", message: "the config file is not valid YAML" });
  }
  if (doc.contents !== null && !isMap(doc.contents)) {
    return fail("invalid", { path: "(root)", message: "the config file is not a mapping" });
  }
  for (const { path: editPath, value } of request.edits) {
    try {
      if (value === null) {
        doc.deleteIn(editPath);
        pruneEmptyParents(doc, editPath);
      } else {
        doc.setIn(editPath, value);
      }
    } catch {
      return fail("invalid", {
        path: editPath.join("."),
        message: "cannot set this field: its section in the file is not a mapping",
      });
    }
  }

  const validated = validateConfig(doc.toJS());
  if (!validated.ok) return fail("invalid", ...validated.issues);
  if (validated.config.teams.enabled) {
    try {
      loadTemplates(validated.config.teams.templatesPath ?? defaultTemplatesPath());
    } catch (error) {
      const message =
        error instanceof TemplateError ? error.message : "cannot read the templates folder";
      return fail("invalid", { path: "teams.templatesPath", message });
    }
  }

  const text = doc.toString({ lineWidth: 0 });
  writeAtomically(path, text);
  return { status: "saved", issues: [], sha256: sha256Of(text) };
}

function writeAtomically(path: string, text: string): void {
  let target = path;
  try {
    target = realpathSync(path); // keep a symlinked config a symlink
  } catch {
    // missing: create it at `path`
  }
  const temp = `${target}.tmp-${process.pid}`;
  try {
    mkdirSync(dirname(target), { recursive: true, mode: 0o700 });
    rmSync(temp, { force: true });
    writeFileSync(temp, text, { mode: 0o600, flag: "wx" });
    renameSync(temp, target);
  } catch {
    rmSync(temp, { force: true });
    throw new Error("cannot write the config file");
  }
}
