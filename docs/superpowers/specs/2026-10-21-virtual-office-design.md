# Virtual Office — design

Status: written from the Owner's request on 2026-10-21 ("Have a 3d virtual office in the app … I want it to visualize all running agent in this mac"). Choices marked _my call_ are the builder's and can be changed. Vocabulary is in `CONTEXT.md`.

## Intent

The Owner runs several coding agents at once (Claude Code, Codex, Gemini CLI) across several projects and wants to see, at a glance, **what each one is doing right now**. The Office shows them as a small 3D office: each project is a **Room**, each running agent session sits at its own **Desk** in the Room of the project it works in, and a bubble above it says what it is doing ("Editing OfficeView.swift", "Running npm test").

## Goals

- An **Office** page in the Suica window, beside Messages and Review requests.
- A 3D scene rendered with **RealityKit** (`RealityView`) inside the existing SwiftUI app. Decided with the Owner; it raises the app's minimum macOS from 14 to 15.
- One Room per project folder with at least one running agent; one Desk per running agent session.
- Each Desk shows the agent type (by colour), its current activity, and its status: working, waiting for the Owner, or idle.
- Clicking an agent shows a detail card: agent type, project, status, the last few actions.
- Claude Code, Codex and Gemini CLI supported at first; more agent types can be added through config (see Detection).

## Non-goals

- Controlling agents. The Office only watches: no sending messages, stopping, approving or answering (decided with the Owner).
- History or statistics of past sessions.
- Agents on other machines or in the cloud.
- Realistic art. The first version is low-poly geometry built in code (boxes, capsules, text); no USDZ assets (_my call_).

## Anti-goals

- Anything leaving the Mac. Detection reads local files only, read-only.
- Showing prompt or message text beyond a short activity line. The bubble names the action and its target (tool + file or command), not the conversation (_my call_: the window may be on screen while sharing).
- A heavy render loop: when the page is not visible, the scene and detection polling stop.

## Vocabulary (add to `CONTEXT.md`)

- **Coding Agent**: a coding assistant process running on the Owner's Mac (Claude Code, Codex, Gemini CLI, …). Not Suica's own background agent, and not an Agent Review. _Avoid_: agent (alone), bot.
- **Session**: one running conversation of a Coding Agent, in one folder.
- **Room**: a project folder that has at least one live Session.
- **Desk**: one Session's place in its Room.

## Architecture

Follows the app's existing pattern: Suica.app runs the installed `suica` CLI and decodes its JSON.

- **CLI**: a new `suica office --json` command that prints a snapshot of live Sessions. A new contract `contracts/office.v1.json` (golden) with a matching Swift decoder in `SuicaCore`.
- **Detection lives in the CLI** (`src/office/`), one adapter per Coding Agent type, each implementing: list live Sessions → `{ agent, sessionId, cwd, status, activity, recentActions[], updatedAt, pid? }`.
- **App**: `OfficeModel` (in `SuicaCore`, testable) polls the CLI every 2 s while the page is visible (_my call_, same cadence as Logs), diffs snapshots by `sessionId`, and drives the scene. The `RealityView` lives in the `Suica` target.

### Room identity

A Session's Room is its working folder, normalised to the git repository root when the folder is inside one (so a Session in `suica/macos/Suica` sits in the `suica` Room). Git worktrees of a repo (`../suica-<topic>`, `.claude/worktrees/*`) join the main repo's Room (_my call_: they are the same project to the Owner). The Room's label is the folder name.

### Detection per agent (what exists on this Mac today)

- **Claude Code**: `~/.claude/sessions/<pid>.json` lists each running process with `sessionId`, `cwd`, `status` (`busy` / idle) and `updatedAt`. Liveness: the pid is alive. Activity: the last `tool_use` in the transcript `~/.claude/projects/<slug>/<sessionId>.jsonl`, read from the file's tail. This file format was seen on 2026-10-21 (Claude Code 2.1.304) but is undocumented; other files in that folder may carry fewer fields. Fallback when the fields are missing (_my call_): list `claude` processes, take each one's cwd (`lsof -a -d cwd -p <pid>`), pick the most recently written transcript in that cwd's `~/.claude/projects/<slug>/`, and derive busy or idle from its last entry.
- **Codex**: rollout files `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`; the first line (`session_meta`) has `cwd` and `session_id`; later `event_msg` lines carry tool calls and `task_complete`. Liveness: a `codex` process whose cwd matches, or a file written in the last few minutes (the builder confirms which is reliable; Codex also runs a long-lived `app-server-daemon` that must not count as a Session).
- **Gemini CLI**: `~/.gemini/projects.json` maps folders to project names; chats live in `~/.gemini/tmp/<project>/chats/session-*.jsonl`. Liveness: a `gemini` process with that cwd, or recent writes. Its format is the least known; the builder inspects it first and may ship Gemini after the other two if it needs more work.
- **Waiting for the Owner**: shown when the agent's log says it is waiting for permission or input (Claude Code's idle/notify status, Codex approval requests). Where an agent exposes no such signal, its Session shows working or idle only.
- **Idle**: a live Session with no activity in the last 60 s (_my call_). A Session whose process has exited stays at its Desk, greyed, for 5 minutes, then leaves (_my call_).
- **More agents via config**: an `office.agents` list in `config.yaml` enables or disables the built-in adapters. A generic adapter takes a process name and a JSONL log glob with a cwd field and an activity field (the builder defines its exact keys); unknown keys are rejected as elsewhere in the config.

### Scene

- Rooms laid out in a row or grid, each a floor and two low walls with the project name; Room size grows with its Desk count.
- A Desk: a desk, a monitor, a figure coloured by agent type (Claude Code coral, Codex teal, Gemini purple, generic grey; _my call_), and a floating text bubble with the current activity, trimmed to ~32 characters.
- Status: working figures bob slightly or the monitor glows; waiting shows an amber "Waiting for you" bubble; idle figures turn grey.
- Arrivals and departures animate (desk appears, figure walks in or fades) (_my call_, kept short and respecting Reduce Motion).
- Camera: fixed isometric-style angle that fits all Rooms; the Owner can orbit and zoom; a reset button returns to the default view.
- Click a figure → a detail card overlaid on the page (agent type, project path, status, last 5 actions, started at). An **Open** button brings the agent's app forward (Claude app, Terminal, Codex) where that can be found; otherwise it is left out (_my call_).
- Empty state: an empty office with "No coding agents running".
- Light and dark appearance follow the app's `Theme`.

## Mockup

The mockup shown to the Owner in the session of 2026-10-21: three Rooms (`suica`, `kinsen`, `cli-probe`), figures coloured by agent type with activity bubbles, and a detail card under the scene listing recent actions. The Owner agreed it fits; it is a direction, not a pixel spec.

## Tests

- CLI: one fixture-based test per adapter (sample session files → expected Sessions), Room normalisation (subfolder, worktree), idle and exited timing, config validation; the `office.v1.json` golden.
- App: `OfficeModel` decoding the golden, diffing snapshots (arrive, update, leave), Room grouping and layout positions. The RealityKit view itself is checked by eye with the screenshot harness.

## Left to the builder

- Exact layout math, geometry, animation and colours within the above.
- Whether detection reads file tails each poll or keeps offsets between polls.
- Where in the sidebar the Office item sits and its shortcut.
