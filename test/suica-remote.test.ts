import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it } from "vitest";

const SCRIPT = join(import.meta.dirname, "..", "scripts", "suica-remote");

function run(args: string[], env: Record<string, string>) {
  const dir = mkdtempSync(join(tmpdir(), "suica-remote-"));
  // A stand-in for ssh: records its arguments, one per line, and runs the last one locally.
  const ssh = join(dir, "ssh");
  writeFileSync(
    ssh,
    `#!/bin/sh\nprintf '%s\\n' "$@" > "${dir}/argv"\nfor last; do :; done\nexec sh -c "$last"\n`,
  );
  chmodSync(ssh, 0o755);
  const r = spawnSync("bash", [SCRIPT, ...args], {
    env: {
      PATH: "/usr/bin:/bin",
      HOME: dir,
      SUICA_REMOTE_SSH: ssh,
      ...env,
    },
    encoding: "utf8",
  });
  return { ...r, argvFile: join(dir, "argv"), dir };
}

it("fails with a hint when no host is configured", () => {
  const r = run(["status"], {});
  expect(r.status).toBe(2);
  expect(r.stderr).toContain("SUICA_REMOTE_HOST");
});

it("quotes arguments for the remote shell and passes the key and port", () => {
  const r = run(["a b", "it's", "$HOME"], {
    SUICA_REMOTE_HOST: "me@vps",
    SUICA_REMOTE_KEY: "/k/id",
    SUICA_REMOTE_PORT: "2222",
    SUICA_REMOTE_BIN: "printf '[%s]'",
  });
  expect(r.status).toBe(0);
  expect(r.stdout).toBe("[a b][it's][$HOME]");
  const argv = spawnSync("cat", [r.argvFile], { encoding: "utf8" }).stdout.split("\n");
  expect(argv).toContain("BatchMode=yes");
  expect(argv).toContain("/k/id");
  expect(argv).toContain("2222");
  expect(argv).toContain("me@vps");
});

it("reads the host from the config file", () => {
  const conf = join(mkdtempSync(join(tmpdir(), "suica-remote-conf-")), "env");
  writeFileSync(conf, "SUICA_REMOTE_HOST=cfg@vps\n");
  const r = run(["x"], { SUICA_REMOTE_CONFIG: conf, SUICA_REMOTE_BIN: "true" });
  expect(r.status).toBe(0);
  expect(readFileSync(r.argvFile, "utf8").split("\n")).toContain("cfg@vps");
});
