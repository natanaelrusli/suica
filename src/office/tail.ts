import { closeSync, fstatSync, openSync, readSync } from "node:fs";

/** A line this long is a request blob, not an event; it is skipped without being parsed. */
const MAX_LINE_BYTES = 512 * 1024;

/**
 * The complete lines in the last `bytes` of a file, oldest first. A window that starts mid-file
 * drops its first, partial line. A missing or unreadable file has no lines.
 */
export function readTail(path: string, bytes: number, maxLine = MAX_LINE_BYTES): string[] {
  let fd: number;
  try {
    fd = openSync(path, "r");
  } catch {
    return [];
  }
  try {
    const size = fstatSync(fd).size;
    const start = Math.max(0, size - bytes);
    const buffer = Buffer.alloc(size - start);
    let read = 0;
    while (read < buffer.length) {
      const n = readSync(fd, buffer, read, buffer.length - read, start + read);
      if (n === 0) break;
      read += n;
    }
    const lines = buffer.subarray(0, read).toString("utf8").split("\n");
    if (start > 0) lines.shift();
    return lines.filter((line) => line !== "" && line.length <= maxLine);
  } catch {
    return [];
  } finally {
    closeSync(fd);
  }
}

/** The first line of a file (read from its first `bytes`), or undefined. */
export function readHead(path: string, bytes: number): string | undefined {
  let fd: number;
  try {
    fd = openSync(path, "r");
  } catch {
    return undefined;
  }
  try {
    const buffer = Buffer.alloc(bytes);
    const n = readSync(fd, buffer, 0, bytes, 0);
    const text = buffer.subarray(0, n).toString("utf8");
    const end = text.indexOf("\n");
    return end === -1 ? (text === "" ? undefined : text) : text.slice(0, end);
  } catch {
    return undefined;
  } finally {
    closeSync(fd);
  }
}
