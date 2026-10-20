import { describe, expect, it } from "vitest";
import { z } from "zod";
import { configSchema } from "../src/config.ts";
import { CONFIG_FIELDS } from "../src/config-fields.ts";

function leafPaths(schema: z.ZodTypeAny, prefix: readonly string[]): string[] {
  if (schema instanceof z.ZodDefault)
    return leafPaths(schema.removeDefault() as z.ZodTypeAny, prefix);
  if (schema instanceof z.ZodOptional) return leafPaths(schema.unwrap() as z.ZodTypeAny, prefix);
  if (schema instanceof z.ZodEffects) return leafPaths(schema.innerType() as z.ZodTypeAny, prefix);
  if (schema instanceof z.ZodObject) {
    return Object.entries(schema.shape as z.ZodRawShape).flatMap(([key, child]) =>
      leafPaths(child, [...prefix, key]),
    );
  }
  // Arrays and records are leaves: the editor edits them as a whole.
  return [prefix.join(".")];
}

describe("CONFIG_FIELDS", () => {
  it("covers every leaf of the config schema exactly once", () => {
    const fromSchema = leafPaths(configSchema, []).sort();
    const fromFields = CONFIG_FIELDS.map((field) => field.path.join(".")).sort();
    expect(fromFields).toEqual(fromSchema);
    expect(new Set(fromFields).size).toBe(fromFields.length);
    expect(fromFields).toHaveLength(40);
  });

  it("gives enum fields the schema's options", () => {
    const nudge = CONFIG_FIELDS.find((field) => field.path.join(".") === "teams.modes.nudge");
    expect(nudge?.type).toBe("enum");
    expect(nudge?.options).toEqual(["auto", "approval", "dry-run"]);
    const notice = CONFIG_FIELDS.find((field) => field.path.join(".") === "teams.modes.notice");
    expect(notice?.options).toEqual(["auto", "approval", "dry-run"]);
    const rereview = CONFIG_FIELDS.find((field) => field.path.join(".") === "teams.modes.rereview");
    expect(rereview?.type).toBe("enum");
    expect(rereview?.options).toEqual(["auto", "approval", "dry-run"]);
    for (const field of CONFIG_FIELDS) {
      expect(field.options !== undefined).toBe(field.type === "enum");
    }
  });

  it("lists the re-review wait as a whole number of minutes", () => {
    const wait = CONFIG_FIELDS.find(
      (field) => field.path.join(".") === "teams.rereviewAfterMinutes",
    );
    expect(wait?.type).toBe("int");
  });

  it("has a label and help for every field", () => {
    for (const field of CONFIG_FIELDS) {
      expect(field.label.trim(), field.path.join(".")).not.toBe("");
      expect(field.help.trim(), field.path.join(".")).not.toBe("");
    }
  });
});
