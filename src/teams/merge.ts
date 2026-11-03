import { YOUR_MR_KINDS } from "./types.ts";
import type { OutboxRow } from "./types.ts";

/** Most MRs one merged chat lists; a bigger group is split in order. */
export const MERGE_MAX = 10;

// shortcut: a key-shaped word such as UTF-8 counts as a ticket, upgrade when a false merge is reported
const TICKET = /\b[A-Z][A-Z0-9]+-\d+\b/;

/** The ticket key in an MR title, such as `ABC-123` in `[ABC-123] Add login`; null without one. */
export function ticketKey(title: string): string | null {
  return TICKET.exec(title)?.[0] ?? null;
}

/**
 * Groups rows that one chat can carry: same recipient, variant and ticket key, at most
 * `MERGE_MAX` each. A row without a key, or that is not a message about the Owner's own MR,
 * stays alone. Groups come in the order of their first row, which is the lead.
 */
export function groupForMerge(rows: readonly OutboxRow[]): OutboxRow[][] {
  const groups: OutboxRow[][] = [];
  const open = new Map<string, OutboxRow[]>();
  for (const row of rows) {
    const ticket = YOUR_MR_KINDS.includes(row.kind) ? ticketKey(row.mrTitle) : null;
    if (ticket === null) {
      groups.push([row]);
      continue;
    }
    const key = `${row.recipient}|${row.variant}|${ticket}`;
    let group = open.get(key);
    if (group === undefined || group.length >= MERGE_MAX) {
      group = [];
      open.set(key, group);
      groups.push(group);
    }
    group.push(row);
  }
  return groups;
}
