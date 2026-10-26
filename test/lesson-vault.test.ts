import { spawnSync } from "node:child_process";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { LessonRow, OccurrenceRow } from "../src/lesson-store.ts";
import { createHash } from "node:crypto";
import { exportVault, renderVault, slug } from "../src/lessons/vault.ts";
import { openStore } from "../src/store.ts";

const NOW = Date.UTC(2026, 9, 26, 9);
const DAY = 86_400_000;
const SCOPE = "/work/acme";

function lesson(id: number, extra: Partial<LessonRow> = {}): LessonRow {
  return {
    id,
    scope: SCOPE,
    title: `Lesson ${id}`,
    rule: `Rule ${id}`,
    topics: ["errors"],
    globs: ["**/*.go"],
    archived: false,
    createdAt: NOW,
    updatedAt: NOW,
    ...extra,
  };
}

function occ(id: number, lessonId: number, extra: Partial<OccurrenceRow> = {}): OccurrenceRow {
  return {
    sourceKey: `review:${id}:1`,
    source: "review",
    mrKey: "acme/api!7",
    mrTitle: "T",
    mrUrl: "https://gitlab.example/acme/api/-/merge_requests/7",
    repoPath: null,
    path: "pkg/a.go",
    line: 12,
    severity: "Major",
    title: "t",
    text: "text",
    outcome: "fixed",
    at: NOW - DAY,
    id,
    lessonId,
    failures: 0,
    retryAt: null,
    ...extra,
  };
}

function reader(
  lessons: LessonRow[],
  occurrences: OccurrenceRow[],
  links: [number, number][] = [],
) {
  return {
    lessons: (scope: string, includeArchived = false) =>
      lessons.filter((l) => l.scope === scope && (includeArchived || !l.archived)),
    occurrences: (id: number) => occurrences.filter((o) => o.lessonId === id),
    links: (id: number) =>
      links.flatMap(([a, b]) => (a === id ? [b] : b === id ? [a] : [])).sort((x, y) => x - y),
  };
}

function render(
  lessons: LessonRow[],
  occurrences: OccurrenceRow[],
  links: [number, number][] = [],
  scopes: string[] = [SCOPE],
) {
  return renderVault(reader(lessons, occurrences, links), scopes, NOW);
}

function noteOf(files: Map<string, string>, id: number): string {
  const key = [...files.keys()].find((k) => k.startsWith("Lessons/") && k.endsWith(`-${id}.md`));
  if (key === undefined) throw new Error(`no note for ${id}`);
  return files.get(key) ?? "";
}

let dir: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "suica-vault-"));
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

describe("slug", () => {
  it("is lowercase ascii words, at most 60 chars, then the id", () => {
    expect(slug("Wrap errors: use %w!", 7)).toBe("wrap-errors-use-w-7");
    const long = slug("word ".repeat(40), 123);
    expect(long.endsWith("-123")).toBe(true);
    expect(long.length).toBeLessThanOrEqual(64);
    expect(slug("日本語のタイトル", 5)).toBe("lesson-5");
  });
  it("differs for equal titles", () => {
    expect(slug("Same", 1)).not.toBe(slug("Same", 2));
  });
});

describe("renderVault", () => {
  it("gives each lesson a note linked to its topics and repos", () => {
    const files = render(
      [lesson(1, { title: "Wrap errors", rule: "Wrap with %w.", topics: ["errors", "go-style"] })],
      [
        occ(1, 1, { text: "line one\nline two" }),
        occ(2, 1, { mrKey: "acme/web!3", mrUrl: "https://x/3" }),
      ],
    );
    const note = noteOf(files, 1);
    expect(note).toMatch(
      /^---\nid: 1\nscope: "acme"\ntopics: \["errors", "go-style"\]\nweight: \d+\.\d{2}\n/,
    );
    expect(note).toContain("first_seen: 2026-10-25\nlast_seen: 2026-10-25\n---");
    expect(note).toContain("# Wrap errors\n\nWrap with %w.");
    expect(note).toContain("## Topics\n- [[Topics/errors]]\n- [[Topics/go-style]]");
    expect(note).toContain(
      "- [[Repos/acme-api]] [!7](https://gitlab.example/acme/api/-/merge_requests/7) `pkg/a.go:12` Major, fixed: line one line two",
    );
    expect(note).toContain("[[Repos/acme-web]] [!3](https://x/3)");
    expect(files.get("Topics/errors.md")).toContain("[[Lessons/wrap-errors-1|Wrap errors]]");
    expect(files.get("Repos/acme-api.md")).toContain("[[Lessons/wrap-errors-1|Wrap errors]]");
    expect(files.has("Repos/acme-web.md")).toBe(true);
    expect(files.has("index.md")).toBe(true);
  });

  it("ranks the index by weight", () => {
    const files = render(
      [lesson(1, { title: "Light" }), lesson(2, { title: "Heavy" })],
      [occ(1, 1, { severity: "Nit" }), occ(2, 2, { severity: "Blocker" })],
    );
    const index = files.get("index.md") ?? "";
    expect(index.indexOf("Heavy")).toBeGreaterThan(-1);
    expect(index.indexOf("Heavy")).toBeLessThan(index.indexOf("Light"));
    expect(index).toContain("[[Lessons/heavy-2|Heavy]]");
  });

  it("leaves out archived, scope-less and occurrence-less lessons", () => {
    const files = render(
      [lesson(1), lesson(2, { archived: true }), lesson(3, { scope: "" }), lesson(4)],
      [occ(1, 1), occ(2, 2), occ(3, 3)],
      [],
      [SCOPE, ""],
    );
    const lessons = [...files.keys()].filter((k) => k.startsWith("Lessons/"));
    expect(lessons).toEqual(["Lessons/lesson-1-1.md"]);
  });

  it("slugs of equal titles differ", () => {
    const files = render(
      [lesson(1, { title: "Same" }), lesson(2, { title: "Same" })],
      [occ(1, 1), occ(2, 2)],
    );
    expect([...files.keys()].filter((k) => k.startsWith("Lessons/"))).toEqual([
      "Lessons/same-1.md",
      "Lessons/same-2.md",
    ]);
  });

  it("names no author", () => {
    const files = render(
      [lesson(1)],
      [occ(1, 1, { text: "Fix this", mrTitle: "Dana Whitfield's change" })],
    );
    for (const content of files.values()) expect(content).not.toContain("Dana");
  });

  it("escapes front matter values", () => {
    const nasty = 'Use: "quotes" --- # and \\ here\nnext';
    const files = render(
      [lesson(1, { title: nasty, scope: "/work/my projects" })],
      [occ(1, 1)],
      [],
      ["/work/my projects"],
    );
    const note = noteOf(files, 1);
    const front = note.split("\n---\n")[0] ?? "";
    expect(front).toContain('scope: "my projects"');
    expect(front.split("\n").length).toBe(7);
    const heading = note.split("\n").find((l) => l.startsWith("# "));
    expect(heading).toBeDefined();
    expect(heading).not.toContain("[[");
  });

  it("only writes kebab topics and file-safe repo names", () => {
    const files = render(
      [lesson(1, { topics: ["ok-topic", "../evil", "Bad Topic"] })],
      [occ(1, 1, { mrKey: "../x/y z!1" })],
    );
    expect([...files.keys()].filter((k) => k.startsWith("Topics/"))).toEqual([
      "Topics/ok-topic.md",
    ]);
    for (const key of files.keys()) {
      expect(key).not.toContain("..");
      expect(key.split("/").length).toBeLessThanOrEqual(2);
    }
  });

  it("sanitises wiki-link titles", () => {
    const files = render([lesson(1, { title: "A|B] [C] #D" })], [occ(1, 1)]);
    const index = files.get("index.md") ?? "";
    const link = /\[\[Lessons\/[^|\]]+\|([^\]]*)\]\]/.exec(index);
    expect(link).not.toBeNull();
    expect(link?.[1]).not.toMatch(/[|[\]#]/);
    expect(link?.[1]).toContain("A");
  });

  it("neutralises injected links and code in occurrence text", () => {
    const files = render(
      [lesson(1)],
      [occ(1, 1, { text: "see [[Secrets]] and `rm -rf`\n# Heading\n> quote" })],
    );
    const line = noteOf(files, 1)
      .split("\n")
      .find((l) => l.startsWith("- [[Repos/"));
    expect(line).toBeDefined();
    expect(line).not.toContain("[[Secrets");
    expect(line).not.toContain("rm -rf`");
    expect(line?.split(": ").slice(1).join(": ")).not.toContain("\n");
    expect(line?.match(/\[\[/g)?.length).toBe(1);
  });

  it("caps occurrence text at 300 characters", () => {
    const files = render([lesson(1)], [occ(1, 1, { text: "x".repeat(1000) })]);
    const line =
      noteOf(files, 1)
        .split("\n")
        .find((l) => l.startsWith("- [[Repos/")) ?? "";
    expect(line.length).toBeLessThan(500);
    expect(line).not.toContain("x".repeat(301));
  });

  it("links related lessons within a scope only", () => {
    const files = render(
      [lesson(1), lesson(2), lesson(3, { scope: "/work/other" })],
      [occ(1, 1), occ(2, 2), occ(3, 3)],
      [
        [1, 2],
        [1, 3],
      ],
      [SCOPE, "/work/other"],
    );
    const note = noteOf(files, 1);
    expect(note).toContain("## Related\n- [[Lessons/lesson-2-2|Lesson 2]]");
    expect(note).not.toContain("lesson-3");
    expect(noteOf(files, 3)).not.toContain("lesson-1");
  });

  it("is deterministic", () => {
    const args = [
      [lesson(1), lesson(2)],
      [occ(1, 1), occ(2, 2), occ(3, 1, { at: NOW - 3 * DAY })],
      [[1, 2]],
    ] as const;
    const a = render([...args[0]], [...args[1]], [[1, 2]]);
    const b = render([...args[0]], [...args[1]], [[1, 2]]);
    expect([...b.entries()]).toEqual([...a.entries()]);
  });
});

describe("renderVault labels, repos and untrusted text", () => {
  it("labels a scope under the home folder with ~ and others by basename", () => {
    const home = "/Users/me";
    const lessons = [
      lesson(1, { scope: "/Users/me/repo.madhani.one" }),
      lesson(2, { scope: "/elsewhere/other" }),
    ];
    const files = renderVault(
      reader(lessons, [occ(1, 1), occ(2, 2)]),
      ["/Users/me/repo.madhani.one", "/elsewhere/other"],
      NOW,
      home,
    );
    expect(noteOf(files, 1)).toContain('scope: "~/repo.madhani.one"');
    expect(noteOf(files, 2)).toContain('scope: "other"');
    for (const content of files.values()) expect(content).not.toContain("/Users/me");
  });

  it("renders an absolute occurrence path as its basename", () => {
    const files = render([lesson(1)], [occ(1, 1, { path: "/Users/me/secret/dir/a.go", line: 3 })]);
    const note = noteOf(files, 1);
    expect(note).toContain("`a.go:3`");
    expect(note).not.toContain("/Users/me");
  });

  it("neutralises images and html in untrusted text", () => {
    const files = render(
      [lesson(1, { title: "T <b>x</b>", rule: "![r](https://evil/r.png) <script>" })],
      [occ(1, 1, { text: "![x](https://evil/x.png) <img src=x onerror=1>" })],
    );
    for (const content of files.values()) {
      expect(content).not.toContain("<img");
      expect(content).not.toContain("<script");
      expect(content).not.toContain("<b>");
      expect(content).not.toMatch(/(^|[^\\])!\[/m);
    }
    expect(noteOf(files, 1)).toContain("&lt;img");
    expect(noteOf(files, 1)).toContain("\\![x]");
  });

  const sha6 = (project: string) => createHash("sha1").update(project).digest("hex").slice(0, 6);
  const repoFiles = (files: Map<string, string>) =>
    [...files.keys()].filter((k) => k.startsWith("Repos/")).sort();

  it("keeps the plain name for a plain project", () => {
    const files = render([lesson(1)], [occ(1, 1, { mrKey: "group/project!1" })]);
    expect(repoFiles(files)).toEqual(["Repos/group-project.md"]);
  });

  it("disambiguates names that collide after the / mapping", () => {
    const files = render(
      [lesson(1), lesson(2)],
      [occ(1, 1, { mrKey: "a/b-c!1" }), occ(2, 2, { mrKey: "a-b/c!1" })],
    );
    expect(repoFiles(files)).toEqual(
      [`Repos/a-b-c-${sha6("a/b-c")}.md`, `Repos/a-b-c-${sha6("a-b/c")}.md`].sort(),
    );
    expect(noteOf(files, 1)).toContain(`[[Repos/a-b-c-${sha6("a/b-c")}]]`);
  });

  it("disambiguates names that collide ignoring case", () => {
    const files = render(
      [lesson(1), lesson(2)],
      [occ(1, 1, { mrKey: "Foo/Bar!1" }), occ(2, 2, { mrKey: "foo/bar!1" })],
    );
    expect(repoFiles(files)).toEqual(
      [`Repos/Foo-Bar-${sha6("Foo/Bar")}.md`, `Repos/foo-bar-${sha6("foo/bar")}.md`].sort(),
    );
  });

  it("adds the hash when sanitising changed more than the slash", () => {
    const files = render([lesson(1)], [occ(1, 1, { mrKey: "g/p q!1" })]);
    expect(repoFiles(files)).toEqual([`Repos/g-p_q-${sha6("g/p q")}.md`]);
  });

  it("floors now to the UTC day so weights do not churn within a day", () => {
    const data = [lesson(1)];
    const os = [occ(1, 1)];
    const morning = renderVault(reader(data, os), [SCOPE], Date.UTC(2026, 9, 26, 1));
    const evening = renderVault(reader(data, os), [SCOPE], Date.UTC(2026, 9, 26, 23));
    expect([...evening]).toEqual([...morning]);
  });
});

describe("exportVault", () => {
  const data = () =>
    reader([lesson(1, { title: "One" }), lesson(2, { title: "Two" })], [occ(1, 1), occ(2, 2)]);

  it("writes files and a manifest of them", () => {
    const result = exportVault(data(), [SCOPE], dir, NOW);
    expect(result.removed).toBe(0);
    expect(result.written).toBe(readdirSync(join(dir, "Lessons")).length + 1 + 1 + 1);
    const manifest = JSON.parse(readFileSync(join(dir, ".suica-vault.json"), "utf8")) as {
      files: string[];
    };
    expect(manifest.files).toContain("Lessons/one-1.md");
    expect(manifest.files).toContain("index.md");
    expect(readFileSync(join(dir, "Lessons/one-1.md"), "utf8")).toContain("# One");
  });

  it("resolves scopes, so a trailing slash or .. exports the same files and deletes nothing", () => {
    const exact = exportVault(data(), [SCOPE], dir, NOW);
    const files = readdirSync(join(dir, "Lessons")).sort();
    const again = exportVault(data(), [`${SCOPE}/`, "", "/work/x/../acme"], dir, NOW);
    expect(again).toEqual({ written: 0, removed: 0, conflicts: 0 });
    expect(readdirSync(join(dir, "Lessons")).sort()).toEqual(files);
    expect(exact.written).toBeGreaterThan(1);
    expect(render([lesson(1)], [occ(1, 1)], [], [`${SCOPE}/`])).toEqual(
      render([lesson(1)], [occ(1, 1)]),
    );
  });

  it("creates the vault dir when missing", () => {
    const target = join(dir, "new", "vault");
    exportVault(data(), [SCOPE], target, NOW);
    expect(existsSync(join(target, "index.md"))).toBe(true);
  });

  it("writes byte-identical files twice and skips rewriting them", () => {
    exportVault(data(), [SCOPE], dir, NOW);
    const file = join(dir, "Lessons/one-1.md");
    const before = lstatSync(file);
    const text = readFileSync(file, "utf8");
    const again = exportVault(data(), [SCOPE], dir, NOW);
    const after = lstatSync(file);
    expect(again).toEqual({ written: 0, removed: 0, conflicts: 0 });
    expect(after.ino).toBe(before.ino);
    expect(after.mtimeMs).toBe(before.mtimeMs);
    expect(readFileSync(file, "utf8")).toBe(text);
  });

  it("removes the note of a lesson that disappeared, and keeps unrelated files", () => {
    exportVault(data(), [SCOPE], dir, NOW);
    writeFileSync(join(dir, "mine.md"), "mine");
    writeFileSync(join(dir, "Lessons", "handwritten.md"), "hand");
    const result = exportVault(
      reader([lesson(1, { title: "One" })], [occ(1, 1)]),
      [SCOPE],
      dir,
      NOW,
    );
    expect(result.removed).toBeGreaterThanOrEqual(1);
    expect(existsSync(join(dir, "Lessons/two-2.md"))).toBe(false);
    expect(existsSync(join(dir, "Lessons/one-1.md"))).toBe(true);
    expect(readFileSync(join(dir, "mine.md"), "utf8")).toBe("mine");
    expect(readFileSync(join(dir, "Lessons", "handwritten.md"), "utf8")).toBe("hand");
    expect(existsSync(join(dir, "Lessons"))).toBe(true);
  });

  it("never removes a path outside the vault listed in a tampered manifest", () => {
    const outside = join(dir, "outside.txt");
    writeFileSync(outside, "keep");
    const vault = join(dir, "vault");
    mkdirSync(vault);
    writeFileSync(
      join(vault, ".suica-vault.json"),
      JSON.stringify({ version: 1, files: ["../outside.txt", "/etc/hosts"] }),
    );
    exportVault(data(), [SCOPE], vault, NOW);
    expect(readFileSync(outside, "utf8")).toBe("keep");
  });

  it("refuses a symlinked Lessons folder that leaves the vault", () => {
    const outside = mkdtempSync(join(tmpdir(), "suica-outside-"));
    try {
      const vault = join(dir, "vault");
      mkdirSync(vault);
      symlinkSync(outside, join(vault, "Lessons"));
      expect(() => exportVault(data(), [SCOPE], vault, NOW)).toThrow();
      expect(readdirSync(outside)).toEqual([]);
    } finally {
      rmSync(outside, { recursive: true, force: true });
    }
  });

  it("keeps a user's own files it did not write and counts them as conflicts", () => {
    mkdirSync(join(dir, "Topics"));
    writeFileSync(join(dir, "index.md"), "my index\n");
    writeFileSync(join(dir, "Topics", "errors.md"), "my topic\n");
    const first = exportVault(data(), [SCOPE], dir, NOW);
    expect(first.conflicts).toBe(2);
    expect(readFileSync(join(dir, "index.md"), "utf8")).toBe("my index\n");
    expect(readFileSync(join(dir, "Topics", "errors.md"), "utf8")).toBe("my topic\n");
    const manifest = JSON.parse(readFileSync(join(dir, ".suica-vault.json"), "utf8")) as {
      files: string[];
    };
    expect(manifest.files).not.toContain("index.md");
    expect(manifest.files).not.toContain("Topics/errors.md");
    // Later, with no lessons at all, nothing of the user's is deleted.
    const later = exportVault(reader([], []), [SCOPE], dir, NOW);
    expect(later.conflicts).toBe(1);
    expect(readFileSync(join(dir, "index.md"), "utf8")).toBe("my index\n");
    expect(readFileSync(join(dir, "Topics", "errors.md"), "utf8")).toBe("my topic\n");
  });

  it("adopts an identical file at a path outside the manifest", () => {
    exportVault(data(), [SCOPE], dir, NOW);
    rmSync(join(dir, ".suica-vault.json"));
    const again = exportVault(data(), [SCOPE], dir, NOW);
    expect(again.conflicts).toBe(0);
    expect(again.written).toBe(0);
    const manifest = JSON.parse(readFileSync(join(dir, ".suica-vault.json"), "utf8")) as {
      files: string[];
    };
    expect(manifest.files).toContain("index.md");
  });

  it("overwrites a manifest-listed file the user edited", () => {
    exportVault(data(), [SCOPE], dir, NOW);
    writeFileSync(join(dir, "index.md"), "edited");
    const again = exportVault(data(), [SCOPE], dir, NOW);
    expect(again.conflicts).toBe(0);
    expect(readFileSync(join(dir, "index.md"), "utf8")).toContain("# Lessons");
  });

  it("removes only files of the owned layout listed in the manifest", () => {
    mkdirSync(join(dir, "notes"));
    mkdirSync(join(dir, "Lessons", "deep"), { recursive: true });
    writeFileSync(join(dir, "notes", "private.md"), "private");
    writeFileSync(join(dir, "Lessons", "deep", "x.md"), "deep");
    writeFileSync(join(dir, "Lessons", "x.txt"), "txt");
    writeFileSync(
      join(dir, ".suica-vault.json"),
      JSON.stringify({
        version: 1,
        files: ["notes/private.md", "Lessons/deep/x.md", "Lessons/x.txt", "Lessons/gone-9.md"],
      }),
    );
    writeFileSync(join(dir, "Lessons", "gone-9.md"), "ours");
    const result = exportVault(data(), [SCOPE], dir, NOW);
    expect(result.removed).toBe(1);
    expect(existsSync(join(dir, "Lessons", "gone-9.md"))).toBe(false);
    expect(readFileSync(join(dir, "notes", "private.md"), "utf8")).toBe("private");
    expect(readFileSync(join(dir, "Lessons", "deep", "x.md"), "utf8")).toBe("deep");
    expect(readFileSync(join(dir, "Lessons", "x.txt"), "utf8")).toBe("txt");
  });

  it("writes nothing the second time within a UTC day", () => {
    exportVault(data(), [SCOPE], dir, Date.UTC(2026, 9, 26, 1));
    const again = exportVault(data(), [SCOPE], dir, Date.UTC(2026, 9, 26, 4));
    expect(again).toEqual({ written: 0, removed: 0, conflicts: 0 });
  });

  it("leaves no temp file behind", () => {
    exportVault(data(), [SCOPE], dir, NOW);
    expect(readdirSync(dir).filter((f) => f.includes("tmp"))).toEqual([]);
    expect(readdirSync(join(dir, "Lessons")).filter((f) => f.includes("tmp"))).toEqual([]);
  });

  it("refuses an empty, relative or root directory", () => {
    expect(() => exportVault(data(), [SCOPE], "", NOW)).toThrow();
    expect(() => exportVault(data(), [SCOPE], "vault", NOW)).toThrow();
    expect(() => exportVault(data(), [SCOPE], "/", NOW)).toThrow();
  });
});

describe("suica lessons export", () => {
  let configPath: string;
  let statePath: string;
  const run = (...args: string[]) => {
    const result = spawnSync(process.execPath, ["src/cli.ts", "lessons", "export", ...args], {
      encoding: "utf8",
      env: { ...process.env, SUICA_CONFIG: configPath },
    });
    return { status: result.status, stdout: result.stdout };
  };
  const write = (lessons: string) => {
    writeFileSync(
      configPath,
      `gitlab:\n  hostname: h\nstatePath: ${statePath}\nlessons:\n${lessons}`,
    );
  };
  beforeEach(() => {
    configPath = join(dir, "config.yaml");
    statePath = join(dir, "state", "state.db");
  });

  it("says when lessons are off or there is no vault path", () => {
    write("  enabled: false\n");
    expect(JSON.parse(run("--json").stdout)).toMatchObject({ version: 1, status: "disabled" });
    write("  enabled: true\n");
    const result = run("--json");
    expect(JSON.parse(result.stdout)).toMatchObject({ version: 1, status: "no-vault-path" });
    expect(result.status).toBe(1);
  }, 20_000);

  it("exports the stored lessons", () => {
    const store = openStore(statePath);
    store.lessons.addOccurrences([
      {
        sourceKey: "review:1:1",
        source: "review",
        mrKey: "acme/api!7",
        mrTitle: "T",
        mrUrl: "https://g/7",
        path: "a.go",
        line: 1,
        severity: "Major",
        title: "t",
        text: "text",
        outcome: "open",
        at: Date.now(),
      },
    ]);
    const id = store.lessons.createLesson(
      {
        scope: "/work/acme",
        title: "Wrap errors",
        rule: "Wrap.",
        topics: ["errors"],
        globs: ["*"],
      },
      Date.now(),
    );
    const row = store.lessons.occurrenceBySource("review:1:1");
    store.lessons.attach([row?.id ?? 0], id, Date.now());
    store.close();
    const vault = join(dir, "vault");
    write(`  enabled: true\n  scopes: ["/work/acme"]\n  vaultPath: ${vault}\n`);
    const result = run("--json");
    expect(result.status).toBe(0);
    expect(JSON.parse(result.stdout)).toMatchObject({
      version: 1,
      status: "exported",
      removed: 0,
      path: vault,
    });
    expect(existsSync(join(vault, `Lessons/wrap-errors-${id}.md`))).toBe(true);
    expect(run().stdout.trim().split("\n")).toHaveLength(1);
  }, 20_000);
});
