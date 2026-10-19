/**
 * Inline posting of an Agent Review: findings that name a line of the reviewed diff become diff
 * threads on that line, and the rest of the review stays in one summary note.
 */

/** A top-level list item under a "Findings" heading that starts with a `path:line` code span. */
export interface Finding {
  /** The list number ("3") or, for a bullet, its position among the findings. */
  readonly number: string;
  readonly path: string;
  readonly line: number;
  /** The item without its marker and location, continuation lines included. */
  readonly text: string;
  /** Lines `[start, end)` of the review the item occupies. */
  readonly start: number;
  readonly end: number;
}

const FENCE = /^\s*(```|~~~)/;
const HEADING = /^(#{1,6})\s+(.*)$/;
const LIST_ITEM = /^ {0,3}(?:\d+[.)]|[-*+])\s/;
/** `1. \`path:12\` — text` or `- \`path:12-20\`: text`; a range is placed on its first line. */
const FINDING_ITEM =
  /^( {0,3}(?:(\d+)[.)]|[-*+])\s+)`([^`\s]+):(\d+)(?:[-–]\d+)?`[ \t]*(?:[—–:-][ \t]*)?(.*)$/;

/**
 * The findings a review lists under a heading named Findings (with its subheadings, such as one
 * per severity). A finding whose location is not its first code span is left in the summary.
 */
export function extractFindings(markdown: string): Finding[] {
  const lines = markdown.replace(/\r\n/g, "\n").split("\n");
  const findings: Finding[] = [];
  let sectionLevel: number | undefined;
  let inFence = false;
  let index = 0;
  while (index < lines.length) {
    const line = lines[index] ?? "";
    if (FENCE.test(line)) inFence = !inFence;
    const heading = inFence ? null : HEADING.exec(line);
    if (heading !== null) {
      const level = heading[1]?.length ?? 1;
      if (/\bfindings\b/i.test(heading[2] ?? "")) sectionLevel = level;
      else if (sectionLevel !== undefined && level <= sectionLevel) sectionLevel = undefined;
      index += 1;
      continue;
    }
    const match = inFence || sectionLevel === undefined ? null : FINDING_ITEM.exec(line);
    if (match === null) {
      index += 1;
      continue;
    }
    const indent = match[1]?.length ?? 0;
    const end = itemEnd(lines, index + 1);
    const continuation = lines
      .slice(index + 1, end)
      .map((rest) => rest.replace(new RegExp(`^ {0,${indent}}`), ""));
    findings.push({
      number: match[2] ?? String(findings.length + 1),
      path: match[3] ?? "",
      line: Number(match[4]),
      text: [match[5] ?? "", ...continuation].join("\n").trim(),
      start: index,
      end,
    });
    index = end;
  }
  return findings;
}

/** The line after an item: the next item, a heading, or an unindented line after a blank one. */
function itemEnd(lines: readonly string[], from: number): number {
  let inFence = false;
  let last = from;
  for (let index = from; index < lines.length; index += 1) {
    const line = lines[index] ?? "";
    if (FENCE.test(line)) {
      inFence = !inFence;
      last = index + 1;
      continue;
    }
    if (inFence) {
      last = index + 1;
      continue;
    }
    if (line.trim() === "") continue;
    const afterBlank = index > last;
    if (LIST_ITEM.test(line) || HEADING.test(line) || (afterBlank && !/^\s/.test(line))) break;
    last = index + 1;
  }
  return last;
}

/**
 * The lines of the new file a unified diff shows, each with its line in the old file: null for
 * an added line, a number for an unchanged context line. Removed lines have no new line.
 */
export function diffLines(diff: string): Map<number, number | null> {
  const lines = new Map<number, number | null>();
  let oldLine = 0;
  let newLine = 0;
  for (const line of diff.split("\n")) {
    const hunk = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(line);
    if (hunk !== null) {
      oldLine = Number(hunk[1]);
      newLine = Number(hunk[2]);
    } else if (newLine === 0 || line.startsWith("\\")) {
      // Before the first hunk, or "\ No newline at end of file".
    } else if (line.startsWith("+")) {
      lines.set(newLine, null);
      newLine += 1;
    } else if (line.startsWith("-")) {
      oldLine += 1;
    } else {
      lines.set(newLine, oldLine);
      oldLine += 1;
      newLine += 1;
    }
  }
  return lines;
}

export interface VersionDiffFile {
  readonly oldPath: string;
  readonly newPath: string;
  readonly diff: string;
}

export interface DiffRefs {
  readonly baseSha: string;
  readonly startSha: string;
  readonly headSha: string;
}

/** The `position` GitLab takes for a diff thread on a text line. */
export interface ThreadPosition {
  readonly position_type: "text";
  readonly base_sha: string;
  readonly start_sha: string;
  readonly head_sha: string;
  readonly old_path: string;
  readonly new_path: string;
  readonly new_line: number;
  /** Set for an unchanged line, which GitLab places by both numbers. */
  readonly old_line?: number;
}

/**
 * Where each finding goes in the diff, or undefined when its file or line is not in it. The
 * model reads the checkout in ./repo, so a `repo/` or `./` prefix on the path is dropped.
 */
export function placeFinding(
  finding: Finding,
  files: readonly VersionDiffFile[],
  refs: DiffRefs,
): ThreadPosition | undefined {
  const path = finding.path.replace(/^(\.\/)?(repo\/)?/, "");
  const file = files.find((candidate) => candidate.newPath === path);
  if (file === undefined) return undefined;
  const lines = diffLines(file.diff);
  if (!lines.has(finding.line)) return undefined;
  const oldLine = lines.get(finding.line);
  return {
    position_type: "text",
    base_sha: refs.baseSha,
    start_sha: refs.startSha,
    head_sha: refs.headSha,
    old_path: file.oldPath,
    new_path: file.newPath,
    new_line: finding.line,
    ...(oldLine === null || oldLine === undefined ? {} : { old_line: oldLine }),
  };
}

/** The review with each finding posted as a thread cut down to a pointer to it. */
export function summaryWithout(markdown: string, posted: readonly Finding[]): string {
  const lines = markdown.replace(/\r\n/g, "\n").split("\n");
  const byStart = new Map(posted.map((finding) => [finding.start, finding]));
  const out: string[] = [];
  for (let index = 0; index < lines.length; index += 1) {
    const finding = byStart.get(index);
    if (finding === undefined) {
      out.push(lines[index] ?? "");
      continue;
    }
    const location = /^(.*?`[^`]+`)/.exec(lines[index] ?? "")?.[1] ?? "";
    out.push(`${location} — posted as an inline comment on that line.`);
    index = finding.end - 1;
  }
  return out.join("\n");
}
