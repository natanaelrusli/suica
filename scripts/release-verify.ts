// Aborts unless DIR's latest.json verifies against the public key the app embeds, so a wrong
// signing key fails here and not after publishing. Usage: node scripts/release-verify.ts DIR
// SUICA_RELEASE_VERIFY_KEY (PEM text) replaces the embedded key; for tests only.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { PUBLIC_KEY_PEM } from "../src/update-key.ts";
import { verifyManifest } from "../src/update.ts";

const dir = process.argv[2];
if (!dir) {
  process.stderr.write("usage: release-verify.ts DIR\n");
  process.exit(1);
}
try {
  verifyManifest(
    readFileSync(join(dir, "latest.json"), "utf8"),
    readFileSync(join(dir, "latest.json.sig"), "utf8"),
    process.env["SUICA_RELEASE_VERIFY_KEY"] ?? PUBLIC_KEY_PEM,
  );
} catch (e) {
  process.stderr.write(
    `release does not verify against the embedded public key: ${e instanceof Error ? e.message : String(e)}\n`,
  );
  process.exit(1);
}
