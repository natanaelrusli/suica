# Virtual Office Implementation Plan

Spec: `docs/superpowers/specs/2026-10-21-virtual-office-design.md` (the binding authority; "my call" marks are the builder's).

**Goal:** an Office page in the Suica window that shows every running Coding Agent on the Mac as a figure at a Desk, in a Room per project, in a RealityKit scene, fed by `suica office --json`.

**Global constraints**

- Detection is read-only and local: files under `~/.claude`, `~/.codex`, `~/.gemini`, plus `ps`/`lsof`. Nothing leaves the Mac.
- The bubble carries tool + target only (file name, command), never prompt or message text.
- Node: TypeScript run with `node src/cli.ts`, strict, zod at the config boundary, tests in vitest, `npx eslint src test`, `npx prettier --check`. Swift: `cd macos/Suica && swift test`.
- Every JSON the CLI prints has a `contracts/*.v1.json` golden and a Swift decoder; the golden is decoded in a Swift test and produced by a TS test.
- The README, `CONTEXT.md` and config table ship in the same change.
- Branch `feat/no-ticket-virtual-office`; commit with `git -C <worktree>`.

**Interfaces** (what later tasks consume)

- Task 1 produces `src/office/types.ts`: `OfficeSession` (`agent, sessionId, cwd, room, status, activity, recentActions, startedAt, updatedAt, pid, hostApp`), `OfficeJson` (`version: 1, generatedAt, sessions[]`), `Probe` (`home, now, pidAlive(pid), processes(): ProcInfo[]`), `ProcInfo` (`pid, ppid, name, cwd`), `Adapter` = `(probe: Probe) => RawSession[]`; `roomFor(cwd)`, `describeTool(name, input)`, `readTail(path, bytes)`, `classify(...)`.
- Tasks 2-4 each export one `Adapter`; task 6 consumes them with the config from task 5 (`config.office.agents: string[]`, `config.office.custom: string[]`).
- Task 6 produces the golden `contracts/office.v1.json`; task 7 decodes it (`OfficeDocument`, `OfficeSession` in Swift) and builds `OfficeModel`; task 8 consumes `OfficeModel`.

**Review focus:** liveness (a dead pid must not draw a Desk; the Codex `app-server` daemon must not count), a transcript tail that begins mid-line, huge transcript lines, a session whose cwd was deleted, and that no prompt text reaches `activity`.

---

### Task 1: Office core: types, rooms, tool descriptions, tail reader, status

Files: `src/office/types.ts`, `src/office/room.ts`, `src/office/describe.ts`, `src/office/tail.ts`, `src/office/status.ts`, `test/office-core.test.ts`.

- [ ] Step 1: write failing tests: `roomFor` (plain folder, subfolder of a repo, `.git` file of a worktree pointing at `<main>/.git/worktrees/x`, no git, deleted folder); `describeTool` (Edit → `Editing OfficeView.swift`, Bash → `Running npm test`, Grep, unknown tool, no prompt text); `readTail` (drops a partial first line, handles a file smaller than the window, skips lines over the limit); `classify` (waiting wins, fresh → working, stale → idle after 60 s).
  Run `npx vitest run test/office-core.test.ts`. Expected: FAIL, modules missing.
- [ ] Step 2: implement the five modules.
- [ ] Step 3: run the same command. Expected: all pass.
- [ ] Step 4: commit `feat(office): core types, room normalisation and tool descriptions` (with the spec and this plan).

### Task 2: Claude Code adapter

Files: `src/office/claude.ts`, `test/office-claude.test.ts`.

- [ ] Step 1: failing tests with a fixture home: `sessions/<pid>.json` (busy, idle, dead pid fresh → exited, dead pid old → dropped, a file without `cwd`/`sessionId` → fallback via process list and newest transcript), transcript tail with tool_use entries → activity and 5 recent actions, a transcript whose last line is huge.
  Expected: FAIL.
- [ ] Step 2: implement `claudeAdapter`.
- [ ] Step 3: Expected: pass.
- [ ] Step 4: commit.

### Task 3: Codex adapter

Files: `src/office/codex.ts`, `test/office-codex.test.ts`.

- [ ] Step 1: failing tests: rollout with `session_meta`, a function_call, `task_complete` → idle; approval request last → waiting; `codex app-server` process is not a Session; a rollout with no process but written 1 minute ago is live; written 10 minutes ago is not.
- [ ] Step 2-4: implement `codexAdapter`, pass, commit.

### Task 4: Gemini and generic adapters

Files: `src/office/gemini.ts`, `src/office/generic.ts`, `test/office-gemini.test.ts`, `test/office-generic.test.ts`.

- [ ] Step 1: failing tests: Gemini folder↔project mapping, chat with tool calls → activity, recent write or process → live; generic adapter parses `name|process|glob|cwdKey|activityKey`, finds cwd and activity by dotted key in a JSONL file, ignores a malformed entry.
- [ ] Step 2-4: implement, pass, commit.

### Task 5: `office` config

Files: `src/config.ts`, `src/config-fields.ts`, `test/config*.test.ts`, `contracts/config.v1.json`, `README.md` table, Swift config golden test counts if they change.

- [ ] Step 1: failing tests: `office.agents` defaults to `claude, codex, gemini` and rejects unknown names; `office.custom` defaults to `[]` and rejects a malformed entry naming it; unknown keys rejected; `CONFIG_FIELDS` covers both.
- [ ] Step 2: implement; update golden and README table.
- [ ] Step 3: `npx vitest run test/config*.test.ts` and `cd macos/Suica && swift test --filter Contract`. Expected: pass.
- [ ] Step 4: commit.

### Task 6: `suica office --json`

Files: `src/office/collect.ts`, `src/office/probe.ts`, `src/cli.ts`, `contracts/office.v1.json`, `test/office-collect.test.ts`, `test/office-cli.test.ts`.

- [ ] Step 1: failing tests: `collectOffice` runs only enabled adapters, normalises rooms, sorts, resolves `hostApp` from the parent chain, survives an adapter that throws (the others still show); the CLI prints the document and the golden equals a built one.
- [ ] Step 2: implement the real `Probe` (`ps`, `lsof`, `process.kill(pid, 0)`), the command, the usage line.
- [ ] Step 3: `npx vitest run test/office-*.test.ts`; then run `node src/cli.ts office --json` on this Mac. Expected: valid JSON with this machine's live Claude Sessions.
- [ ] Step 4: commit.

### Task 7: Swift core: decoder, client, OfficeModel

Files: `macos/Suica/Sources/SuicaCore/Office.swift`, `AgentClient.swift` (+ `DashboardClient` fake in tests), `macos/Suica/Tests/SuicaCoreTests/OfficeTests.swift`, `DashboardContractTests.swift`.

- [ ] Step 1: failing tests: decode the golden; `OfficeModel` diff (arrive, update, leave with a 5-minute greyed stay), Room grouping, layout positions (rooms in a grid, desks inside a room, size grows with count), `trimmed` bubble text to ~32 characters, unknown status decodes as idle.
- [ ] Step 2: implement.
- [ ] Step 3: `cd macos/Suica && swift test`. Expected: pass.
- [ ] Step 4: commit.

### Task 8: Swift app: Office page and RealityKit scene

Files: `macos/Suica/Package.swift` (macOS 15), `Navigation.swift`, `Copy.swift`, `MainWindow.swift`, `Window/OfficeView.swift`, `Window/OfficeScene.swift`.

- [ ] Step 1: add the section (`WindowSection.office`, symbol, tint, shortcut ⌘9, Copy strings) and the page; polling every 2 s only while visible; empty state; detail card; reset-camera button; orbit and zoom; Reduce Motion.
- [ ] Step 2: `swift build` and `swift test`. Expected: pass.
- [ ] Step 3: render with the screenshot harness (scratch package) against `suica office --json` of this Mac, plus a synthetic three-room document, and look at the PNGs.
- [ ] Step 4: commit.

### Task 9: Docs

Files: `CONTEXT.md`, `README.md`.

- [ ] Step 1: add the four terms to `CONTEXT.md`; add an Office section and the `office` command to the README.
- [ ] Step 2: `npx prettier --check .`, `npx eslint src test`, `npx tsc --noEmit`, `npx vitest run`. Expected: clean.
- [ ] Step 3: commit.
