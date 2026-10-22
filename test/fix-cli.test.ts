import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { openStore } from "../src/store.ts";
import { thread } from "./fix-builders.ts";

let dir: string;
let configPath: string;
let statePath: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "suica-fix-cli-"));
  configPath = join(dir, "config.yaml");
  statePath = join(dir, "state", "state.db");
  writeFileSync(configPath, `gitlab:\n  hostname: h\nstatePath: ${statePath}\n`);
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

function suica(args: string[], input = ""): { status: number | null; stdout: string } {
  const result = spawnSync("node", ["src/cli.ts", ...args], {
    encoding: "utf8",
    input,
    env: { ...process.env, SUICA_CONFIG: configPath },
  });
  return { status: result.status, stdout: result.stdout };
}

describe("suica fix", () => {
  it("lists fixes, discards a ready one and says when there is nothing to do", () => {
    const store = openStore(statePath);
    const id =
      store.fixes.queue("g/p!7", "auto", [thread("d1", "n1")], Date.now(), "Add thing") ?? 0;
    store.fixes.transition(id, ["queued"], "ready", { diff: "" }, Date.now());
    store.close();

    const list = suica(["fix", "list", "--json"]);
    expect(list.status).toBe(0);
    const doc = JSON.parse(list.stdout) as {
      version: number;
      fixes: { id: number; status: string }[];
    };
    expect(doc.version).toBe(1);
    expect(doc.fixes.map((each) => [each.id, each.status])).toEqual([[id, "ready"]]);

    expect(suica(["fix", "discard", String(id), "--json"])).toEqual({
      status: 0,
      stdout: '{"status":"discarded"}\n',
    });
    expect(suica(["fix", "discard", String(id), "--json"])).toEqual({
      status: 1,
      stdout: '{"status":"nothing"}\n',
    });
    expect(suica(["fix", "confirm", String(id), "--json"], "not json")).toEqual({
      status: 1,
      stdout: '{"status":"bad-request"}\n',
    });
    expect(suica(["fix", "queue", "nope", "--json"])).toEqual({
      status: 1,
      stdout: '{"status":"bad-key"}\n',
    });
  });

  it("watches and unwatches an MR", () => {
    // The app reads the last line; log lines come before it.
    const last = (args: string[]) => {
      const { status, stdout } = suica(args);
      return { status, line: stdout.trimEnd().split("\n").at(-1) };
    };
    expect(last(["fix", "unwatch", "g/p!7", "--json"])).toEqual({
      status: 0,
      line: '{"status":"not-watching"}',
    });
    expect(last(["fix", "watch", "g/p!8", "--json"])).toEqual({
      status: 0,
      line: '{"status":"watching"}',
    });
    expect(last(["fix", "watch", "nope", "--json"])).toEqual({
      status: 1,
      line: '{"status":"bad-key"}',
    });
    const store = openStore(statePath);
    expect(store.fixes.watchChoices()).toEqual(
      new Map([
        ["g/p!7", false],
        ["g/p!8", true],
      ]),
    );
    store.close();
  });
});
