import { createInterface } from "node:readline";
import { z } from "zod";

// Modes: ok | noisy (prints non-JSON lines first) | silent (never answers) | crash (exits at once).
// Tools: echo, fail (isError), bad (malformed result), anything else never answers (hang).
const mode = process.argv[2] ?? "ok";
if (mode === "crash") process.exit(3);

const requestSchema = z.object({
  id: z.number().optional(),
  method: z.string(),
  params: z.record(z.string(), z.unknown()).optional(),
});

function reply(id: number, result: unknown): void {
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, result })}\n`);
}

if (mode === "noisy") {
  process.stdout.write("starting up...\n");
  process.stdout.write("{not json\n");
}

createInterface({ input: process.stdin }).on("line", (line) => {
  const request = requestSchema.parse(JSON.parse(line));
  if (mode === "silent" || request.id === undefined) return;
  if (request.method === "initialize") {
    reply(request.id, {
      protocolVersion: "2025-03-26",
      capabilities: {},
      serverInfo: { name: "fake", version: "0" },
    });
    return;
  }
  if (request.method !== "tools/call") return;
  const name = request.params?.["name"];
  const args = request.params?.["arguments"];
  if (name === "echo") {
    reply(request.id, { content: [{ type: "text", text: `echo:${JSON.stringify(args)}` }] });
  } else if (name === "fail") {
    reply(request.id, { content: [{ type: "text", text: "❌ nope" }], isError: true });
  } else if (name === "bad") {
    reply(request.id, { content: "not an array" });
  }
});
