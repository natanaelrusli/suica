// Creates the release signing key. Usage: node scripts/release-keygen.ts
// Writes the private PEM to SUICA_RELEASE_KEY (default ~/.config/suica/release-key.pem, mode 0600),
// prints the public PEM to stdout. Never overwrites an existing key.
import { generateKeyPairSync } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

const path =
  process.env["SUICA_RELEASE_KEY"] ?? join(homedir(), ".config", "suica", "release-key.pem");
const { publicKey, privateKey } = generateKeyPairSync("ed25519");
mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
try {
  // flag "wx" fails if the file exists, so a key is never replaced.
  writeFileSync(path, privateKey.export({ type: "pkcs8", format: "pem" }), {
    flag: "wx",
    mode: 0o600,
  });
} catch (e) {
  process.stderr.write(`not writing ${path}: ${e instanceof Error ? e.message : String(e)}` + "\n");
  process.exit(1);
}
process.stdout.write(publicKey.export({ type: "spki", format: "pem" }).toString().trimEnd() + "\n");
process.stderr.write(
  `Private key written to ${path}. Paste the public key above into src/update-key.ts.` + "\n",
);
