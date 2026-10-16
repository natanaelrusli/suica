import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { parse } from "yaml";
import { validateConfig } from "./config.ts";
import type { ConfigIssue } from "./config.ts";
import { CONFIG_FIELDS } from "./config-fields.ts";
import type { ConfigField } from "./config-fields.ts";
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
