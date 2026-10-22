import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { buildReviewOptions, listModels, listSkills } from "../src/review-options.ts";

const folders: string[] = [];
afterEach(() => {
  for (const folder of folders.splice(0)) rmSync(folder, { recursive: true, force: true });
});

function home(): string {
  const dir = mkdtempSync(join(tmpdir(), "suica-options-"));
  folders.push(dir);
  return dir;
}

function write(path: string, text: string): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, text);
}

const skill = (description: string): string =>
  `---\nname: x\ndescription: ${description}\n---\n\n# Body\n`;

/** A plugin installed in the cache and listed in installed_plugins.json. */
function plugin(root: string, key: string, skills: readonly string[]): void {
  const [name, marketplace] = key.split("@");
  const dir = join(root, ".claude/plugins/cache", marketplace ?? "", name ?? "", "1.0.0");
  for (const id of skills) write(join(dir, "skills", id, "SKILL.md"), skill(`${id} skill`));
  const path = join(root, ".claude/plugins/installed_plugins.json");
  let installed: { plugins: Record<string, unknown> } = { plugins: {} };
  try {
    installed = JSON.parse(readFileSync(path, "utf8")) as typeof installed;
  } catch {
    // The first plugin.
  }
  installed.plugins[key] = [{ scope: "user", installPath: dir, version: "1.0.0" }];
  write(path, JSON.stringify(installed));
}

describe("listSkills", () => {
  it("lists personal and plugin skills, review skills first, with their descriptions", () => {
    const root = home();
    write(join(root, ".claude/skills/notes/SKILL.md"), skill("Takes notes"));
    plugin(root, "madhani@madhani", ["madhani-code-review", "madhani-go-coding-standard"]);
    plugin(root, "tools@market", ["code-review"]);
    expect(listSkills("madhani:madhani-code-review", root)).toEqual([
      {
        name: "madhani:madhani-code-review",
        description: "madhani-code-review skill",
        source: "plugin",
        plugin: "madhani",
        missing: false,
      },
      {
        name: "tools:code-review",
        description: "code-review skill",
        source: "plugin",
        plugin: "tools",
        missing: false,
      },
      {
        name: "madhani:madhani-go-coding-standard",
        description: "madhani-go-coding-standard skill",
        source: "plugin",
        plugin: "madhani",
        missing: false,
      },
      { name: "notes", description: "Takes notes", source: "user", plugin: null, missing: false },
    ]);
  });

  it("leaves out plugins turned off in settings and project-scoped installs", () => {
    const root = home();
    plugin(root, "off@market", ["review"]);
    plugin(root, "on@market", ["review"]);
    write(
      join(root, ".claude/settings.json"),
      JSON.stringify({ enabledPlugins: { "off@market": false } }),
    );
    const path = join(root, ".claude/plugins/installed_plugins.json");
    const installed = JSON.parse(readFileSync(path, "utf8")) as {
      plugins: Record<string, unknown>;
    };
    installed.plugins["proj@market"] = [{ scope: "project", installPath: "/elsewhere" }];
    write(path, JSON.stringify(installed));
    expect(listSkills("on:review", root).map((item) => item.name)).toEqual(["on:review"]);
  });

  it("scans the newest cached version when installed_plugins.json is missing", () => {
    const root = home();
    for (const version of ["1.9.0", "1.10.0"]) {
      write(
        join(root, ".claude/plugins/cache/market/madhani", version, "skills/review/SKILL.md"),
        skill(`version ${version}`),
      );
    }
    expect(listSkills("madhani:review", root)).toEqual([
      {
        name: "madhani:review",
        description: "version 1.10.0",
        source: "plugin",
        plugin: "madhani",
        missing: false,
      },
    ]);
  });

  it("keeps a skill without front matter, drops names the config refuses and folders without SKILL.md", () => {
    const root = home();
    write(join(root, ".claude/skills/plain/SKILL.md"), "# No front matter");
    write(join(root, ".claude/skills/has.dot/SKILL.md"), skill("dotted"));
    mkdirSync(join(root, ".claude/skills/empty"), { recursive: true });
    expect(listSkills("plain", root).map((item) => [item.name, item.description])).toEqual([
      ["plain", ""],
    ]);
  });

  it("lists a default that is not installed as missing", () => {
    expect(listSkills("gone:review", home())).toEqual([
      { name: "gone:review", description: "", source: "plugin", plugin: "gone", missing: true },
    ]);
  });
});

describe("listModels", () => {
  it("offers Claude Code's aliases and adds a configured name they lack", () => {
    const names = listModels("claude", "claude-opus-5-5", home()).map((model) => model.name);
    expect(names).toEqual(["opus", "sonnet", "haiku", "claude-opus-5-5"]);
    expect(listModels("claude", "sonnet", home())).toHaveLength(3);
  });

  it("reads Codex's listed models from its cache and skips hidden ones", () => {
    const root = home();
    write(
      join(root, ".codex/models_cache.json"),
      JSON.stringify({
        models: [
          {
            slug: "gpt-6.1-sol",
            display_name: "GPT-6.1-Sol",
            description: "Workhorse",
            visibility: "list",
          },
          { slug: "gpt-reserve", display_name: "GPT-Reserve", description: "", visibility: "hide" },
          { slug: "-bad", display_name: "Bad", visibility: "list" },
        ],
      }),
    );
    expect(listModels("codex", undefined, root)).toEqual([
      { name: "gpt-6.1-sol", label: "GPT-6.1-Sol", description: "Workhorse" },
    ]);
  });

  it("gives nothing for Codex without a readable cache, or for Gemini CLI", () => {
    const root = home();
    write(join(root, ".codex/models_cache.json"), "not json");
    expect(listModels("codex", undefined, root)).toEqual([]);
    expect(listModels("gemini", undefined, root)).toEqual([]);
  });
});

describe("buildReviewOptions", () => {
  it("names the defaults and lists no models without a CLI", () => {
    const options = buildReviewOptions({ skill: "notes", model: "opus" }, null, home());
    expect(options.version).toBe(1);
    expect(options.cli).toBeNull();
    expect(options.defaults).toEqual({ skill: "notes", model: "opus" });
    expect(options.models).toEqual([]);
  });

  it("matches the contract golden", () => {
    const root = home();
    plugin(root, "madhani@madhani", ["madhani-code-review"]);
    write(join(root, ".claude/skills/notes/SKILL.md"), skill("Takes notes"));
    const golden: unknown = JSON.parse(
      readFileSync(new URL("../contracts/review-options.v1.json", import.meta.url), "utf8"),
    );
    expect(
      buildReviewOptions({ skill: "madhani:madhani-code-review", model: "sonnet" }, "claude", root),
    ).toEqual(golden);
  });
});
