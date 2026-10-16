# Suica — Plan 1: rename everything from MR Review Assistant to Suica

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The product is called Suica everywhere (CLI, config and state folders, environment variables, LaunchAgent, macOS app, logs, notifications, docs), and an existing installation moves over with one script without losing state.

**Architecture:** A mechanical rename with one behaviour change: the old `MRA_CONFIG` variable is refused loudly instead of silently ignored. A POSIX shell script moves the Owner's existing folders and removes the old LaunchAgent and app; a Vitest test runs it against a temporary `HOME` with stub `launchctl`, `osascript` and `pgrep`. No data format changes; the SQLite file moves as-is.

**Tech Stack:** Node 24 / TypeScript / Vitest, Swift 6.3 / SwiftPM, POSIX `sh` (existing).

**Spec:** No spec covers naming. The Owner asked on 2026-10-16 for the app to be named Suica and chose "rename everything" (config dir, state DB path, LaunchAgent label, package name, env vars, with a migration step). The name table below is the spec for this plan; Task 5 records it in `docs/superpowers/specs/2026-10-14-mr-review-assistant-design.md`. Plan 2 (`2026-10-16-suica-plan-2-app-window.md`) builds on this one.

## Name table (exact; every task uses these values)

| Thing | Old | New |
|---|---|---|
| Product name (UI, notifications, docs) | `MR Review Assistant` | `Suica` |
| CLI wrapper | `scripts/mra` | `scripts/suica` (no `mra` alias) |
| npm package name | `mr-review-assistant` | `suica` |
| Config file | `~/.config/mr-review-assistant/config.yaml` | `~/.config/suica/config.yaml` |
| Templates default | `~/.config/mr-review-assistant/templates` | `~/.config/suica/templates` |
| State DB default | `~/Library/Application Support/mr-review-assistant/state.db` | `~/Library/Application Support/suica/state.db` |
| Logs folder | `~/Library/Logs/mr-review-assistant/` | `~/Library/Logs/suica/` |
| Env vars | `MRA_CONFIG`, `MRA_ENV`, `MRA_LOG_LEVEL` | `SUICA_CONFIG`, `SUICA_ENV`, `SUICA_LOG_LEVEL` |
| Log `service_name`, MCP client name | `mr-review-assistant` | `suica` |
| LaunchAgent label / template | `com.madhani.mr-review-assistant` / `launchd/com.madhani.mr-review-assistant.plist.template` | `com.madhani.suica.agent` / `launchd/com.madhani.suica.agent.plist.template` |
| Swift package folder | `macos/MRAMenuBar` | `macos/Suica` |
| Swift targets | `MRACore`, `MRAMenuBar`, `MRACoreTests` | `SuicaCore`, `Suica`, `SuicaCoreTests` |
| App struct | `MRAMenuBarApp` | `SuicaApp` |
| Info.plist agent keys | `MRANodePath`, `MRARepoPath`, `MRASearchPath` | `SuicaNodePath`, `SuicaRepoPath`, `SuicaSearchPath` |
| Bundle id / executable / bundle | `com.madhani.mr-review-assistant.menubar` / `MRAMenuBar` / `~/Applications/MR Review Assistant.app` | `com.madhani.suica` / `Suica` / `~/Applications/Suica.app` |
| Temp folder prefixes in tests | `mra-…` | `suica-…` |

Not renamed: the Teams MCP command `~/.config/teams-mcp/run.sh` (not ours), the `contracts/agent-state.v1.json` contract (content unchanged), historical plan files under `docs/superpowers/plans/` (they record what was built under the old name), and the spec's file name (its title changes).

## Global Constraints

- Everything in the earlier plans' Global Constraints still applies: Node `>=24`, `.ts` import suffixes, erasable syntax only, no new dependencies on either side, no `print`/`try!`/force unwrap in Swift outside tests, JSON logs with no names, titles or message text.
- After this plan, `grep -rIn --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=.build --exclude-dir=plans -i "mr-review-assistant\|MR Review Assistant\|MRA_\|MRACore\|MRAMenuBar\|scripts/mra\|\bmra \|mra-"` returns only: the spec's "formerly MR Review Assistant" line, the `MRA_CONFIG` refusal in `src/config.ts` and its test, the migration script and its test, and the README's migration section.
- Branch `feat/no-ticket-suica-rename`, cut from `master` (the tip that contains the menu bar app). MR title `[no-ticket] refactor: rename the product to Suica`. If the Owner has a planner key for this work, use it instead of `no-ticket`.
- Tests never touch the Owner's real `~/.config`, `~/Library` or LaunchAgents. The real migration (Task 5, Step 4) moves the Owner's files and runs only after the Owner says yes in chat.
- Run commands: Node `npm run check`; Swift `cd macos/Suica && swift test`.

## Review Focus

1. **A leftover `MRA_CONFIG` in the Owner's shell profile or a LaunchAgent** — expected: the agent and CLI refuse to start with "MRA_CONFIG is no longer read; rename it to SUICA_CONFIG", instead of silently reading the default path. Test: `test/config.test.ts` (Task 1).
2. **Migrating while the old daemon or app is still running** (the SQLite WAL is open) — expected: the script stops the old LaunchAgent and app first and refuses to move anything while a process still matches. Test: `test/migrate.test.ts` "refuses while an old process is running" (Task 4).
3. **Running the migration twice, or with both old and new folders present** — expected: second run says "already migrated" and changes nothing; both present → refuses and names both paths. Tests: `test/migrate.test.ts` (Task 4).
4. **A config that names old paths explicitly** (`statePath` or `teams.templatesPath` under `mr-review-assistant`) — expected: the script rewrites nothing in the YAML but prints a warning naming the key. Test: `test/migrate.test.ts` "warns about explicit old paths" (Task 4).
5. **An app built before the rename still installed** — expected: the migration removes `~/Applications/MR Review Assistant.app` so two menu bar icons never run against different paths. Test: `test/migrate.test.ts` "removes the old app bundle and LaunchAgent plist" (Task 4).

## File Structure

| File | Change |
|---|---|
| `src/config.ts`, `src/log.ts`, `src/teams/templates.ts`, `src/teams/mcp.ts`, `src/format.ts`, `src/failures.ts`, `src/teams/service.ts`, `src/cli.ts`, comments in `src/agent-state.ts`, `src/teams/*.ts` | Names per table |
| `scripts/mra` → `scripts/suica`; `package.json`, `package-lock.json` (the two top-level `name` fields) | CLI and package name |
| `launchd/com.madhani.suica.agent.plist.template`, `scripts/install-launchagent.sh`, `scripts/uninstall-launchagent.sh` | LaunchAgent |
| `macos/MRAMenuBar/` → `macos/Suica/`, `macos/Info.plist.template`, `scripts/install-macos-app.sh`, `scripts/uninstall-macos-app.sh` | Swift package and app bundle |
| `scripts/migrate-to-suica.sh` (new), `test/migrate.test.ts` (new) | One-time migration |
| `README.md`, `CONTEXT.md`, spec, `.gitignore` | Docs |

---

### Task 1: Rename the Node agent

**Files:**
- Modify: `src/config.ts:107-116`, `src/log.ts:19-36`, `src/teams/templates.ts:69`, `src/teams/mcp.ts:35`, `src/format.ts:116`, `src/failures.ts:43,78`, `src/teams/service.ts:38`, `src/cli.ts:8-9`, doc comments that say `mra` in `src/agent-state.ts`, `src/teams/types.ts`, `src/teams/dispatch.ts`, `src/teams/format-outbox.ts:6`
- Rename: `scripts/mra` → `scripts/suica`; modify `package.json`, `package-lock.json`
- Test: `test/config.test.ts`, `test/log.test.ts`, `test/format.test.ts`, `test/poller.test.ts`, `test/poller-teams.test.ts`, `test/format-outbox.test.ts`, temp prefixes in `test/store*.test.ts`, `test/templates.test.ts`, `test/runtime.test.ts`

**Interfaces:**
- Produces: `defaultConfigPath(env?: NodeJS.ProcessEnv): string` (new optional parameter, defaults to `process.env`) — returns `env.SUICA_CONFIG` if set, else `~/.config/suica/config.yaml`; throws `ConfigError("MRA_CONFIG is no longer read; rename it to SUICA_CONFIG")` when `MRA_CONFIG` is set and `SUICA_CONFIG` is not. `defaultStatePath()` → `~/Library/Application Support/suica/state.db`. `defaultTemplatesPath()` → `~/.config/suica/templates`. Logger reads `SUICA_ENV`, `SUICA_LOG_LEVEL`; `service_name` `suica`. CLI usage line starts `usage: suica <`.
- Indonesian copy (exact): baseline title `Suica aktif`; state failure body `Suica tidak bisa menyimpan state. Alert bisa terulang; lihat log untuk detailnya.`; Teams failure body `Lihat log Suica untuk detailnya.`; self-test text `Suica: tes koneksi Teams berhasil.`; outbox hint `` (…: add the person to teams.people, then `suica retry 1`) ``.

- [ ] **Step 1: Branch**

```bash
git switch master
git switch -c feat/no-ticket-suica-rename
```

- [ ] **Step 2: Write the failing tests** in `test/config.test.ts`

```ts
describe("defaultConfigPath", () => {
  it("uses SUICA_CONFIG when set", () => {
    expect(defaultConfigPath({ SUICA_CONFIG: "/x/c.yaml" })).toBe("/x/c.yaml");
  });
  it("defaults to ~/.config/suica/config.yaml", () => {
    expect(defaultConfigPath({})).toBe(join(homedir(), ".config", "suica", "config.yaml"));
  });
  it("refuses a leftover MRA_CONFIG", () => {
    expect(() => defaultConfigPath({ MRA_CONFIG: "/old.yaml" })).toThrow(
      "MRA_CONFIG is no longer read; rename it to SUICA_CONFIG",
    );
  });
  it("lets SUICA_CONFIG win over a leftover MRA_CONFIG", () => {
    expect(defaultConfigPath({ MRA_CONFIG: "/old.yaml", SUICA_CONFIG: "/new.yaml" })).toBe("/new.yaml");
  });
});
```

Also update the expected strings in the tests listed under **Files** to the new copy (`Suica aktif`, `` `suica retry 1` ``, `service_name: "suica"` where the test asserts the default) and the temp prefixes to `suica-…`.

- [ ] **Step 3: Run to verify they fail**

Run: `npx vitest run test/config.test.ts test/format.test.ts`
Expected: FAIL — `defaultConfigPath` ignores its argument / old copy `MR Review Assistant aktif`.

- [ ] **Step 4: Apply the name table** to every file under **Files**; `git mv scripts/mra scripts/suica`; set `"name": "suica"` in `package.json` and both top-level `name` fields of `package-lock.json` (edit by hand; do not run `npm install`).

- [ ] **Step 5: Run the checks**

Run: `npx prettier --write . && npm run check`
Expected: all pass. Then `scripts/suica --help; echo "exit $?"` prints the usage line starting `usage: suica <` and `exit 2`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: rename the agent, CLI and paths to Suica"
```

---

### Task 2: Rename the LaunchAgent

**Files:**
- Rename: `launchd/com.madhani.mr-review-assistant.plist.template` → `launchd/com.madhani.suica.agent.plist.template`
- Modify: `scripts/install-launchagent.sh`, `scripts/uninstall-launchagent.sh`

**Interfaces:**
- Produces: LaunchAgent label `com.madhani.suica.agent`, plist `~/Library/LaunchAgents/com.madhani.suica.agent.plist`, env `SUICA_ENV=production`, logs `__HOME__/Library/Logs/suica/{stdout,stderr}.log`; the installer reads `SUICA_CONFIG` (default `~/.config/suica/config.yaml`) and creates `~/Library/Logs/suica`. Plan 2 calls `launchctl … gui/<uid>/com.madhani.suica.agent`.

- [ ] **Step 1: Apply the name table** to the three files (`git mv` the template).

- [ ] **Step 2: Verify the rendered plist without installing it**

Run: `T=launchd/com.madhani.suica.agent.plist.template; sed -e "s|__NODE__|/n|g" -e "s|__REPO__|/r|g" -e "s|__HOME__|/h|g" $T | plutil -lint - ; grep -c "suica" $T; grep -c "SUICA_ENV" $T; grep -c "mr-review-assistant\|MRA_" $T; sh -n scripts/install-launchagent.sh && sh -n scripts/uninstall-launchagent.sh`
Expected: `<stdin>: OK`, then `3` (label and the two log paths), `1`, `0`, and no syntax errors.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "refactor: rename the LaunchAgent to com.madhani.suica.agent"
```

---

### Task 3: Rename the Swift package and app bundle

**Files:**
- Rename: `macos/MRAMenuBar/` → `macos/Suica/`; `Sources/MRACore` → `Sources/SuicaCore`; `Sources/MRAMenuBar` → `Sources/Suica`; `Sources/MRAMenuBar/MRAMenuBarApp.swift` → `Sources/Suica/SuicaApp.swift`; `Tests/MRACoreTests` → `Tests/SuicaCoreTests`
- Modify: `macos/Suica/Package.swift`, `Sources/SuicaCore/AgentClient.swift` (Info.plist keys, `MRA_ENV`, the `sendTimeout` comment path), `Sources/SuicaCore/Copy.swift` (`appName = "Suica"`, `moreHidden` → `"and \(count) more (see suica pending --all)"`), every `import MRACore` → `import SuicaCore`, `macos/Info.plist.template`, `scripts/install-macos-app.sh`, `scripts/uninstall-macos-app.sh`
- Test: `Tests/SuicaCoreTests/AgentClientTests.swift`

**Interfaces:**
- Produces: `import SuicaCore`; `AgentConfig(infoDictionary:)` reads `SuicaNodePath`, `SuicaRepoPath`, `SuicaSearchPath`; the child environment is `["PATH": …, "HOME": …, "SUICA_ENV": "production"]`. The installer builds product `Suica`, installs `~/Applications/Suica.app` with `CFBundleName`/`CFBundleDisplayName` `Suica`, `CFBundleIdentifier` `com.madhani.suica`, `CFBundleExecutable` `Suica`, quits a running copy by that bundle id and waits on `pgrep -x Suica`.

- [ ] **Step 1: Update the failing expectations** in `AgentClientTests.swift`: `stateRunsTheCliWithTheExactEnvironment` expects `"SUICA_ENV": "production"`; `configFromTheBundleNeedsAllThreeKeys` uses the `Suica…` keys and still returns nil when any one is missing.

- [ ] **Step 2: Do the moves with `git mv`** and apply the name table to every file under **Files**.

- [ ] **Step 3: Run the tests**

Run: `cd macos/Suica && swift build && swift test`
Expected: build succeeds; all tests pass (the two updated ones included).

- [ ] **Step 4: Lint the shell and plist**

Run: `sh -n scripts/install-macos-app.sh && sh -n scripts/uninstall-macos-app.sh && plutil -lint macos/Info.plist.template`
Expected: no output from `sh -n`, `OK` from plutil.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: rename the macOS app to Suica"
```

---

### Task 4: Migration script

**Files:**
- Create: `scripts/migrate-to-suica.sh`
- Test: `test/migrate.test.ts`

**Interfaces:**
- Produces: `scripts/migrate-to-suica.sh` (no arguments, exit 0 on success or "already migrated", exit 1 on refusal). Steps in order:
  1. `launchctl bootout gui/$(id -u)/com.madhani.mr-review-assistant` (errors ignored), `osascript -e 'tell application id "com.madhani.mr-review-assistant.menubar" to quit'` (errors ignored).
  2. Wait up to 5 s while `pgrep -f "mr-review-assistant|MRAMenuBar"` finds a process; if one remains, print `an old process is still running (pid …): quit it and run this again` and exit 1 before moving anything.
  3. For each pair — `~/.config/mr-review-assistant` → `~/.config/suica`, `~/Library/Application Support/mr-review-assistant` → `~/Library/Application Support/suica`, `~/Library/Logs/mr-review-assistant` → `~/Library/Logs/suica` — first check all pairs: if any old and new both exist, print `both <old> and <new> exist: merge them by hand` and exit 1 having moved nothing. Then `mv` each old that exists.
  4. `rm -f ~/Library/LaunchAgents/com.madhani.mr-review-assistant.plist`; `rm -r ~/Applications/MR Review Assistant.app` if present.
  5. If the moved config contains `mr-review-assistant` on a line, print `warning: <file> still names mr-review-assistant in: <the key before the colon>` per line, unchanged.
  6. If none of the old paths existed: print `already migrated` and exit 0. Otherwise print `migrated; now run scripts/install-launchagent.sh and scripts/install-macos-app.sh`.
  If `MRA_CONFIG` is set in the environment, print `warning: MRA_CONFIG is set; rename it to SUICA_CONFIG` first.

- [ ] **Step 1: Write the failing tests** in `test/migrate.test.ts`. A helper makes a temp `HOME` and a `bin` folder with stub `launchctl`, `osascript` and `pgrep` scripts that append their arguments to `$HOME/calls.log`; `pgrep` exits 1 (nothing found) unless `$HOME/running` exists, in which case it prints `4242` and exits 0. Run the script with `spawnSync("sh", ["scripts/migrate-to-suica.sh"], { env: { HOME, PATH: \`${bin}:/usr/bin:/bin\` } })`.

```ts
it("moves config, state and logs and removes the old LaunchAgent and app", () => {
  // old ~/.config/mr-review-assistant/config.yaml, …/Application Support/mr-review-assistant/state.db and state.db-wal,
  // ~/Library/Logs/mr-review-assistant/stdout.log, ~/Library/LaunchAgents/com.madhani.mr-review-assistant.plist,
  // ~/Applications/MR Review Assistant.app/Contents/Info.plist
  // expect status 0; new paths exist with the same bytes; old paths gone; calls.log contains
  // "bootout gui/" and "com.madhani.mr-review-assistant"; stdout contains "now run scripts/install-launchagent.sh"
});
it("says already migrated and changes nothing on a second run");
it("refuses while an old process is running and moves nothing", () => { /* touch $HOME/running → status 1, stderr/stdout contains "pid 4242", old paths still there */ });
it("refuses when old and new folders both exist and moves nothing", () => { /* both ~/.config dirs → status 1, message names both paths; the state dir was not moved either */ });
it("warns about explicit old paths in the config", () => { /* config has "statePath: /Users/x/Library/Application Support/mr-review-assistant/state.db" → output contains "statePath" and the YAML is byte-identical */ });
it("warns about a leftover MRA_CONFIG");
```

- [ ] **Step 2: Run to verify they fail**

Run: `npx vitest run test/migrate.test.ts`
Expected: FAIL — `scripts/migrate-to-suica.sh` does not exist (status 127).

- [ ] **Step 3: Implement `scripts/migrate-to-suica.sh`** (`#!/bin/sh`, `set -eu`, quote every path — two of them contain spaces) to the steps above; `chmod +x`.

- [ ] **Step 4: Run the checks**

Run: `npm run check`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add the one-time migration to the Suica paths"
```

---

### Task 5: Documentation and the Owner's own migration

**Files:**
- Modify: `README.md` (every name per the table; new section "Moving from MR Review Assistant" with the three commands below), `CONTEXT.md` (heading `# Suica`, first sentence "Suica is a personal background agent …", drop "Working name; the project has no folder yet."), spec title → `# Suica (formerly MR Review Assistant) — design` plus one line under "Runtime and scope": "Renamed to Suica on 2026-10-16: paths, CLI, LaunchAgent and app follow `docs/superpowers/plans/2026-10-16-suica-plan-1-rename.md`.", `.gitignore` (the `macos/MRAMenuBar/.build` entry → `macos/Suica/.build`)

- [ ] **Step 1: Update the docs** as listed. README migration section, exact commands:

```bash
scripts/migrate-to-suica.sh
scripts/install-launchagent.sh
scripts/install-macos-app.sh
```

- [ ] **Step 2: Check no old names remain**

Run the `grep` from Global Constraints.
Expected: only the allowed hits listed there.

- [ ] **Step 3: Full checks**

Run: `npm run check && (cd macos/Suica && swift test)`
Expected: both pass.

- [ ] **Step 4: Migrate the Owner's machine — ask first.** Tell the Owner in chat that this moves `~/.config/mr-review-assistant` and `~/Library/Application Support/mr-review-assistant` and installs the renamed LaunchAgent and app, and wait for a yes. Then run the three commands from Step 1 and:

Run: `scripts/suica status && launchctl print gui/$(id -u)/com.madhani.suica.agent | grep -m1 "state ="`
Expected: the same tracked counts as before the migration, and `state = running`. The menu bar shows the Suica icon; no second icon remains.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "docs: document the Suica name and the migration"
```
