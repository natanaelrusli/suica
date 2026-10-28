# OTA updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Suica.app and the suica CLI update themselves from a new GitHub Release, with one click in the app.

**Architecture:** A release script builds one signed tarball (app bundle + CLI sources + install scripts) and publishes it with `latest.json` and an ed25519 signature over that file. The TypeScript CLI owns the logic (`suica update check|apply --json`, the same JSON-contract pattern as every other app feature); it verifies, installs the CLI part with the existing `install-cli.sh`, and stages the new app. The app only shows the state, asks the CLI to apply, then runs a swap script after quitting and relaunches.

**Tech Stack:** Node 24 (`fetch`, `node:crypto` ed25519, `/usr/bin/tar`), POSIX sh, SwiftUI (SuicaCore models + decoders), `gh` for publishing. No new dependency (no Sparkle).

**Spec:** none (decisions in the plan, as P3 to P5). My calls are marked **my call**.

## Global Constraints

- Node 24 or newer; macOS 15 or newer (`LSMinimumSystemVersion`); Swift 6, `swiftLanguageModes: [.v6]`.
- Every new CLI JSON document carries `"version": 1`, a golden in `contracts/*.v1.json`, and a Swift decoder tested against that golden in the same change.
- No secret in git: the release private key lives at `~/.config/suica/release-key.pem`, only the public key is committed.
- Every outbound `fetch` has an explicit timeout (`AbortSignal.timeout`); manifest `url` must start with `https://github.com/natanaelrusli/suica/releases/download/`.
- Apps are ad hoc signed (`codesign --force --sign -`); the installed `Info.plist` must carry `SuicaCLIPath` for this machine, so the app is re-signed after that value is set.
- English in code, comments and docs. Branch `feat/no-ticket-ota-updates`, built in a sibling worktree (see memory conventions); merge locally with `--no-ff`.
- **my call:** the repo `natanaelrusli/suica` is public (no token needed) and releases are arm64 only. Both are checked in Task 2 and refused cleanly when wrong.
- **my call:** the user clicks Install; nothing is installed unattended. No opt-out config key (a check is one small GET).

## Review Focus

- Tampered tarball or manifest (wrong sha256, bad signature, `url` off github.com): nothing installed, old version keeps running. (Task 2)
- Manifest older than or equal to current version (downgrade, replay): reported up to date. (Task 2)
- No release published yet (404), offline, or GitHub rate limit: app stays silent, no error banner at launch; only a manual check shows the message. (Tasks 2, 5)
- Update triggered from the app, where PATH is the short `SuicaSearchPath`: node must still be found and baked into the new CLI wrapper. (Task 3)
- Install path with spaces, or app launched by `swift run` (no `SuicaCLIPath`): scripts quote paths; Install hidden when the client is unconfigured. (Tasks 3, 4, 5)
- Download interrupted or disk full midway: staged area removed, old CLI and app untouched. (Task 3)

---

### Task 1: One version, shown everywhere

**Files:**
- Modify: `src/cli.ts` (add `version` command and `--version`), `scripts/install-macos-app.sh` (stamp plist)
- Test: `test/version-cli.test.ts`

**Interfaces:**
- Produces: `suica --version` prints `package.json` version and exits 0; installed `Info.plist` `CFBundleShortVersionString` and `CFBundleVersion` equal it. `export const VERSION: string` in `src/version.ts` (reads `package.json` next to `src/`, so the installed copy under `$PREFIX/lib/suica` works).

- [ ] **Step 1: Failing test** `test/version-cli.test.ts`: spawn `node src/cli.ts --version`, assert stdout trimmed equals `package.json`'s `version`. Give it a 20_000 timeout (spawns the CLI).
- [ ] **Step 2: Run** `npx vitest run test/version-cli.test.ts`; expected FAIL (unknown command).
- [ ] **Step 3: Implement** `VERSION` in `src/version.ts` and the flag in `src/cli.ts`. In `install-macos-app.sh`, after the template copy, `PlistBuddy -c "Set :CFBundleShortVersionString $V"` and `:CFBundleVersion` with `V=$(node -p "require('$REPO/package.json').version")`.
- [ ] **Step 4: Run** the test again; expected PASS.
- [ ] **Step 5: Commit** `feat(update): one version from package.json`.

### Task 2: Update core: verify and compare

**Files:**
- Create: `src/update.ts`, `src/update-key.ts` (exports `PUBLIC_KEY_PEM`, filled in Task 6)
- Test: `test/update.test.ts`

**Interfaces:**
- Produces, in `src/update.ts`:
  - `interface Manifest { version: string; arch: string; url: string; sha256: string }`
  - `isNewer(latest: string, current: string): boolean` (numeric `x.y.z` compare)
  - `verifyManifest(manifestText: string, signatureB64: string, publicKeyPem: string): Manifest` throws `Error` on bad signature, bad JSON, or `url` outside the allowed prefix
  - `type CheckResult = { status: "up-to-date"; current: string } | { status: "available"; current: string; latest: string } | { status: "unavailable"; message: string }`
  - `checkForUpdate(deps: { fetch: typeof fetch; current: string; arch: string; publicKeyPem: string }): Promise<CheckResult>`; fetches `https://github.com/natanaelrusli/suica/releases/latest/download/latest.json` and `.json.sig` with `AbortSignal.timeout(15_000)`; any throw, non-200 or arch mismatch becomes `unavailable`, never an exception.

- [ ] **Step 1: Failing tests** (generate a keypair in the test with `generateKeyPairSync("ed25519")`, sign manifest text, inject a fake `fetch`): `isNewer("0.1.10","0.1.9") === true`, `isNewer("0.1.0","0.1.0") === false`, `isNewer("0.0.9","0.1.0") === false`; `verifyManifest` accepts a good pair, rejects a flipped byte in the manifest, a signature from another key, and a `url` on `https://evil.example/`; `checkForUpdate` returns `available` / `up-to-date` (equal and older) / `unavailable` for a 404, a rejected fetch, and `arch: "x64"` against an arm64 manifest.
- [ ] **Step 2: Run** `npx vitest run test/update.test.ts`; expected FAIL (module missing).
- [ ] **Step 3: Implement** as above. Use `crypto.verify(null, Buffer.from(text), publicKeyPem, Buffer.from(sig, "base64"))`.
- [ ] **Step 4: Run**; expected PASS.
- [ ] **Step 5: Commit** `feat(update): verify and compare release manifests`.

### Task 3: Apply: download, verify, install CLI, stage app

**Files:**
- Create: `scripts/finish-app.sh`, `scripts/swap-app.sh`; split `scripts/install-macos-app.sh` into `scripts/build-app.sh` (everything up to `cp` of Info.plist, taking `OUT_APP` and leaving `SuicaCLIPath` as `__CLI__`) plus a call to `finish-app.sh`
- Modify: `src/update.ts`, `scripts/install-cli.sh` (honor `SUICA_NODE` before `command -v node`)
- Test: `test/update-apply.test.ts`, `test/swap-app.test.ts`

**Interfaces:**
- Consumes: Task 2 `Manifest`, `verifyManifest`, `isNewer`.
- Produces:
  - `finish-app.sh APP CLI`: `PlistBuddy Set :SuicaCLIPath`, then `codesign --force --sign - APP`. `install-macos-app.sh` calls it too, so there is one copy of that logic.
  - `swap-app.sh PID STAGED TARGET`: waits (max 30 s) until `PID` is gone, then `rm -rf TARGET`, `mv STAGED TARGET`, `open TARGET`. If `STAGED` is missing it only does `open TARGET`.
  - `type ApplyResult = { status: "staged"; version: string; staged: string; target: string; swapScript: string } | { status: "up-to-date" } | { status: "failed"; message: string }`
  - `applyUpdate(deps: CheckDeps & { run: (cmd: string, args: string[], env?: Record<string, string>) => Promise<void>; home: string; execPath: string; cliPath: string }): Promise<ApplyResult>`. Order: check, fetch tarball (`AbortSignal.timeout(120_000)`) into a temp dir under `~/Library/Application Support/Suica/update/`, compare sha256, `tar -xzf`, run extracted `scripts/install-cli.sh` with `SUICA_NODE=execPath` and `SUICA_PREFIX` taken from `cliPath`'s grandparent, run `finish-app.sh` on the extracted app, move it to `staged/Suica.app`. Any failure removes the temp dir and returns `failed` before the CLI step; the CLI step is atomic already (`install-cli.sh` swaps last).

- [ ] **Step 1: Failing tests.** `update-apply.test.ts`: build a tiny fake tarball in a temp dir (an empty `Suica.app/Contents`, a `scripts/` with stub `install-cli.sh` and `finish-app.sh` that touch a marker) and inject `fetch` and `run`. Assert: good tarball returns `staged` and runs the stubs in that order; a tarball whose sha256 differs returns `failed` and the `install-cli.sh` stub marker does not exist; a failing `run` for `install-cli.sh` leaves no `staged/` directory; a path with a space in `home` works. `swap-app.test.ts`: spawn the script with a dead pid and fake dirs, assert TARGET now has STAGED's contents and STAGED is gone (stub `open` via a `PATH` dir containing an `open` that writes a marker).
- [ ] **Step 2: Run** both files; expected FAIL.
- [ ] **Step 3: Implement** the scripts and `applyUpdate`. Quote every path in sh. Keep `install-macos-app.sh` behavior identical (run `make install-app` once by hand and confirm the app starts).
- [ ] **Step 4: Run** both test files; expected PASS. Run `shellcheck scripts/*.sh` if installed.
- [ ] **Step 5: Commit** `feat(update): download, verify and stage a release`.

### Task 4: CLI commands and the contract

**Files:**
- Modify: `src/cli.ts`
- Create: `contracts/update.v1.json`
- Test: `test/update-cli.test.ts`

**Interfaces:**
- Consumes: `checkForUpdate`, `applyUpdate`, `VERSION`, `PUBLIC_KEY_PEM`.
- Produces: `suica update check --json` prints `{"version":1,"status":"available","current":"0.1.0","latest":"0.1.1"}` (other statuses per `CheckResult`); `suica update apply --json` prints the `ApplyResult` plus `"version":1`... **my call:** the apply document names the release `release` (not `version`) to keep `"version": 1` the contract version. Golden `contracts/update.v1.json` holds one example of each status.

- [ ] **Step 1: Failing test** that spawns `node src/cli.ts update check --json` with `SUICA_UPDATE_BASE_URL` pointing at a local `http.createServer` serving a signed manifest (**my call:** that env var overrides the releases base, and the url prefix check in Task 2 reads the same override so tests can run offline; the override is ignored unless `NODE_ENV=test`). Assert JSON equals the golden `available` example. 20_000 timeout.
- [ ] **Step 2: Run**; expected FAIL.
- [ ] **Step 3: Implement** the two subcommands, wired like the existing `lessons` subcommands; exit code 0 for every status (the app reads `status`).
- [ ] **Step 4: Run** `npx vitest run test/update-cli.test.ts` and `npm run check`; expected PASS.
- [ ] **Step 5: Commit** `feat(update): suica update check and apply`.

### Task 5: App model and decoders

**Files:**
- Create: `macos/Suica/Sources/SuicaCore/Updates.swift`
- Modify: `macos/Suica/Sources/SuicaCore/AgentClient.swift` (add `UpdatesClient`, `CLIAgentClient` conformance), `macos/Suica/Sources/Suica/SuicaApp.swift` (`UnconfiguredClient: UpdatesClient`, create `UpdatesModel`), `macos/Suica/Sources/SuicaCore/Copy.swift`
- Test: `macos/Suica/Tests/SuicaCoreTests/UpdatesTests.swift`

**Interfaces:**
- Produces:
  - `enum UpdateCheck: Decodable, Equatable { case upToDate(current: String), available(current: String, latest: String), unavailable(message: String) }` decoded from the Task 4 golden
  - `struct UpdateApplied: Decodable, Equatable { let status: String; let release: String?; let staged: String?; let target: String?; let swapScript: String?; let message: String? }`
  - `protocol UpdatesClient: Sendable { func checkUpdate() async throws(AgentError) -> UpdateCheck; func applyUpdate() async throws(AgentError) -> UpdateApplied }`
  - `@MainActor @Observable final class UpdatesModel`: `init(client: any UpdatesClient, store: UserDefaults, now: () -> Date)`; `state: idle | available(String) | installing | failed(String)`; `checkIfDue() async` (at most once per 24 h, key `updates.lastCheck`, silent on `unavailable`); `checkNow() async` (surfaces `unavailable` as `failed(message)`); `install() async` (calls apply, on `staged` runs `swapScript staged target` detached with this process's pid and then `NSApp.terminate`; the terminate and launch live in the app target behind a closure `relaunch: (UpdateApplied) -> Void` so the model tests need no AppKit).

- [ ] **Step 1: Failing tests:** decoder test per golden status; model tests with a stub client: `checkIfDue` twice within 24 h calls the client once; `unavailable` leaves `state == .idle` for `checkIfDue` but `.failed` for `checkNow`; `install` on `staged` calls `relaunch` once, on `failed` sets `.failed(message)` and does not call it.
- [ ] **Step 2: Run** `cd macos/Suica && swift test --filter UpdatesTests`; expected FAIL.
- [ ] **Step 3: Implement.** Pass `staged`, `target`, `swapScript` as separate `Process` arguments (no shell string). Copy strings in `Copy.swift` (`updateAvailable(version)`, `installing`, `checkNow`, `upToDate`).
- [ ] **Step 4: Run** `swift test`; expected PASS (all ~200 plus new).
- [ ] **Step 5: Commit** `feat(app): updates model and client`.

### Task 6: UI and the call site

**Files:**
- Modify: `macos/Suica/Sources/Suica/PanelView.swift` or the menu view that holds the footer actions, the About/Settings page that shows the version, `SuicaApp.swift` (`Task { await updates.checkIfDue() }` next to the launch tasks, after `onboardingModel.checkNeeded()`)

**Interfaces:**
- Consumes: `UpdatesModel`.
- Produces: footer item "Update to 0.1.1" (only in `.available`), a spinner while `.installing`, a "Check for updates" button and the current version on the Settings page, hidden when the client is unconfigured.

- [ ] **Step 1: Implement** the three views.
- [ ] **Step 2: Verify visually** with the scratch NSHostingView harness from the screenshot-harness memory, in states idle, available, installing, failed. Expected: each renders with no clipped text in light and dark.
- [ ] **Step 3: Commit** `feat(app): update button and settings row`.

### Task 7: Release script and key

**Files:**
- Create: `scripts/release.sh`, `scripts/release-sign.ts`, `scripts/release-keygen.ts`
- Modify: `src/update-key.ts` (real public key), `Makefile` (`release` target)
- Test: `test/release-sign.test.ts`

**Interfaces:**
- Produces: `node scripts/release-keygen.ts` writes `~/.config/suica/release-key.pem` (mode 600, refuses to overwrite) and prints the public key PEM. `node scripts/release-sign.ts TARBALL VERSION ARCH` writes `latest.json` and `latest.json.sig` next to it. `scripts/release.sh`: fails unless the worktree is clean and the tag `v$VERSION` is free; runs `build-app.sh` into a temp dir; tars `Suica.app scripts src package.json package-lock.json` to `suica-$VERSION-arm64.tar.gz`; signs; `gh release create v$VERSION` with the three files.

- [ ] **Step 1: Failing test:** run `release-sign.ts` on a small fake tarball using a temp key (path via `SUICA_RELEASE_KEY`), then `verifyManifest` from Task 2 on its output with the matching public key returns a manifest whose `sha256` matches the file and whose `url` is the release asset URL for that version.
- [ ] **Step 2: Run** `npx vitest run test/release-sign.test.ts`; expected FAIL.
- [ ] **Step 3: Implement** the three scripts; run keygen once, commit only the printed public key into `src/update-key.ts`.
- [ ] **Step 4: Run** the test; expected PASS.
- [ ] **Step 5: Commit** `feat(update): release script and signing`.

### Task 8: Docs and the real round trip

**Files:**
- Modify: `README.md` (Updating section: how a release is cut, what the app does, that the first updater-capable build is installed by hand), `CONTEXT.md` (update contract, `SUICA_NODE`), `docs/superpowers/plans/` tracker (add P11 row in tables 1 and 2, same change)

- [ ] **Step 1: Write the docs.** Include only commands run in Step 2.
- [ ] **Step 2: End to end on this machine:** `make update-app` at 0.1.0 (the manual bootstrap), bump to 0.1.1, `make release`, open the app; expected: footer shows "Update to 0.1.1"; click it; the app quits and reopens, `suica --version` and the About row both read 0.1.1, `suica agent` still running (`make status`).
- [ ] **Step 3: Negative checks:** corrupt the uploaded tarball asset (re-upload altered) and confirm the app reports a failure and still runs 0.1.0; turn Wi-Fi off and confirm launch shows nothing.
- [ ] **Step 4: Run** `make test-all`; expected PASS. Commit `docs(update): OTA updates`.

## Self-review notes

- Types line up: `Manifest`, `CheckResult`, `ApplyResult` (Task 2, 3) map to `UpdateCheck`, `UpdateApplied` (Task 5); `swapScript`, `staged`, `target` names are the same in 3 and 5.
- Chicken and egg: existing installs have no updater, so the first release needs a manual `make update-app`; stated in Task 8.
