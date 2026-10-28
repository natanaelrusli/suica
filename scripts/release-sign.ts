// Writes latest.json and latest.json.sig next to TARBALL. Usage: node scripts/release-sign.ts TARBALL VERSION ARCH
// The key is read from SUICA_RELEASE_KEY (default ~/.config/suica/release-key.pem).
import { createHash, sign } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";

const [tarball, version, arch] = process.argv.slice(2);
if (!tarball || !version || !arch) {
  process.stderr.write("usage: release-sign.ts TARBALL VERSION ARCH" + "\n");
  process.exit(1);
}
const keyPath =
  process.env["SUICA_RELEASE_KEY"] ?? join(homedir(), ".config", "suica", "release-key.pem");
const bytes = readFileSync(tarball);
const manifest = JSON.stringify({
  version,
  arch,
  url: `https://github.com/natanaelrusli/suica/releases/download/v${version}/${basename(tarball)}`,
  sha256: createHash("sha256").update(bytes).digest("hex"),
});
const dir = dirname(tarball);
writeFileSync(join(dir, "latest.json"), manifest);
writeFileSync(
  join(dir, "latest.json.sig"),
  sign(null, Buffer.from(manifest), readFileSync(keyPath)).toString("base64"),
);
