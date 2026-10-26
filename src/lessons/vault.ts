import {
  lstatSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { createHash } from "node:crypto";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, sep } from "node:path";
import type { LessonStore, OccurrenceRow } from "../lesson-store.ts";
import { weight } from "./match.ts";
import { projectOfMrKey } from "./scopes.ts";

/**
 * The vault: Lessons written as Markdown notes (an Obsidian vault, say). One way only: Suica owns
 * every file its manifest lists and overwrites it; it never touches a file it did not write.
 */

const MANIFEST = ".suica-vault.json";
const TEXT_MAX = 300;
const SLUG_MAX = 60;
const INDEX_MAX = 100;
const DAY_MS = 86_400_000;
/** What a manifest may list: the vault's own layout, one segment under each folder. */
const OWNED = /^(?:index\.md|(?:Lessons|Topics|Repos)\/[^/]+\.md)$/;
const TOPIC = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;

export type VaultReader = Pick<LessonStore, "lessons" | "occurrences" | "links">;

interface Entry {
  readonly lesson: ReturnType<VaultReader["lessons"]>[number];
  readonly weight: number;
  readonly occurrences: readonly OccurrenceRow[];
  readonly related: readonly number[];
}

/** Lowercase ASCII words joined by `-`, at most 60 characters, then `-<id>`. */
export function slug(title: string, id: number): string {
  const words = title.toLowerCase().match(/[a-z0-9]+/g) ?? [];
  let base = "";
  for (const word of words) {
    const next = base === "" ? word : `${base}-${word}`;
    if (next.length > SLUG_MAX) break;
    base = next;
  }
  if (base === "" && words.length > 0) base = (words[0] ?? "").slice(0, SLUG_MAX);
  return base === "" ? `lesson-${String(id)}` : `${base}-${String(id)}`;
}

/** One line, no backticks and no wiki-link brackets: free text cannot inject structure. */
function clean(text: string): string {
  return text
    .replace(/\s+/g, " ")
    .replace(/`/g, "")
    .replace(/\[\[|\]\]/g, "")
    .replace(/</g, "&lt;")
    .replace(/!\[/g, "\\![")
    .trim();
}

/** A title inside `[[target|title]]`: no `|`, `[`, `]` or `#`. */
function linkTitle(title: string): string {
  return (
    clean(title)
      .replace(/[|[\]#^\\]/g, " ")
      .replace(/\s+/g, " ")
      .trim() || "Lesson"
  );
}

function cap(text: string, max: number): string {
  return text.length <= max ? text : `${text.slice(0, max - 1)}…`;
}

function sanitised(project: string): string {
  const name = project
    .replaceAll("/", "-")
    .replace(/[^A-Za-z0-9._-]/g, "_")
    .replace(/^\.+/, "_");
  return name === "" ? "unknown" : name;
}

/**
 * Repos file names: `/` becomes `-`. A name that sanitising changed further, or that collides
 * with another project's ignoring case, gets the first 6 hex of the project's sha1 appended.
 */
function repoNames(projects: Iterable<string>): Map<string, string> {
  const all = [...new Set(projects)];
  const taken = new Map<string, number>();
  for (const project of all) {
    const key = sanitised(project).toLowerCase();
    taken.set(key, (taken.get(key) ?? 0) + 1);
  }
  return new Map(
    all.map((project) => {
      const name = sanitised(project);
      const plain = name === project.replaceAll("/", "-");
      const alone = taken.get(name.toLowerCase()) === 1;
      const hash = createHash("sha1").update(project).digest("hex").slice(0, 6);
      return [project, plain && alone ? name : `${name}-${hash}`];
    }),
  );
}

/** `~/<relative>` under the home folder, else the folder's own name: never an absolute path. */
function scopeLabel(scope: string, home: string): string {
  if (home !== "" && home !== sep && scope.startsWith(home + sep)) {
    return `~/${scope.slice(home.length + 1)}`;
  }
  return basename(scope) || scope;
}

function day(at: number): string {
  return new Date(at).toISOString().slice(0, 10);
}

/** A URL safe inside a Markdown link destination, or "" when it is not http(s). */
function safeUrl(url: string): string {
  if (!/^https?:\/\//i.test(url)) return "";
  return url.replace(/[\s()<>]/g, (c) => encodeURIComponent(c));
}

function iidOf(mrKey: string): string {
  const bang = mrKey.lastIndexOf("!");
  return bang < 0 ? "" : mrKey.slice(bang + 1).replace(/[^0-9]/g, "");
}

function noteTitle(entry: Entry): string {
  return clean(entry.lesson.title) || "Lesson";
}

function rule(text: string): string {
  const flat = clean(text);
  return /^[#>\-*+\d]/.test(flat) ? `\\${flat}` : flat;
}

function lessonNote(
  entry: Entry,
  byId: ReadonlyMap<number, Entry>,
  names: ReadonlyMap<string, string>,
  home: string,
): string {
  const { lesson, occurrences } = entry;
  const topics = lesson.topics.filter((t) => TOPIC.test(t));
  const times = occurrences.map((o) => o.at);
  const lines = [
    "---",
    `id: ${String(lesson.id)}`,
    `scope: ${JSON.stringify(scopeLabel(lesson.scope, home))}`,
    `topics: [${topics.map((t) => JSON.stringify(t)).join(", ")}]`,
    `weight: ${entry.weight.toFixed(2)}`,
    `first_seen: ${day(Math.min(...times))}`,
    `last_seen: ${day(Math.max(...times))}`,
    "---",
    "",
    `# ${noteTitle(entry)}`,
    "",
    rule(lesson.rule),
    "",
    "## Related",
    ...entry.related.flatMap((id) => {
      const other = byId.get(id);
      return other === undefined
        ? []
        : [`- [[Lessons/${slug(other.lesson.title, id)}|${linkTitle(other.lesson.title)}]]`];
    }),
    "",
    "## Topics",
    ...topics.map((t) => `- [[Topics/${t}]]`),
    "",
    "## Occurrences",
    ...[...occurrences]
      .sort((a, b) => b.at - a.at || b.id - a.id)
      .map((o) => {
        const url = safeUrl(o.mrUrl);
        const iid = iidOf(o.mrKey);
        const mr = url === "" ? `!${iid}` : `[!${iid}](${url})`;
        const where =
          o.path === null
            ? ""
            : ` \`${clean(isAbsolute(o.path) ? basename(o.path) : o.path)}${o.line === null ? "" : `:${String(o.line)}`}\``;
        return `- [[Repos/${names.get(projectOfMrKey(o.mrKey)) ?? "unknown"}]] ${mr}${where} ${clean(o.severity)}, ${clean(o.outcome)}: ${cap(clean(o.text), TEXT_MAX)}`;
      }),
    "",
  ];
  return lines.join("\n");
}

function listNote(title: string, entries: readonly Entry[]): string {
  return [
    `# ${title}`,
    "",
    ...entries.map(
      (e) =>
        `- [[Lessons/${slug(e.lesson.title, e.lesson.id)}|${linkTitle(e.lesson.title)}]] (${e.weight.toFixed(2)})`,
    ),
    "",
  ].join("\n");
}

function gather(reader: VaultReader, scopes: readonly string[], now: number): Entry[] {
  const out: Omit<Entry, "related">[] = [];
  for (const scope of new Set(scopes)) {
    if (scope === "") continue;
    for (const lesson of reader.lessons(scope)) {
      if (lesson.archived || lesson.scope === "") continue;
      const occurrences = reader.occurrences(lesson.id);
      if (occurrences.length === 0) continue;
      out.push({ lesson, weight: weight(occurrences, now), occurrences });
    }
  }
  const scopeOf = new Map(out.map((e) => [e.lesson.id, e.lesson.scope]));
  return out
    .sort((a, b) => b.weight - a.weight || a.lesson.id - b.lesson.id)
    .map((e) => ({
      ...e,
      related: reader
        .links(e.lesson.id)
        .filter((id) => scopeOf.get(id) === e.lesson.scope)
        .sort((a, b) => a - b),
    }));
}

/** Every file of the vault as relative POSIX path to content; no disk involved. */
export function renderVault(
  reader: VaultReader,
  scopes: readonly string[],
  now: number,
  home: string = homedir(),
): Map<string, string> {
  // Weights move with time: counting by whole UTC days keeps a re-export within a day identical.
  const entries = gather(reader, scopes, now - (now % DAY_MS));
  const names = repoNames(
    entries.flatMap((e) => e.occurrences.map((o) => projectOfMrKey(o.mrKey))),
  );
  const byId = new Map(entries.map((e) => [e.lesson.id, e]));
  const files = new Map<string, string>();
  const topics = new Map<string, Entry[]>();
  const repos = new Map<string, Entry[]>();
  for (const e of entries) {
    files.set(`Lessons/${slug(e.lesson.title, e.lesson.id)}.md`, lessonNote(e, byId, names, home));
    for (const t of new Set(e.lesson.topics.filter((x) => TOPIC.test(x)))) {
      topics.set(t, [...(topics.get(t) ?? []), e]);
    }
    for (const project of new Set(
      e.occurrences.map((o) => names.get(projectOfMrKey(o.mrKey)) ?? "unknown"),
    )) {
      repos.set(project, [...(repos.get(project) ?? []), e]);
    }
  }
  for (const [t, list] of topics) files.set(`Topics/${t}.md`, listNote(t, list));
  for (const [r, list] of repos) files.set(`Repos/${r}.md`, listNote(r, list));
  files.set(
    "index.md",
    [
      "# Lessons",
      "",
      ...entries
        .slice(0, INDEX_MAX)
        .map(
          (e) =>
            `- [[Lessons/${slug(e.lesson.title, e.lesson.id)}|${linkTitle(e.lesson.title)}]] (${e.weight.toFixed(2)}, ${String(e.occurrences.length)}x)`,
        ),
      "",
    ].join("\n"),
  );
  return files;
}

function insideVault(root: string, path: string): boolean {
  return path === root || path.startsWith(root + sep);
}

/** A manifest entry that stays inside the vault: relative, POSIX, no `..`, not the manifest. */
function validRelative(path: unknown): path is string {
  if (typeof path !== "string" || path === "" || path === MANIFEST) return false;
  if (isAbsolute(path) || path.includes("\\") || path.includes("\0")) return false;
  return path.split("/").every((part) => part !== "" && part !== "." && part !== "..");
}

function readManifest(dir: string): string[] {
  try {
    const parsed: unknown = JSON.parse(readFileSync(join(dir, MANIFEST), "utf8"));
    const files = (parsed as { files?: unknown }).files;
    const list: unknown[] = Array.isArray(files) ? files : [];
    return list.filter((f): f is string => validRelative(f) && OWNED.test(f));
  } catch {
    return [];
  }
}

function sameContent(path: string, content: string): boolean {
  try {
    return !lstatSync(path).isSymbolicLink() && readFileSync(path, "utf8") === content;
  } catch {
    return false;
  }
}

/** Atomic: a temp file in the same folder, then a rename (which replaces a symlink, not follows it). */
let tempCount = 0;
function writeAtomic(path: string, content: string): void {
  tempCount += 1;
  const temp = join(dirname(path), `.suica-tmp-${String(process.pid)}-${String(tempCount)}`);
  try {
    writeFileSync(temp, content, { flag: "wx" });
    renameSync(temp, path);
  } catch (error) {
    rmSync(temp, { force: true });
    throw error;
  }
}

/** Writes the vault into `dir` and removes the files an earlier export wrote that are gone now. */
export function exportVault(
  reader: VaultReader,
  scopes: readonly string[],
  dir: string,
  now: number,
): { written: number; removed: number; conflicts: number } {
  if (dir === "" || !isAbsolute(dir) || dir === sep || dir.replace(/[\\/]+$/, "") === "") {
    throw new Error("vault path must be an absolute folder other than the root");
  }
  const files = renderVault(reader, scopes, now);
  mkdirSync(dir, { recursive: true });
  const root = realpathSync(dir);
  const checked = new Set<string>();
  const guard = (relative: string): string => {
    const target = join(root, ...relative.split("/"));
    const parent = dirname(target);
    if (!checked.has(parent)) {
      mkdirSync(parent, { recursive: true });
      if (!insideVault(root, realpathSync(parent))) {
        throw new Error(`vault folder ${relative.split("/")[0] ?? ""} leaves the vault`);
      }
      checked.add(parent);
    }
    return target;
  };
  // Check every folder before writing anything, so a refused vault is left as it was.
  const targets = [...files.keys()].sort().map((relative) => [relative, guard(relative)] as const);
  const previous = readManifest(root);
  const ours = new Set(previous);
  const owned: string[] = [];
  let written = 0;
  let conflicts = 0;
  for (const [relative, target] of targets) {
    const content = files.get(relative) ?? "";
    if (sameContent(target, content)) {
      owned.push(relative);
      continue;
    }
    // A file Suica did not write and the user may have: left alone, never adopted.
    if (!ours.has(relative) && lstatSync(target, { throwIfNoEntry: false }) !== undefined) {
      conflicts += 1;
      continue;
    }
    writeAtomic(target, content);
    owned.push(relative);
    written += 1;
  }
  let removed = 0;
  for (const relative of previous) {
    if (files.has(relative)) continue;
    try {
      const target = join(root, ...relative.split("/"));
      if (lstatSync(target, { throwIfNoEntry: false }) === undefined) continue;
      if (!insideVault(root, realpathSync(dirname(target)))) continue;
      rmSync(target, { force: true });
      removed += 1;
    } catch {
      // Already gone or unreadable: nothing of ours to remove.
    }
  }
  const manifest = `${JSON.stringify({ version: 1, files: owned.sort() }, null, 2)}\n`;
  const manifestPath = join(root, MANIFEST);
  if (!sameContent(manifestPath, manifest)) writeAtomic(manifestPath, manifest);
  return { written, removed, conflicts };
}
