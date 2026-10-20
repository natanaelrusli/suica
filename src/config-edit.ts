import { createHash } from "node:crypto";
import {
  closeSync,
  fsyncSync,
  mkdirSync,
  openSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname } from "node:path";
import { YAMLMap, isCollection, isMap, isScalar, isSeq, parse, parseDocument } from "yaml";
import type { Document } from "yaml";
import { z } from "zod";
import { expandHome, validateConfig } from "./config.ts";
import type { ConfigIssue } from "./config.ts";
import { CONFIG_FIELDS } from "./config-fields.ts";
import type { ConfigField } from "./config-fields.ts";
import { loadAlerts } from "./alerts.ts";
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

const samePath = (left: readonly string[], right: readonly string[]): boolean =>
  left.length === right.length && left.every((segment, index) => segment === right[index]);

/** A section written as a bare `key:` line, which parses as a null scalar. */
const isNullSection = (node: unknown): boolean => isScalar(node) && node.value === null;

/**
 * Removes the key at `path`; nothing to do when a section above it is missing or null, throws when
 * one is not a collection.
 */
function removeKey(doc: Document, path: readonly string[]): void {
  for (let length = 1; length < path.length; length++) {
    const node = doc.getIn(path.slice(0, length), true);
    if (node === undefined || isNullSection(node)) return;
    if (!isCollection(node)) throw new Error("not a collection");
  }
  doc.deleteIn(path);
  pruneEmptyParents(doc, path);
}

/** Removes each mapping along `path` that has just become empty, innermost first. */
function pruneEmptyParents(doc: Document, path: readonly string[]): void {
  for (let length = path.length - 1; length >= 1; length--) {
    const prefix = path.slice(0, length);
    const node = doc.getIn(prefix, true);
    if (!isMap(node) || node.items.length > 0) return;
    doc.deleteIn(prefix);
  }
}

const isPlainObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

/** A scalar node that already holds `value`; a new value never matches a collection node. */
const holds = (node: unknown, value: unknown): boolean => isScalar(node) && node.value === value;

/** Turns every null section above `path` into an empty mapping, so a key can be set below it. */
function openSections(doc: Document, path: readonly string[]): void {
  for (let length = 1; length < path.length; length++) {
    const prefix = path.slice(0, length);
    if (isNullSection(doc.getIn(prefix, true))) doc.setIn(prefix, new YAMLMap());
  }
}

/**
 * Edits the sequence in place: an item that stays keeps its node (and so its comments), whatever
 * its new position; the sequence node keeps its own comments.
 */
function editSequence(doc: Document, items: unknown[], values: readonly unknown[]): unknown[] {
  const unused = [...items];
  return values.map((value) => {
    const index = unused.findIndex((node) => holds(node, value));
    if (index < 0) return doc.createNode(value);
    return unused.splice(index, 1)[0];
  });
}

/** Edits the mapping key by key, so the pairs that stay keep their comments. */
function editMap(doc: Document, map: YAMLMap, values: Record<string, unknown>): void {
  const seen = new Set<string>();
  map.items = map.items.filter((pair) => {
    // A key written as a number (`123:`) is the string the editor sends.
    const key = isScalar(pair.key) ? String(pair.key.value) : undefined;
    if (key === undefined || !Object.hasOwn(values, key) || seen.has(key)) return false;
    seen.add(key);
    const value = values[key];
    if (holds(pair.value, value)) return true;
    if (isScalar(pair.value) && typeof value === "string") pair.value.value = value;
    else pair.value = doc.createNode(value);
    return true;
  });
  for (const [key, value] of Object.entries(values)) {
    if (!seen.has(key)) map.items.push(doc.createPair(key, value));
  }
}

/** Sets the key at `path`; a list or a map already in the file is edited, not replaced. */
function setKey(doc: Document, path: readonly string[], value: unknown): void {
  openSections(doc, path);
  const node = doc.getIn(path, true);
  if (Array.isArray(value) && isSeq(node)) {
    node.items = editSequence(doc, node.items, value);
  } else if (isPlainObject(value) && isMap(node)) {
    editMap(doc, node, value);
    if (node.items.length === 0) removeKey(doc, path);
  } else if (isPlainObject(value) && Object.keys(value).length === 0) {
    // An empty map is the default: nothing to write.
    removeKey(doc, path);
  } else {
    doc.setIn(path, value);
  }
}

/** Checks, edits and writes the config file. Throws a path-free Error only when the write fails. */
export function applyConfigEdits(path: string, request: SaveRequest): SaveResultJson {
  for (const { path: editPath } of request.edits) {
    if (!CONFIG_FIELDS.some((field) => samePath(field.path, editPath))) {
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
        removeKey(doc, editPath);
      } else {
        setKey(doc, editPath, value);
      }
    } catch {
      return fail("invalid", {
        path: editPath.join("."),
        message: "cannot set this field: its section in the file is not a mapping",
      });
    }
  }

  // Validate what the agent will read back: the written text, parsed as loadConfig does.
  const text = doc.toString({ lineWidth: 0 });
  let reparsed: unknown;
  try {
    reparsed = parse(text);
  } catch {
    return fail("invalid", { path: "(root)", message: "the edited config is not valid YAML" });
  }
  const validated = validateConfig(reparsed);
  if (!validated.ok) return fail("invalid", ...validated.issues);
  try {
    const templatesPath = validated.config.teams.templatesPath;
    // The agent expands a leading ~ when it loads the config: check the folder it will read.
    const folder = templatesPath === undefined ? defaultTemplatesPath() : expandHome(templatesPath);
    // Notification templates load whether Teams is on or not; Teams templates only with Teams.
    loadAlerts(folder);
    if (validated.config.teams.enabled) loadTemplates(folder);
  } catch (error) {
    const message =
      error instanceof TemplateError ? error.message : "cannot read the templates folder";
    return fail("invalid", { path: "teams.templatesPath", message });
  }

  writeAtomically(path, text);
  return { status: "saved", issues: [], sha256: sha256Of(text) };
}

/** Writes `text` to `path` through a private temporary file and a rename; throws `failure`. */
export function writeAtomically(
  path: string,
  text: string,
  failure = "cannot write the config file",
): void {
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
    const fd = openSync(temp, "wx", 0o600);
    try {
      writeFileSync(fd, text);
      // On disk before the rename, so a crash never leaves an empty or partial config behind.
      fsyncSync(fd);
    } finally {
      closeSync(fd);
    }
    renameSync(temp, target);
  } catch {
    try {
      rmSync(temp, { force: true });
    } catch {
      // the fixed message below is what surfaces, never a path
    }
    throw new Error(failure);
  }
}
