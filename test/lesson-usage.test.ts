import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { estimateTokens, fileUsageLog, readUsage } from "../src/lessons/usage.ts";
import type { UsageEntry } from "../src/lessons/usage.ts";

const DAY = 86_400_000;
const NOW = Date.UTC(2026, 9, 29, 9);

let tmp: string;
let dir: string;

beforeEach(() => {
  tmp = mkdtempSync(join(tmpdir(), "suica-usage-"));
  dir = join(tmp, "lessons-usage");
});
afterEach(() => {
  rmSync(tmp, { recursive: true, force: true });
});

function entry(at: number, extra: Partial<UsageEntry> = {}): UsageEntry {
  return {
    at,
    project: "g/app",
    scope: "/s",
    source: "session",
    lessonIds: [1, 2],
    tokens: 10,
    ...extra,
  };
}

describe("estimateTokens", () => {
  it("is the characters over four, rounded up", () => {
    expect(estimateTokens("")).toBe(0);
    expect(estimateTokens("abcd")).toBe(1);
    expect(estimateTokens("abcde")).toBe(2);
  });
});

describe("the usage log", () => {
  it("appends one line per entry to the UTC day file", () => {
    const first = entry(Date.UTC(2026, 9, 29, 23, 30));
    const second = entry(Date.UTC(2026, 9, 30, 0, 30), { source: "read", file: "src/a.go" });
    const log = fileUsageLog(dir, NOW);
    log.append(first);
    log.append(second);
    expect(readdirSync(dir).sort()).toEqual(["2026-10-29.jsonl", "2026-10-30.jsonl"]);
    for (const name of readdirSync(dir)) {
      expect(readFileSync(join(dir, name), "utf8").trimEnd().split("\n")).toHaveLength(1);
      expect(statSync(join(dir, name)).mode & 0o777).toBe(0o600);
    }
    expect(statSync(dir).mode & 0o777).toBe(0o700);
    expect(readUsage(dir, 0)).toEqual([first, second]);
  });

  it("skips malformed lines", () => {
    mkdirSync(dir);
    const good = entry(NOW);
    writeFileSync(
      join(dir, "2026-10-29.jsonl"),
      [
        JSON.stringify(good),
        '{"at":1,',
        "null",
        JSON.stringify({ ...good, lessonIds: undefined }),
        JSON.stringify({ ...good, source: "other" }),
        JSON.stringify({ ...good, lessonIds: [1.5] }),
      ].join("\n") + "\n",
    );
    expect(readUsage(dir, 0)).toEqual([good]);
  });

  it("drops entries before since", () => {
    mkdirSync(dir);
    const old = entry(NOW - 31 * DAY);
    const recent = entry(NOW - DAY);
    writeFileSync(
      join(dir, "2026-10-29.jsonl"),
      `${JSON.stringify(old)}\n${JSON.stringify(recent)}\n`,
    );
    expect(readUsage(dir, NOW - 30 * DAY)).toEqual([recent]);
  });

  it("prunes day files older than USAGE_DAYS on open", () => {
    mkdirSync(dir);
    for (const name of ["2026-09-01.jsonl", "2026-10-28.jsonl", "notes.txt"]) {
      writeFileSync(join(dir, name), "");
    }
    fileUsageLog(dir, Date.UTC(2026, 9, 29));
    expect(readdirSync(dir).sort()).toEqual(["2026-10-28.jsonl", "notes.txt"]);
  });

  it("never throws", () => {
    writeFileSync(dir, "");
    expect(() => fileUsageLog(dir, NOW).append(entry(NOW))).not.toThrow();
    expect(readUsage(dir, 0)).toEqual([]);
    expect(readUsage(join(tmp, "missing"), 0)).toEqual([]);
    expect(existsSync(join(tmp, "missing"))).toBe(false);
  });
});
