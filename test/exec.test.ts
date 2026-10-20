import { describe, expect, it } from "vitest";
import { defaultExec } from "../src/exec.ts";

describe("defaultExec", () => {
  it("passes each stdout line on as it arrives, the last one too, and still returns stdout whole", async () => {
    const lines: string[] = [];
    const result = await defaultExec("printf", ["one\\ntwo\\nthree"], {
      timeoutMs: 5000,
      onStdoutLine: (line) => lines.push(line),
    });
    expect(lines).toEqual(["one", "two", "three"]);
    expect(result.stdout).toBe("one\ntwo\nthree");
  });
});
