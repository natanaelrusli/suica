# MR Review Assistant — Native macOS menu bar app Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS menu bar app, in English, that shows what the agent is doing and lets the Owner send, skip or retry held Teams messages, and pause or resume polling, without typing `mra` commands.

**Architecture:** The Node agent stays the only brain. It gains a machine-readable surface (`mra state` prints one JSON document, and `mra send|skip|retry <id> --json` print one status line). A small Swift app (SwiftPM, SwiftUI `MenuBarExtra`, no third-party packages) runs those commands as child processes, decodes the JSON and renders it. A golden JSON file in `contracts/` is checked by both a Vitest test and a Swift test, so the two sides cannot drift apart. The app never touches SQLite, GitLab or Teams itself, so every safety rule from Plans 1 and 2 (at-most-once, working hours, obsolete checks) stays in one place.

**Tech Stack:** Node 24 / TypeScript / Vitest (existing); Swift 6.3, SwiftUI, macOS 14+, Swift Testing (ships with the toolchain), `swift build` plus a shell script that assembles the `.app` bundle. No Xcode project file.

**Spec:** There is no UI section in `docs/superpowers/specs/2026-10-14-mr-review-assistant-design.md`; the Owner asked for a native app after Plan 2 was merged. The decisions below stand in for it, and Task 6 adds one line to the spec. Vocabulary: `CONTEXT.md`. Builds on Plans 1 and 2 (merged on branch `feat/no-ticket-polling-foundation`).

## Design decisions (made here; change them before execution if you disagree)

- **A menu bar app, not a Dock app.** An icon with a count of messages that need the Owner; click it for a popover with the list.
- **The app shells out to the existing CLI** instead of reading SQLite or talking to Teams. One implementation of "send" exists; the app cannot bypass it.
- **Scope:** status line, the outbox (what needs the Owner first, then the 20 most recent), and Send (with a confirmation), Skip, Retry, Pause polling, Resume polling, Refresh, Quit. No settings window, no config editing, no launch-at-login switch (macOS Login Items does that).
- **English everywhere in the app.** The Teams messages sent to colleagues and the macOS alert notifications from the agent stay Indonesian; they are not part of the app.
- **Paths are baked in at install time**, like the LaunchAgent does: the install script writes the absolute `node` path and the repo path into the app's `Info.plist`.

## Global Constraints

- Everything in Plans 1 and 2's Global Constraints applies to the Node changes (Node `>=24`, `.ts` import suffixes, erasable syntax only, Madhani TypeScript standard, no `console.log` outside the CLI's own stdout writes, JSON logs with **no names, titles or message text**, `no-ticket` branches). The new JSON goes to stdout only and is never logged.
- Node side: **no new dependencies**. Swift side: **no third-party SwiftPM dependencies**; `swift-tools-version: 6.0`, language mode 6 (strict concurrency), `.macOS(.v14)`.
- Swift code: no `print`, no `try!`, no force unwrap or `as!` outside tests; child processes are started with `Process.executableURL` and an argument array, never through a shell; every child process has a timeout and is terminated when it expires.
- The child process environment is set explicitly: `PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin` (the same as the LaunchAgent), `HOME`, `MRA_ENV=production`. A GUI app does not inherit the shell's `PATH`.
- Text that other people wrote (MR titles, names, message text) is shown through `DisplayText.clean(_:max:)` (control characters and newlines become spaces, runs of spaces collapse, cut at 200 characters with `…`), and links open only if `DisplayText.safeURL` accepts them (`http` or `https`).
- Branch `feat/no-ticket-macos-menubar`, cut from the tip of `feat/no-ticket-polling-foundation`. MR title `[no-ticket] feat: native macOS menu bar app for held Teams messages`.
- Tests never send a real Teams message. The smoke test sends nothing without the Owner's explicit confirmation in chat.
- Run commands: Node `npm run check`; Swift `cd macos/MRAMenuBar && swift test`.

## Review Focus

1. **Contract drift** — the Node JSON and the Swift decoder disagree after one side changes (a renamed field, a new status, `version` bumped). Tests: `test/agent-state.test.ts`, `ContractTests.swift`, both reading `contracts/agent-state.v1.json`.
2. **Hostile text from other people** — MR titles and names with newlines, control characters, 5 000 characters or a `javascript:` URL. Tests: `DisplayTextTests.swift`.
3. **The same message sent from two places** — a double click, the app plus `mra send`, the app plus the daemon. The second attempt must show "busy" or "no longer waiting", never produce a second message. Tests: `MenuModelTests.swift` (in-flight guard) and the existing CAS tests of Plan 2.
4. **The agent is unreachable or broken** — `node` missing, repo moved, non-zero exit, empty or garbage stdout, a hung child. The app must stay responsive, keep the last good state visible and show a plain error. Tests: `AgentClientTests.swift`, `ProcessRunnerTests.swift`, `MenuModelTests.swift`.
5. **Launching as a GUI app** — no shell `PATH`, working directory `/`, paths with spaces. Tests: `AgentClientTests.swift` (exact environment and working directory), manual smoke in Task 6.
6. **Stale lists** — a row was sent or skipped elsewhere since the last refresh. Acting on it must give a clear message and a refresh, not a crash or a retry. Tests: `MenuModelTests.swift`.

## File Structure

| File | Responsibility |
|---|---|
| `src/agent-state.ts` | Pure: `buildAgentState`, `actionJson`; the JSON contract types |
| `contracts/agent-state.v1.json` | Golden example of the contract, read by both test suites |
| `src/cli.ts` (modify) | `mra state`, `--json` for `send`, `skip`, `retry` |
| `macos/MRAMenuBar/Package.swift` | Package with `MRACore` (library), `MRAMenuBar` (app), `MRACoreTests` |
| `Sources/MRACore/Models.swift` | Codable contract types, `ItemState`, `ItemAction`, `decodeAgentState` |
| `Sources/MRACore/DisplayText.swift` | `clean`, `safeURL` |
| `Sources/MRACore/Copy.swift` | Every English string the app shows |
| `Sources/MRACore/AgentClient.swift` | `CommandRunning`, `ProcessRunner`, `AgentClient`, `CLIAgentClient`, errors |
| `Sources/MRACore/MenuModel.swift` | Observable view model: refresh loop, actions, confirmation, banners |
| `Sources/MRAMenuBar/` | SwiftUI app entry and views (not unit-tested) |
| `macos/Info.plist.template`, `scripts/install-macos-app.sh`, `scripts/uninstall-macos-app.sh` | Build, bundle, ad-hoc sign, install, remove |
| `README.md`, spec (modify) | Document the app |

---

### Task 1: The JSON contract on the Node side

**Files:**
- Create: `src/agent-state.ts`, `contracts/agent-state.v1.json`
- Test: `test/agent-state.test.ts`

**Interfaces:**
- Consumes: `OutboxRow`, `OutboxStatus`, `OUTBOX_STATUSES`, `ATTENTION_STATUSES` from `src/teams/types.ts`.
- Produces: `AgentItemJson { id; kind; status; detail; recipientName; mrKey; mrTitle; mrUrl; text: string | null; createdAt; updatedAt }` (numbers are epoch milliseconds); `AgentStateJson { version: 1; paused; baselineDone; trackedAuthored; reviewRequested; teams: null | { counts: Record<OutboxStatus, number>; attentionHidden: number; attention: AgentItemJson[]; recent: AgentItemJson[] } }`; `buildAgentState(input: { paused: boolean; baselineDone: boolean; trackedAuthored: number; reviewRequested: number; rows: readonly OutboxRow[] | undefined }): AgentStateJson` (`rows` is `undefined` when Teams is disabled, giving `teams: null`); `actionJson(status: string): string` → `{"status":"<status>"}` plus no newline.

Rules: `attention` = rows whose status is in `ATTENTION_STATUSES` or is `queued`, oldest first, at most 100, with `attentionHidden` the number cut; `recent` = the 20 newest of the other rows, newest first; `counts` has every status key, zero included; `variant` is not exposed.

- [ ] **Step 1: Branch**

```bash
cd ~/project/suica
git switch feat/no-ticket-polling-foundation
git switch -c feat/no-ticket-macos-menubar
```

- [ ] **Step 2: Create `contracts/agent-state.v1.json`** exactly:

```json
{
  "version": 1,
  "paused": false,
  "baselineDone": true,
  "trackedAuthored": 4,
  "reviewRequested": 5,
  "teams": {
    "counts": { "queued": 0, "pending": 1, "sending": 0, "sent": 1, "skipped": 0, "failed": 0, "unresolved": 0, "dry-run": 0 },
    "attentionHidden": 0,
    "attention": [
      {
        "id": 2, "kind": "nudge", "status": "pending", "detail": "",
        "recipientName": "Bob", "mrKey": "g/p!5", "mrTitle": "Add thing",
        "mrUrl": "https://gitlab.example/g/p/-/merge_requests/5",
        "text": "Halo Bob", "createdAt": 1000, "updatedAt": 2000
      }
    ],
    "recent": [
      {
        "id": 1, "kind": "nudge", "status": "sent", "detail": "",
        "recipientName": "Bob", "mrKey": "g/p!5", "mrTitle": "Add thing",
        "mrUrl": "https://gitlab.example/g/p/-/merge_requests/5",
        "text": "Halo Bob", "createdAt": 500, "updatedAt": 600
      }
    ]
  }
}
```

- [ ] **Step 3: Write the failing tests** in `test/agent-state.test.ts` (rows come from a small `row(overrides)` helper over `OutboxRow`)

```ts
it("matches the golden contract file", () => {
  // rows: id 2 pending (created 1000, updated 2000) and id 1 sent (created 500, updated 600), both nudge → Bob, g/p!5, "Add thing", text "Halo Bob"
  // expect(buildAgentState({ paused: false, baselineDone: true, trackedAuthored: 4, reviewRequested: 5, rows })).toEqual(JSON.parse(readFileSync("contracts/agent-state.v1.json", "utf8")))
});
it("reports teams as null when Teams is disabled");
it("puts pending, unresolved, failed, sending and queued rows in attention, oldest first");
it("keeps the 20 newest finished rows in recent, newest first, and counts every status including zeros");
it("cuts attention at 100 and reports how many were hidden", () => { /* 150 pending → 100 shown, attentionHidden 50 */ });
it("passes awkward text through unchanged", () => { /* title with newline, quotes, emoji, 5000 chars → identical in the JSON; the app decides how to show it */ });
it("actionJson produces one line of JSON", () => { expect(actionJson("sent")).toBe('{"status":"sent"}'); });
```

- [ ] **Step 4: Run to verify they fail**

Run: `npx vitest run test/agent-state.test.ts`
Expected: FAIL — cannot resolve `../src/agent-state.ts`.

- [ ] **Step 5: Implement `src/agent-state.ts`** to the interfaces and rules above.

- [ ] **Step 6: Run the checks**

Run: `npx prettier --write . && npm run check`
Expected: all pass. (If prettier reformats the golden file, that is fine; the test compares parsed JSON.)

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: define the agent state JSON contract"
```

---

### Task 2: `mra state` and `--json` actions

**Files:**
- Modify: `src/cli.ts`
- Test: none for `cli.ts` (it only wires tested parts, as in Plan 2); Step 3 checks it against the real state.

**Interfaces:**
- Consumes: `buildAgentState`, `actionJson` (Task 1); `Runtime` (`store`, `teams`).
- Produces: CLI `mra state` (always JSON on stdout, exit 0; `teams` is `null` when disabled); `mra send <id> --json`, `mra skip <id> --json`, `mra retry <id> --json` print `actionJson(code)` instead of the text line and keep their exit codes. Codes: `send` → the outcome's `status` (`sent`, `busy`, `obsolete`, `unresolved`, `failed`, `retry-later`, `lookup-error`, `not-pending`, `not-found`); `skip` → `skipped` or `nothing`; `retry` → `retried` or `nothing`. `pause` and `resume` stay as they are (the app checks their exit code). The usage line gains `state`.

- [ ] **Step 1: Wire the commands in `src/cli.ts`:** `state` is handled with the other Teams-independent commands (`teams.list(true)` when Teams is enabled, `trackedAuthored.size`, `myReviewStates.size`, `isPaused()`, `baselineDone` from the store); `--json` is detected with `argv.includes("--json")` for the id commands.

- [ ] **Step 2: Run the checks**

Run: `npx prettier --write . && npm run check`
Expected: all pass.

- [ ] **Step 3: Check against the real state (read-only)**

```bash
scripts/mra state | node -e 'const s=JSON.parse(require("fs").readFileSync(0,"utf8")); console.log(JSON.stringify({version:s.version,teams:s.teams===null?null:Object.keys(s.teams)}))'
scripts/mra send 999999 --json; echo "exit $?"
```

Expected: first line `{"version":1,"teams":["counts","attentionHidden","attention","recent"]}` (or `"teams":null` if Teams is off); second `{"status":"not-found"}` and `exit 1`.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: add mra state and --json results for the menu bar app"
```

---

### Task 3: Swift package, models and display text

**Files:**
- Create: `macos/MRAMenuBar/Package.swift`, `Sources/MRACore/Models.swift`, `Sources/MRACore/DisplayText.swift`, `Sources/MRACore/Copy.swift`, a one-line `Sources/MRAMenuBar/main.swift` placeholder, `Tests/MRACoreTests/ContractTests.swift`, `Tests/MRACoreTests/DisplayTextTests.swift`

**Interfaces:**
- Produces (`import MRACore`, all `public`, `Sendable`):
  - `struct OutboxItem: Codable, Equatable, Identifiable` with `id: Int`, `kind: String`, `status: String`, `detail: String`, `recipientName: String`, `mrKey: String`, `mrTitle: String`, `mrUrl: String`, `text: String?`, `createdAt: Int`, `updatedAt: Int`; computed `state: ItemState` and `actions: [ItemAction]`.
  - `enum ItemState: Equatable { case queued, pending, sending, sent, skipped, failed, unresolved, dryRun, unknown }` (an unrecognised status string is `.unknown`, never a decode failure).
  - `enum ItemAction: Equatable { case send, skip, retry }`; `actions` per state: `pending` → `[.send, .skip]`, `unresolved` → `[.retry, .skip]`, `queued` → `[.skip]`, everything else `[]`.
  - `struct TeamsSection: Codable, Equatable` (`counts: [String: Int]`, `attentionHidden: Int`, `attention: [OutboxItem]`, `recent: [OutboxItem]`); `struct AgentState: Codable, Equatable` (`version`, `paused`, `baselineDone`, `trackedAuthored`, `reviewRequested`, `teams: TeamsSection?`).
  - `enum AgentError: Error, Equatable { case launchFailed, timedOut, failed(exitCode: Int32), badOutput, unsupportedVersion(Int) }`.
  - `func decodeAgentState(_ data: Data) throws(AgentError) -> AgentState` — `badOutput` for invalid JSON, `unsupportedVersion(n)` when `version != 1` (the version is read before the rest is decoded, so a future contract fails with this error and not a field error).
  - `enum DisplayText { static func clean(_ text: String, max: Int = 200) -> String; static func safeURL(_ text: String) -> URL? }`.
  - `enum Copy` with the strings in the table below; `static func flash(for code: String) -> String`.

Copy (`Copy.swift`, exact):

| Name | English text |
|---|---|
| `appName` | `MR Review Assistant` |
| `running` / `paused` | `Polling` / `Paused` |
| `tracked(n)` | `n of your MRs are tracked` |
| `waitingForYou(n)` | `n MRs are waiting for your review` |
| `attentionHeading` / `recentHeading` | `Needs your attention` / `Recent` |
| `attentionEmpty` | `Nothing is waiting for you.` |
| `moreHidden(n)` | `and n more (see mra pending --all)` |
| `teamsDisabled` | `Teams is off. Set teams.enabled to true in the config.` |
| `send` / `skip` / `retry` | `Send…` / `Skip` / `Retry` |
| `pause` / `resume` / `refresh` / `quit` | `Pause polling` / `Resume polling` / `Refresh` / `Quit` |
| `confirmTitle(name)` | `Send this message to name?` |
| `confirmSend` / `confirmCancel` | `Send` / `Cancel` |
| `kindLabel` | `nudge` → `Nudge`, `reminder` → `Reminder`, `notice` → `Review notice`, other → the raw value |
| `maybeSent` / `notRetried` / `needsPeople` | `May have been delivered: check Teams` / `Not retried automatically` / `Add this person to teams.people, then Retry` |
| `agentUnreachable` | `Can't reach the agent. Check that the repository and Node still exist, then Refresh.` |
| `agentTimedOut` | `The agent took too long to answer.` |
| `agentOutdated` | `The agent speaks a newer protocol. Rebuild the app.` |

`flash(for:)`: `sent` "Message sent." · `busy` "Another process is already sending this message." · `obsolete` "Skipped: the message is no longer needed." · `unresolved` "Couldn't find this person in Teams. Add them to teams.people, then Retry." · `failed` "Sending failed and will not be retried automatically." · `retry-later` "Teams is unreachable. The message is still waiting." · `lookup-error` "The Teams lookup failed. Add this person to teams.people." · `not-pending` "This message is no longer waiting for approval." · `not-found` "Message not found." · `skipped` "Message skipped." · `retried` "Message queued again." · `nothing` "Nothing to do." · any other code → "Done."

- [ ] **Step 1: Create the package** (`Package.swift`: tools 6.0, `.macOS(.v14)`, library `MRACore`, executable target `MRAMenuBar` depending on it, test target `MRACoreTests` depending on `MRACore`, no external dependencies) and the placeholder `main.swift`, then run `cd macos/MRAMenuBar && swift build`. Expected: builds with no warnings.

- [ ] **Step 2: Write the failing tests** (Swift Testing, `import Testing`, `@testable import MRACore`)

```swift
// ContractTests.swift — the golden file is read through #filePath: ../../../../contracts/agent-state.v1.json
@Test func decodesTheGoldenContract() throws {
    let state = try decodeAgentState(goldenData())
    #expect(state.version == 1 && state.trackedAuthored == 4 && state.reviewRequested == 5)
    #expect(state.teams?.attention.first?.id == 2)
    #expect(state.teams?.attention.first?.state == .pending)
    #expect(state.teams?.attention.first?.actions == [.send, .skip])
    #expect(state.teams?.recent.first?.state == .sent)
}
@Test func decodesTeamsDisabledAsNil()                      // "teams": null
@Test func rejectsANewerVersionBeforeLookingAtFields()      // {"version":2,"unknown":true} → .unsupportedVersion(2)
@Test func rejectsGarbage()                                 // "not json", "" → .badOutput
@Test func treatsAnUnknownStatusAsUnknownWithNoActions()
@Test(arguments: [("pending", [ItemAction.send, .skip]), ("unresolved", [.retry, .skip]), ("queued", [.skip]),
                  ("sent", []), ("failed", []), ("sending", []), ("skipped", []), ("dry-run", [])])
func actionsFollowTheStatus(status: String, expected: [ItemAction])

// DisplayTextTests.swift
@Test func collapsesNewlinesTabsAndControlCharacters()      // "a\n\tb\u{0007}c" → "a b c"
@Test func cutsLongTextWithAnEllipsis()                     // 5000 × "x" → 200 characters ending in "…"
@Test func keepsEmojiAndAccentsIntact()
@Test func trimsOuterWhitespace()
@Test func acceptsOnlyHttpAndHttpsLinks()                   // https ok; javascript:, file:, data:, "" and "not a url" → nil
@Test func flashTextCoversEveryCodeTheAgentCanSend()        // every code in the Task 2 list has non-default text; "zzz" → "Done."
```

- [ ] **Step 3: Run to verify they fail**

Run: `cd macos/MRAMenuBar && swift test`
Expected: FAIL — the tests do not compile because `decodeAgentState`, `DisplayText` and `Copy` do not exist.

- [ ] **Step 4: Implement `Models.swift`, `DisplayText.swift`, `Copy.swift`** to the signatures above. `clean` works on `Character`s so emoji and combining marks are not split; `safeURL` uses `URL(string:)` and checks the scheme case-insensitively.

- [ ] **Step 5: Run the tests**

Run: `cd macos/MRAMenuBar && swift test`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: add the Swift package with the contract models and display text"
```

---

### Task 4: The agent client

**Files:**
- Create: `Sources/MRACore/AgentClient.swift`
- Test: `Tests/MRACoreTests/AgentClientTests.swift`, `Tests/MRACoreTests/ProcessRunnerTests.swift`

**Interfaces:**
- Consumes: `AgentState`, `AgentError`, `decodeAgentState` (Task 3).
- Produces (all `public`, `Sendable`):
  - `struct Invocation: Equatable { executable: String; arguments: [String]; environment: [String: String]; workingDirectory: String; timeout: TimeInterval }`; `struct CommandResult: Equatable { exitCode: Int32; stdout: Data; stderr: Data }`.
  - `protocol CommandRunning { func run(_ invocation: Invocation) async throws(AgentError) -> CommandResult }`; `struct ProcessRunner: CommandRunning` (Foundation `Process`: reads stdout and stderr concurrently so a full pipe cannot block, caps captured output at 4 MiB each, terminates the child when `timeout` expires and throws `.timedOut`, throws `.launchFailed` when it cannot start).
  - `struct AgentConfig: Equatable { nodePath: String; repoPath: String; searchPath: String }` with `static func fromBundle(_ bundle: Bundle) -> AgentConfig?` reading the `Info.plist` keys `MRANodePath`, `MRARepoPath`, `MRASearchPath` (nil if any is missing or empty).
  - `struct ActionResult: Equatable { let code: String }`.
  - `protocol AgentClient { func state() async throws(AgentError) -> AgentState; func send(id: Int) async throws(AgentError) -> ActionResult; func skip(id: Int) ...; func retry(id: Int) ...; func setPaused(_ paused: Bool) async throws(AgentError) }`; `struct CLIAgentClient: AgentClient` with `init(config: AgentConfig, runner: CommandRunning)`.

Behaviour: every call runs `<nodePath> <repoPath>/src/cli.ts <args>` with `workingDirectory = repoPath` and environment `PATH = searchPath`, `HOME` (from `ProcessInfo`), `MRA_ENV = production`. Arguments: `state`; `send <id> --json`; `skip <id> --json`; `retry <id> --json`; `pause`; `resume`. Timeouts: `state`, `skip`, `retry`, `pause`, `resume` 20 s; `send` 150 s (Teams start 30 s plus call 60 s, with headroom). `state`: exit code must be 0 (else `.failed(exitCode:)`), stdout decoded with `decodeAgentState`. `send`/`skip`/`retry`: the CLI exits 1 for "nothing happened" outcomes, so the exit code is ignored when stdout holds `{"status": <string>}` (returned as `ActionResult`); otherwise `.failed(exitCode:)` (or `.badOutput` when the exit code is 0). `pause`/`resume`: exit code 0 or `.failed`.

- [ ] **Step 1: Write the failing tests**

```swift
// AgentClientTests.swift — a FakeRunner records Invocations and returns scripted CommandResults
@Test func stateRunsTheCliWithTheExactEnvironment()   // executable == nodePath, arguments == [repo + "/src/cli.ts", "state"], workingDirectory == repo, env PATH == searchPath, MRA_ENV == "production", timeout 20
@Test func pathsWithSpacesAreOneArgument()            // repo "/Users/a b/My Repo" → arguments[0] == "/Users/a b/My Repo/src/cli.ts"
@Test func sendUsesTheJsonFlagAndALongTimeout()       // arguments tail == ["send", "7", "--json"], timeout 150
@Test func aNonZeroExitWithAStatusIsAnOutcomeNotAnError()   // exit 1, stdout {"status":"busy"} → ActionResult(code: "busy")
@Test func skipAndRetryReturnTheirCodes()
@Test func aNonZeroExitWithoutJsonFails()             // exit 3, empty stdout → .failed(exitCode: 3)
@Test func exitZeroWithGarbageIsBadOutput()           // send/skip/retry
@Test func stateFailsOnNonZeroExit()                  // .failed(exitCode: 2)
@Test func stateRejectsGarbageAndNewerVersions()
@Test func pauseAndResumeUseTheirCommands()
@Test func configFromBundleNeedsAllThreeKeys()        // missing or empty key → nil

// ProcessRunnerTests.swift — real processes, no node needed
@Test func capturesStdoutStderrAndExitCode()          // /bin/sh -c 'echo out; echo err >&2; exit 3'
@Test func killsAHungChildAtTheTimeout()              // /bin/sleep 30 with timeout 0.5 → .timedOut after < 3 s
@Test func reportsALaunchFailureForAMissingExecutable()
@Test func doesNotDeadlockOnLargeOutput()             // /bin/sh -c 'head -c 3000000 /dev/zero' → returns, stdout.count == 3000000
@Test func passesTheEnvironmentAndWorkingDirectory()  // /usr/bin/env and /bin/pwd with workingDirectory "/tmp"
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd macos/MRAMenuBar && swift test`
Expected: FAIL — `CLIAgentClient`, `ProcessRunner` and `AgentConfig` do not exist.

- [ ] **Step 3: Implement `AgentClient.swift`** to the behaviour above. In `ProcessRunner`, run the wait on a background task so the caller's actor is never blocked, and make termination idempotent.

- [ ] **Step 4: Run the tests**

Run: `cd macos/MRAMenuBar && swift test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add the agent client that runs the mra CLI as a child process"
```

---

### Task 5: The view model

**Files:**
- Create: `Sources/MRACore/MenuModel.swift`
- Test: `Tests/MRACoreTests/MenuModelTests.swift`

**Interfaces:**
- Consumes: `AgentClient`, `AgentState`, `OutboxItem`, `AgentError`, `Copy` (Tasks 3–4).
- Produces: `@MainActor @Observable public final class MenuModel` with
  - `init(client: any AgentClient)`;
  - read-only state: `state: AgentState?` (the last good state, kept when a refresh fails), `errorText: String?` (from `AgentError`: `.timedOut` → `Copy.agentTimedOut`, `.unsupportedVersion` → `Copy.agentOutdated`, anything else → `Copy.agentUnreachable`; cleared by the next successful refresh), `banner: String?` (the last action's `Copy.flash`), `busyIds: Set<Int>`, `confirmation: OutboxItem?`, `isPaused: Bool` (from `state`, false when unknown), `badgeCount: Int` (attention items whose state is `.pending` or `.unresolved`);
  - `func refresh() async`; `func runRefreshLoop(every interval: Duration) async` (refreshes, sleeps, repeats until the task is cancelled);
  - `func requestSend(_ item: OutboxItem)` (sets `confirmation` only for an item whose `actions` contain `.send` and that is not busy), `func cancelConfirmation()`, `func confirmSend() async` (acts on `confirmation`, then clears it);
  - `func skip(_ item: OutboxItem) async`, `func retry(_ item: OutboxItem) async`, `func togglePause() async`.

Behaviour: an action for an id already in `busyIds` does nothing (the client is not called again); `busyIds` gains the id for the duration of the call and loses it after, also on error; after every action the model calls `refresh()` and sets `banner` to `Copy.flash(for: code)`; when an action throws, `banner` is `Copy.agentUnreachable` (or the timed-out text) and `state` is untouched; `togglePause` calls `setPaused(!isPaused)` then refreshes.

- [ ] **Step 1: Write the failing tests** (a `FakeClient` actor with scripted results and call counters)

```swift
@Test func refreshStoresTheStateAndClearsAnEarlierError()
@Test func aFailedRefreshKeepsTheLastGoodStateAndShowsAPlainError()   // timedOut / unsupportedVersion / failed map to the three texts
@Test func badgeCountsPendingAndUnresolvedOnly()
@Test func sendNeedsAConfirmationAndOnlyForSendableItems()            // a sent or skipped item never becomes `confirmation`
@Test func cancellingTheConfirmationSendsNothing()
@Test func confirmSendCallsTheClientOnceThenRefreshesAndShowsTheOutcome()   // banner == Copy.flash(for: "sent"), state refreshed
@Test func aSecondSendOfTheSameIdWhileInFlightIsIgnored()             // suspended fake send; second confirm → client.sendCalls == 1
@Test func busyIdsAreClearedAfterAFailure()
@Test func aStaleRowGivesAnExplanationAndARefresh()                   // client returns "not-pending" → banner text, refresh called
@Test func skipRetryAndPauseCallTheClientAndRefresh()
@Test func theRefreshLoopRefreshesRepeatedlyAndStopsOnCancel()        // interval .milliseconds(10)
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd macos/MRAMenuBar && swift test`
Expected: FAIL — `MenuModel` does not exist.

- [ ] **Step 3: Implement `MenuModel.swift`** to the behaviour above.

- [ ] **Step 4: Run the tests**

Run: `cd macos/MRAMenuBar && swift test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add the menu bar view model with confirmation and in-flight guards"
```

---

### Task 6: The app, packaging, documentation and smoke test

**Files:**
- Create: `Sources/MRAMenuBar/MRAMenuBarApp.swift`, `Sources/MRAMenuBar/MenuView.swift`, `Sources/MRAMenuBar/ItemRow.swift` (replace the placeholder `main.swift`), `macos/Info.plist.template`, `scripts/install-macos-app.sh`, `scripts/uninstall-macos-app.sh`
- Modify: `README.md`, `docs/superpowers/specs/2026-10-14-mr-review-assistant-design.md` (one line), `.gitignore` (`macos/MRAMenuBar/.build/`)

**Interfaces:**
- Consumes: `MenuModel`, `CLIAgentClient`, `ProcessRunner`, `AgentConfig.fromBundle`, `Copy`, `DisplayText` (Tasks 3–5).
- Produces: the app `MR Review Assistant.app` (bundle id `com.madhani.mr-review-assistant.menubar`, `LSUIElement` true, minimum macOS 14).

UI rules (the views have no unit tests; Step 4 checks them by eye): the app is a SwiftUI `MenuBarExtra` with `.menuBarExtraStyle(.window)`; the label is an SF Symbol (`tray.full`) plus the `badgeCount` when it is above zero; the model is created once at launch from `AgentConfig.fromBundle(.main)` (when that is nil the popover shows only `Copy.agentUnreachable`) and `runRefreshLoop(every: .seconds(30))` runs for the life of the app, plus one refresh each time the popover opens. The popover is about 380 pt wide and shows, top to bottom: the status line (`Copy.running`/`Copy.paused`, `Copy.tracked`, `Copy.waitingForYou`), the error text in a red-tinted banner when `errorText` is set, the action `banner`, the "Needs your attention" list (`Copy.attentionEmpty` when empty, `Copy.moreHidden` when `attentionHidden > 0`), a collapsed "Recent" `DisclosureGroup`, `Copy.teamsDisabled` when `state.teams` is nil, and a footer with Pause/Resume, Refresh and Quit. Each row shows the kind label, `DisplayText.clean` of the recipient name and of the MR key as a link (`DisplayText.safeURL`; plain text when it returns nil), the status, the `maybeSent`/`notRetried`/`needsPeople` hint for the matching state, and for a `pending` item its cleaned text (up to 4 lines); its buttons are the item's `actions` (disabled while its id is in `busyIds`, with a `ProgressView` in place of the label). **Send…** calls `requestSend`; the model's `confirmation` presents a `confirmationDialog` titled `Copy.confirmTitle(name)` that shows the message text and has `Copy.confirmSend` and `Copy.confirmCancel`.

- [ ] **Step 1: Write the views and the app entry** to the rules above, then run `cd macos/MRAMenuBar && swift build -c release`. Expected: builds with no warnings; `swift test` still passes.

- [ ] **Step 2: Write `macos/Info.plist.template`** (`CFBundleName` and `CFBundleDisplayName` `MR Review Assistant`, `CFBundleIdentifier`, `CFBundleExecutable` `MRAMenuBar`, `CFBundlePackageType` `APPL`, `LSMinimumSystemVersion` `14.0`, `LSUIElement` true, and the three string keys `MRANodePath` = `__NODE__`, `MRARepoPath` = `__REPO__`, `MRASearchPath` = `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`) and `scripts/install-macos-app.sh` (POSIX `sh`, `set -eu`, same style as `install-launchagent.sh`): refuses when `command -v node` or `command -v swift` is missing; runs `swift build -c release` in `macos/MRAMenuBar`; assembles `$HOME/Applications/MR Review Assistant.app/Contents/{MacOS,Info.plist}` (quit a running copy first with `osascript -e 'tell application id "com.madhani.mr-review-assistant.menubar" to quit'`, ignoring failure); fills the template with the absolute `node` and repo paths; ad-hoc signs with `codesign --force --sign - <app>`; starts it with `open`. `scripts/uninstall-macos-app.sh` quits the app and removes the bundle.

- [ ] **Step 3: Document.** `README.md`: a "Menu bar app" section (what it shows, `scripts/install-macos-app.sh`, `scripts/uninstall-macos-app.sh`, add it under System Settings → General → Login Items to start at login, `cd macos/MRAMenuBar && swift test` for its tests); under "Known limits": the app shows what the agent last recorded and refreshes every 30 seconds; the paths baked in at install time make a moved repository or a changed Node version need a re-run of the install script; it needs the background agent (or `mra once`) to have polled for the list to be current. Spec: append "A native macOS menu bar app was added after Plan 2." to item 2 of "Delivery in three plans".

- [ ] **Step 4: Run the checks and the smoke test**

Run: `npx prettier --write . && npm run check && (cd macos/MRAMenuBar && swift test)`
Expected: both suites pass.

Smoke test (changes nothing unless you click Send):

```bash
scripts/install-macos-app.sh
pgrep -x MRAMenuBar
```

Expected: `installed …` and one process id. A tray icon appears in the menu bar. Click it: the popover shows the status line with the real counts, the three `[dry-run]` rows under "Recent", and "Nothing is waiting for you." (or your held messages). Click **Pause polling**: the status line says `Paused` and `scripts/mra status` prints `paused: yes`; click **Resume polling** to undo it. Move the repository folder aside temporarily, click **Refresh**: the red banner shows `Can't reach the agent…` while the last list stays visible; move it back and Refresh clears the banner. Do not click **Send…** on a real message without the Owner's explicit confirmation in chat; the confirmation dialog itself is safe to open and cancel.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add the native macOS menu bar app, its installer and documentation"
```

---

## Self-review

- **Coverage:** every design decision has a task: the JSON surface (1, 2), the Swift models and English copy (3), the child-process client with explicit environment and timeouts (4), the confirmation, in-flight and stale-row behaviour (5), the app, packaging and docs (6). English app text is `Copy.swift`; Teams messages and notifications are untouched.
- **Types:** `AgentState`/`OutboxItem` field names in Task 3 equal the keys of the golden JSON written in Task 1; the codes the CLI prints in Task 2 are the ones `Copy.flash` maps in Task 3 and the ones `MenuModel` forwards in Task 5; `AgentConfig` keys in Task 4 equal the `Info.plist` keys in Task 6.
- **Proportion:** bodies are left to the implementer; the plan pins names, signatures, strings, rules and the assertions that matter.
