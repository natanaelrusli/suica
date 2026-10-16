import type { OutboxRow } from "./types.ts";

function hint(row: OutboxRow): string {
  switch (row.status) {
    case "unresolved":
      return ` (${row.detail}: add the person to teams.people, then \`suica retry ${row.id}\`)`;
    case "failed":
      return ` (${row.detail}: not retried automatically)`;
    case "sending":
      return " (may have been sent: check Teams)";
    default:
      return row.detail === "" ? "" : ` (${row.detail})`;
  }
}

/** Terminal listing for the Owner. It prints names and titles, so it is never logged. */
export function formatOutbox(rows: readonly OutboxRow[]): string {
  if (rows.length === 0) return "no messages\n";
  const lines: string[] = [];
  for (const row of rows) {
    lines.push(
      `#${row.id} [${row.status}] ${row.kind} → ${row.recipientName} · ${row.mrKey}${hint(row)}`,
    );
    if (row.status === "pending" && row.text !== null) {
      for (const line of row.text.split("\n")) lines.push(`    ${line}`);
    }
  }
  return `${lines.join("\n")}\n`;
}
