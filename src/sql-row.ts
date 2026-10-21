import { z } from "zod";

/** One row as `node:sqlite` returns it. */
export type Row = Record<string, unknown>;

export function text(row: Row, column: string): string {
  const value = row[column];
  if (typeof value !== "string") throw new Error(`column ${column} is not text`);
  return value;
}

export function integer(row: Row, column: string): number {
  const value = row[column];
  if (typeof value !== "number") throw new Error(`column ${column} is not an integer`);
  return value;
}

export function nullableText(row: Row, column: string): string | null {
  const value = row[column];
  return typeof value === "string" ? value : null;
}

export function nullableInteger(row: Row, column: string): number | null {
  const value = row[column];
  return typeof value === "number" ? value : null;
}

/** What a run did, newest last. */
export interface ActivityLine {
  readonly at: number;
  readonly text: string;
}

const activitySchema = z.array(z.object({ at: z.number(), text: z.string() }));

/** A column that does not read as activity counts as none: it is only ever shown. */
export function parseActivity(value: unknown): ActivityLine[] {
  if (typeof value !== "string") return [];
  try {
    const parsed = activitySchema.safeParse(JSON.parse(value));
    return parsed.success ? parsed.data : [];
  } catch {
    return [];
  }
}
