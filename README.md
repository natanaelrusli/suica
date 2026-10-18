# Suica

A personal background agent for macOS that polls GitLab on `repo.madhani.one` and shows a notification when someone requests your review (flow A) and when someone reviews or comments on your own merge requests (flow D). Vocabulary: [CONTEXT.md](CONTEXT.md). Design: [spec](docs/superpowers/specs/2026-10-14-mr-review-assistant-design.md). Plan 1 (alerts), Plan 2 (Teams chats) and Agent Review (see below) are implemented.

It only reads from GitLab. It never posts, approves or changes anything there. With Teams enabled it also chats colleagues as you, from fixed templates.

It comes as two apps, each installed on its own from this repository:

- **The `suica` CLI** (`src/`): the commands and the background agent that polls GitLab. `scripts/install-cli.sh` installs it under `~/.local`, so it keeps working when the checkout moves or changes; `suica agent install` starts the background agent.
- **Suica.app** (`macos/`): the menu bar app and its window. It runs the installed `suica` command for everything, so install the CLI first.

## Requirements

- Node 24 (see `.nvmrc`), for the CLI
- Swift (Xcode or the Command Line Tools), to build the app
- [`glab`](https://gitlab.com/gitlab-org/cli) logged in to `repo.madhani.one` (`glab auth status`)
- Optional: `terminal-notifier` (`brew install terminal-notifier`) so that clicking a notification opens the MR. Without it the agent falls back to `osascript` and the notification is not clickable.

## Setup

```bash
scripts/install-cli.sh               # installs ~/.local/lib/suica and the command ~/.local/bin/suica
mkdir -p ~/.config/suica
printf 'gitlab:\n  hostname: repo.madhani.one\n' > ~/.config/suica/config.yaml
suica agent install                  # starts the background agent (see Run in the background)
scripts/install-macos-app.sh         # optional: the menu bar app (see Menu bar app)
```

`scripts/install-cli.sh` copies `src/` with `package.json` and `package-lock.json`, installs the production dependencies with `npm ci --omit=dev --ignore-scripts`, and writes `~/.local/bin/suica`, a two-line wrapper with the absolute path of the `node` it found (Node 24 or newer). Set `SUICA_PREFIX` to install somewhere other than `~/.local`, and put `<prefix>/bin` on your `PATH` (the script tells you when it is not). Re-run it to update from the checkout, and after switching Node versions. When a LaunchAgent is already installed, the script runs `suica agent install` again so the agent uses the new copy right away. `scripts/uninstall-cli.sh` stops and removes the agent and the installed CLI; the config, state database and logs stay.

Config file: `~/.config/suica/config.yaml` (override the path with `SUICA_CONFIG`). Unknown keys are rejected so typos fail loudly.

| Key                                | Default                          | Meaning                                                          |
| ---------------------------------- | -------------------------------- | ---------------------------------------------------------------- |
| `gitlab.hostname`                  | required                         | GitLab host passed to `glab --hostname`                          |
| `gitlab.glabPath`                  | `glab`                           | `glab` executable                                                |
| `gitlab.timeoutSeconds`            | `60`                             | Timeout for one `glab` call                                      |
| `polling.activeSeconds`            | `120`                            | Poll interval while you are at the Mac                           |
| `polling.idleSeconds`              | `300`                            | Poll interval while idle                                         |
| `polling.idleAfterSeconds`         | `300`                            | No keyboard or mouse input for this long counts as idle          |
| `polling.maxBackoffSeconds`        | `900`                            | Cap for the exponential backoff after failed polls               |
| `notifications.summaryThreshold`   | `4`                              | More notifications than this in one poll become one summary      |
| `notifications.ignoreAuthors`      | `[]`                             | GitLab usernames whose comments never alert (for example bots)   |
| `teams.enabled`                    | `false`                          | Switch the Teams flows on (see Teams below)                      |
| `teams.command`                    | `~/.config/teams-mcp/run.sh`     | Command that starts the Teams MCP server                         |
| `teams.startTimeoutSeconds`        | `30`                             | Timeout for the Teams MCP to start                               |
| `teams.callTimeoutSeconds`         | `60`                             | Timeout for one Teams MCP call                                   |
| `teams.modes.nudge`, `teams.modes.notice` | `approval`                | `auto`, `approval` or `dry-run`, per flow                        |
| `teams.workingHours.start`, `.end` | `09:00`, `17:00`                 | Messages only go out inside these hours (Mac local time)         |
| `teams.workingHours.days`          | `[1, 2, 3, 4, 5]`                | ISO weekdays, Monday is 1 and Sunday is 7                        |
| `teams.reminderAfterHours`         | `24`                             | Reminder if the Reviewer is still `UNREVIEWED` this long after the nudge |
| `teams.noticeDebounceMinutes`      | `10`                             | Review Notice after this long without further change by you      |
| `teams.maxMessagesPerReviewer`     | `2`                              | At most this many messages per MR per Reviewer                   |
| `teams.templatesPath`              | `~/.config/suica/templates` | Folder with template files                              |
| `teams.people`                     | `{}`                             | GitLab username → email, for people Teams cannot find by name    |
| `model.cli`                        | `auto`                           | Coding agent CLI for language model work: `auto` (the first installed of `claude`, `codex`, `gemini`), `claude`, `codex` or `gemini` |
| `review.auto`                      | `true`                           | Review every MR waiting for you that the agent has not reviewed yet, oldest first, and again after a new Review Request (see Agent Review below) |
| `review.post`                      | `approval`                       | `approval`: a ready review waits until you post it; `auto`: it is posted to GitLab as you as soon as it is ready |
| `review.skill`                     | `madhani:madhani-code-review`    | Claude Code skill the review follows, as typed after the slash   |
| `review.model`                     | CLI default                      | Model the review runs with: `sonnet`, `opus`, `haiku` or a full model name for Claude Code (`--model`), a model name for Codex (`-m`) |
| `review.maxChangedLines`           | `800`                            | Larger MRs are skipped                                           |
| `review.maxPerDay`                 | `10`                             | At most this many automatic reviews in 24 hours (yours do not count) |
| `review.timeoutMinutes`            | `20`                             | A review run is stopped after this long                          |
| `statePath`                        | `~/Library/Application Support/suica/state.db` | SQLite state file |

In `gitlab.glabPath`, `teams.command`, `teams.templatesPath` and `statePath` a leading `~` or `~/` stands for your home folder: it is expanded when the config is loaded, and the file keeps the text as you wrote it. `~user` and a `~` later in the path are taken literally.

The first poll on a fresh state database records a baseline silently and shows one summary ("N MR menunggu review-mu"). History never alerts.

## Commands

```bash
suica once      # one poll now
suica status    # paused / baseline / tracked counts
suica pause     # stop polling (kill switch)
suica resume
```

The app window (below) runs these commands. They print one JSON document on stdout, can be used from a script, and (except `stats` and `usage`) work even when the config file is broken:

```bash
suica status --json         # agent service, last poll, paused, intervals, paths, installed model CLIs; a broken config shows up as configError
suica stats                 # history statistics: last 14 days per day, turnaround over 30 days
suica usage                 # language model tokens: last 24 h, 7 and 30 days, by purpose, last 14 days per day
suica config show --json    # every config key with the value in the file, the effective value, and the problems found
suica config set --json     # applies edits read from stdin (see below)
suica agent restart --json  # launchctl kickstart -k of the background agent
suica reviews --json        # you, and the open MRs where you are a Reviewer (asks GitLab through glab)
suica mr <key> --json       # one MR by key (group/project!12): description, reviewers, pipeline, squash, discussions, diff
suica mr approve <key> <sha> --json  # approve the MR as you, only if its head commit is still <sha>
suica review queue <key> --json    # queue an Agent Review of that MR; the background agent runs it after its next poll
suica review post <id> --json      # post a ready review to GitLab as one comment, as you
suica review discard <id> --json   # drop a ready, failed or skipped review
```

`reviews` and `mr` read GitLab directly, not the state database, so they need a working config and `glab` login. `mr` fetches at most 100 discussions and 100 changed files, and leaves out a file's diff when GitLab marks it too large, when it is over 200,000 characters, or once 1.5 million characters of diff have been included (`diff` is then `null`). `mr approve` prints `{"status": …}`: `approved`, `head-changed` (the source branch moved past `<sha>`, so nothing was approved), `bad-request` (malformed key or commit) or `failed`.

`config set --json` reads at most 1 MiB from stdin:

```json
{ "baseSha256": "<sha256 from config show, or null if the file does not exist>",
  "edits": [{ "path": ["polling", "activeSeconds"], "value": 90 }] }
```

A `value` of `null` removes the key, so the agent's default applies. It prints `{"status": …, "issues": [{"path": …, "message": …}], "sha256": …}` and exits 0 only for `saved`. The other statuses write nothing: `invalid` (the edited config would not load, or Teams is on and the templates folder does not load; `issues` names the keys), `conflict` (the file changed since `baseSha256` was read) and `bad-request` (not a valid request: not JSON, not the shape above, larger than 1 MiB, or it names a key that does not exist). A save is atomic and the file is written with mode `0600`. `agent restart --json` prints `{"status": …}` with `restarted`, `not-installed` or `failed` and exits 0 only for `restarted`.

## Agent Review

The agent can review a merge request with a coding agent CLI following a Claude Code skill (`review.skill`, by default `madhani:madhani-code-review`), and the review waits in the app until you post it.

- **Start**: with `review.auto` (on by default), every poll queues each MR waiting for you (not a draft, your state still not reviewed) that the agent has never reviewed, oldest first, and an MR that asks for your review again; at most `review.maxPerDay` a day. A failed, skipped or discarded review is not retried on its own. **Review with agent** on an MR in the window (or `suica review queue <key> --json`) queues one by hand. The background agent starts the oldest queued review after its next poll, one at a time, beside the poll loop; nothing runs while polling is paused.
- **Run**: the agent reads the MR and its diff from GitLab, skips drafts and MRs over `review.maxChangedLines`, clones the source branch shallowly with `glab repo clone` into a temporary folder (deleted afterwards), and skips a commit that already has a ready or posted review. The CLI from `model.cli` then reviews, with `review.model` when set, `mr.diff` (GitLab's diff against the target branch) with the checkout for context. **Claude Code** runs the skill natively (`/madhani:madhani-code-review`), with only the Read, Grep, Glob and Skill tools, everything else refused (`--permission-mode dontAsk`) and no MCP servers (`--strict-mcp-config`), so it cannot run commands, reach the network or message anyone. **Codex** runs in its read-only sandbox without MCP servers and gets the skill's `SKILL.md` and `references/*.md` pasted into the prompt; the other skills it points to are not available to it. **Gemini CLI** is not supported for reviews: the run fails with a message saying so. The prompt marks everything from the MR as untrusted and asks for the skill's normal mode, never `--brutal`, with the scope stated as code reading only. Tokens are recorded under **Token usage**. A notification (in Indonesian, like the others) says when a review is ready, skipped or failed.
- **Post**: with `review.post: approval` (the default), open the MR in **Review requests → Agent review**, read it, then **Post to GitLab…** (asks first) or **Discard**. With `review.post: auto` the review is posted the moment it is ready, and the notification says it was posted (or that posting failed, in which case it waits in the app like an approval-mode review). It is posted as one MR comment, as you, starting with a line saying an agent wrote it. Before posting, lines starting with `/` are escaped so GitLab does not run them as quick actions, and @mentions and links outside code are removed. The agent never approves or requests changes. A post that fails goes back to ready with a note to check GitLab first, since the comment may have arrived.
- **What it is doing**: Overview has an **Agent Review** card with the MR being reviewed now (title, CLI, model, for how long), the next ones in the queue, whether automatic reviews are on, and two pickers that save one key each and apply after **Restart agent**: **Posting** (wait for me, or post automatically, which asks to confirm first) and **Model** (CLI default, or `opus`, `sonnet`, `haiku` when Claude Code reviews; other names go in Configuration); the menu bar popover shows the same "Reviewing …" line while a review runs. `suica status --json` and `suica state` carry it as `agentReview`. Each review records the model that wrote it, as the CLI reported it.
- Reviews are kept for 90 days. A run cut off by a restart is marked failed when the agent starts again.

## Teams

Teams is off until `teams.enabled: true`. Messages are chats from you, written from fixed Indonesian templates, sent as plain text and never by a language model.

- **Reviewer Nudge** to a Reviewer who is added to, or re-requested on, one of your non-draft MRs; one reminder if they are still `UNREVIEWED` 24 hours later; never to someone who already reviewed.
- **Review Notice** to the Author of an MR you reviewed (approved, requested changes or comments only), 10 minutes after you stopped changing your review.

A message that is no longer needed (the Reviewer has reviewed, the MR is gone) is skipped, also while it waits for your approval; `suica send` refuses it with `obsolete`. A reminder is due 24 hours after the nudge was actually delivered, never before.

Each flow has a send mode: `approval` (default; the message waits for you), `auto` (sent when due) or `dry-run` (rendered and recorded, never sent). Messages only go out in working hours (Mac local time) and wait in the queue otherwise.

```bash
suica pending [--all]   # list messages that need you (all statuses with --all)
suica send <id>         # send a pending message
suica skip <id>         # drop a message
suica retry <id>        # look the person up again after fixing teams.people
suica selftest          # send one test line to your own Teams notes chat
suica state             # the agent's state as one JSON document (used by the menu bar app)
```

Statuses in `suica pending`: `pending` waits for you; `unresolved` needs a `teams.people` line (then `suica retry`), or Teams returned an error for that person's lookup; `failed` is final; `sending` may have been delivered, so check Teams before deciding.

Templates are files in the templates folder: `nudge.txt`, `reminder.txt`, `notice.approved.txt`, `notice.changes.txt`, `notice.comments.txt`. Placeholders: `{{mr.title}}`, `{{mr.url}}`, `{{mr.iid}}`, `{{mr.project}}`, `{{person.name}}`, `{{owner.name}}`. An unknown placeholder stops startup instead of sending a broken message.

People are found through `teams.people`, then a cache, then an exact display-name match in Teams; anything uncertain is left for you.

## Moving from MR Review Assistant

Suica used to be called MR Review Assistant. If you ran it under the old name, run these three commands from the checkout, in this order:

```bash
scripts/migrate-to-suica.sh
scripts/install-cli.sh
suica agent install
scripts/install-macos-app.sh
```

`scripts/migrate-to-suica.sh` is a one-time move and is safe to run twice (a second run prints `already migrated` and changes nothing). It:

- stops the old LaunchAgent (`com.madhani.mr-review-assistant`) and quits the old menu bar app;
- refuses, before moving anything, if an old agent or app process is still running, if the old LaunchAgent is still loaded, or if any process (for example an agent started by hand with `npm start`) holds the old state database open;
- refuses, naming both paths, if an old folder and its new counterpart both exist (merge them by hand);
- moves `~/.config/mr-review-assistant` to `~/.config/suica`, `~/Library/Application Support/mr-review-assistant` to `~/Library/Application Support/suica`, and `~/Library/Logs/mr-review-assistant` to `~/Library/Logs/suica`, so the state database moves as it is;
- removes the old LaunchAgent plist and `~/Applications/MR Review Assistant.app`, so two menu bar icons never run against different paths;
- warns, without editing the file, for every line of the moved config that still names `mr-review-assistant` (for example an explicit `statePath` or `teams.templatesPath`; change those by hand);
- when it warns about such a line, ends by telling you to fix those keys first and only then run the install steps (an explicit old `statePath` would make the new agent recreate the old folder with a fresh database);
- warns if `MRA_CONFIG` is set. The agent and CLI no longer read it and refuse to start while it is set without `SUICA_CONFIG`: rename it to `SUICA_CONFIG` in your shell profile.

The migration deletes the old app bundle, so replace **MR Review Assistant** with **Suica** under System Settings → General → Login Items; an old Login Item would point at nothing.

If the script says an old process is still running: its process check also matches any process whose command line contains `mr-review-assistant` or `MRAMenuBar` (for example an editor or `tail` on the old log files, or a checkout folder still named `mr-review-assistant`). Close it or run the script from a renamed folder, then run the script again.

## Menu bar app

A native macOS menu bar app shows what the agent last recorded and lets you handle held Teams messages without typing `suica` commands. The penguin icon shows how many messages need you; click it to see the status, the messages that need you (with **Send…**, **Skip** and **Retry**; Send asks you to confirm the text first), recent messages, and **Pause polling** / **Resume polling**, **Refresh**, **Open Suica…** (closes the popover and opens the app window, below) and **Quit**. Each recent message says how it ended: **Sent with your approval** (you pressed Send), **Sent without approval** (its flow is in `auto` mode), **Skipped by you**, **No longer needed**, or **Dry run, not sent**. Messages sent before this version show only **Sent**: the agent did not record approvals then. A Review Notice about an MR you approved in GitLab has a green check icon. The app is in English; the Teams messages it sends are not. It runs the `suica` CLI for everything (`suica state`, `suica send <id> --json`, …), so it follows the same rules as the CLI: at most once, working hours, obsolete messages skipped.

```bash
scripts/install-macos-app.sh      # builds, draws the icon (macos/make-icon.swift), installs ~/Applications/Suica.app and starts it
scripts/uninstall-macos-app.sh
```

The app needs the installed CLI: the install script finds `suica` on your `PATH` (or `~/.local/bin/suica`; set `SUICA_CLI` for another location), refuses without it, and bakes its absolute path into the app. The app itself does not need Node or the checkout once installed. Add it under System Settings → General → Login Items to start it at login. The app's own tests: `cd macos/Suica && swift test`.

## App window

**Open Suica…** in the menu bar popover opens a window with six sections. The app is in English. The window shows in the Dock while it is open and the app goes back to menu-bar-only when you close it. Switching sections, opening and closing the sidebar (its toolbar button or ⌃⌘S), new or changed messages, banners and the save bar are animated; Overview and Statistics switch to two columns when the window is wide enough; with **Reduce motion** on (System Settings → Accessibility → Display) they only fade.

- **Overview**: whether the background agent is running (with its pid), is installed but not running, or is not installed; **Restart agent**; paused or polling with **Pause polling** / **Resume polling**, the poll intervals, the last recorded poll (ok or failed, and the reason) and how many MRs are tracked and waiting; whether Teams is on; the config file, the state database file, the logs folder and the templates folder with a Show in Finder button each. A config error is shown here in red. **Language model** shows which coding agent CLIs are installed and lets you switch `model.cli` (Auto, Claude Code, Codex, Gemini CLI); it saves that one key without touching unsaved edits in Configuration, applies after **Restart agent**, and names the CLI in use with its path, or warns when the chosen one is not installed. A CLI is found when its executable (`claude`, `codex`, `gemini`) is in `PATH`, `~/.local/bin`, `~/.claude/local`, `~/.npm-global/bin`, `~/.bun/bin`, `~/.volta/bin`, the folder of the `node` running Suica, `/opt/homebrew/bin` or `/usr/local/bin`.
- **Review requests**: the open MRs where you are a Reviewer, grouped as **Waiting for you** (not a draft, and your state is still not reviewed, the same rule as the menu bar badge), **You reviewed** and **Drafts**, each with its count and in GitLab's order; the first MR waiting for you is selected. A row shows your own state when you have reviewed and how many Reviewers approved when someone besides you reviews it. A row also says when its review is queued, running now, ready, posted or failed. Select one to read its description, its changes (one diff per file, which you can fold) and its comments (GitLab's own activity, such as added commits, behind **Show GitLab activity**), with the branches, pipeline, whether merging squashes the commits (**Squash on merge** or **No squash**, with the project's squash setting applied), labels and each Reviewer's state on top and **Open in GitLab**, and **Review with agent** (or **Review again**) next to them. **Approve…** (asks first) approves the MR on GitLab as you, at the commit on screen: if the author pushed after you opened the MR, nothing is approved and you are asked to look again. It shows only when GitLab lets you approve, and becomes **Approved by you** once you have. The **Agent review** tab (marked • when a review waits for you) shows the state, which CLI reviewed which commit, why a run failed or was skipped, the review itself, and **Post to GitLab…** / **Discard**; while a review is queued or running the page reads the list again every 15 seconds. Links in descriptions and comments open only when they are http(s). The list loads when you open the section or press Refresh, and each MR once until the list is refreshed or you press its reload button.
- **Messages**: the same list, marks and actions as the popover (Send…, Skip, Retry), split into **Your MRs** (nudges and reminders to your Reviewers) and **Others' MRs** (Review Notices to the Authors of MRs you reviewed); each tab shows how many of its messages need you. The window and the popover share one model, so a message acted on in one cannot be sent twice from the other.
- **Statistics**: poll health over the last 24 hours and 7 days (ok and failed), counts over the last 14 days of Review Requests, activity on your MRs (reviewer state changes and comments that passed `ignoreAuthors`), nudges and reminders sent, Review Notices sent, a bar chart per day, and two turnaround times (median and 90th percentile, in whole minutes): from a Review Request to your review, and from a delivered nudge to that Reviewer's review, for reviews in the last 30 days (the request or nudge can be up to 60 days old). Review Requests and activity are counted as detected, before they are grouped into a summary notification; Teams messages are counted on the day of their last change. Paused polls are not logged.
- **Token usage**: the language model tokens the agent used (input, output, cache read and cache write, summed as one figure per tile): totals and run counts for the last 24 hours, 7 days and 30 days, a breakdown by purpose (Agent reviews, Replies, Other) over 30 days, and a bar chart per day for the last 14 days. Runs are kept for 90 days. Agent Reviews are recorded here; Teams messages come from templates and use no tokens.
- **Configuration**: a form with every key of the table above, grouped as GitLab, Polling, Notifications, Teams, Language model and Storage; **Use default** removes a key from the file, and so does clearing an optional text box (`gitlab.glabPath`, `teams.command`, `teams.templatesPath`, `statePath`); an empty GitLab host is refused by the agent. A section that is `null`, such as a bare `teams:` line, does not load (the agent reports it); the editor treats it as an empty section, so saving a key inside it repairs the file. **Save** is disabled while a field holds text that is not a value yet (an empty number box, a half-typed time like `09:3`) and while nothing changed. The agent checks the edit before it writes: unknown or wrong values and, with Teams on, a templates folder that does not load, are refused with a message next to the field and the file is left alone. While you have unsaved edits a bar at the bottom offers **Discard changes** and **Save** (the same as the toolbar). **Open config in editor** and **Open templates folder** are in the toolbar; templates are not edited in the app. If the file changed on disk while you were editing, Save is refused (`conflict`), your edits are kept and **Reload** shows the new file.

Edits apply only after **Restart agent**, which the window offers right after a save (and which is also on Overview). The agent reads its config once at start.

History is recorded by the background agent, so it starts only once the running agent has been restarted on this version (`suica agent install` or **Restart agent**); updating the files is not enough. Nothing from before is reconstructed. Poll log and history are kept for 90 days, like the Teams outbox.

The state database is at schema 7: schema 3 added the history tables (the app window), schema 4 the outbox's `approved` column (the approval marks above), schema 5 the `token_usage` table (Token usage), schema 6 the `agent_review` table (Agent Review), schema 7 its title, model and start columns. An older build refuses a schema it does not know. Going back to an older build is unsupported: stop the agent and the app, then set the version back by hand with `sqlite3 "<state database file>" 'PRAGMA user_version = 6'` (or `= 5` for a build from before Agent Review, `= 3` for one from before the approval marks, `= 2` for one from before the app window). The added tables and column stay in the file and are picked up again by a later upgrade.

## Run in the background

```bash
suica agent install      # writes the LaunchAgent (com.madhani.suica.agent) for this installation and starts it
suica agent uninstall    # stops it and removes the plist
```

`suica agent install` refuses to run without a config file, writes `~/Library/LaunchAgents/com.madhani.suica.agent.plist` pointing at the installed `main.ts` and the `node` that runs the CLI, and reloads and starts the agent. Run it again after reinstalling the CLI elsewhere; `scripts/install-cli.sh` does that for you when the agent is already installed.

Logs are JSON lines captured by launchd in `~/Library/Logs/suica/` (`stdout.log`, `stderr.log`). The agent does no rotation; at the default log level it writes only on start, stop and errors (an error is logged once per failure streak). Set `SUICA_LOG_LEVEL=debug` to see every poll. launchd restarts the agent only when it exits with an error, at most once a minute, and the installer refuses to run without a config file. The plist bakes in the absolute path of the `node` found when you ran the installer: re-run it after switching Node versions or moving the repository.

## Development

```bash
npm ci           # dev dependencies, in the checkout
npm run check    # typecheck, lint, prettier, tests
scripts/suica status   # the CLI straight from the checkout, without installing it
```

Source of truth for each behaviour is a test in `test/`. `src/events.ts`, `src/format.ts` and `src/scheduler.ts` are pure; process spawning (`src/exec.ts`), SQLite (`src/store.ts`) and the clock sit behind small interfaces.

## Known limits

- Polling stops while the Mac is fully asleep; the next poll after wake (within about 15 seconds) catches up from stored state and collapses a burst into one summary.
- Do not run `suica once` while the background agent is running: the two processes are not coordinated and can alert on the same event twice.
- If a notification fails halfway, the ones already shown are not repeated and the rest are dropped (an error is logged and reported once).
- If the state database cannot be written, alerts can repeat until it recovers; you are told once.
- "GitLab unreachable" is only reported after two failed polls in a row, because the network is often not up yet right after a wake.
- When an MR is merged or closed there is no final alert (only open MRs are watched).
- A comment that arrives in the same poll in which an MR is first tracked, or in which a draft becomes ready, is recorded silently.
- More than 100 open MRs on either list fails the poll with a notification (pagination is not implemented).
- `osascript` notifications cannot be clicked; install `terminal-notifier` for click-to-open.
- A Teams message is sent at most once: a failed or interrupted send is never repeated automatically.
- An MR is announced to its Author only once per round of your review.
- Teams planning starts from the moment Teams is enabled, and again after every period in which it was switched off; older history is never announced.
- An Agent Review starts only after the background agent's next poll (up to the poll interval), reviews code by reading only (no tests, no build), and reviews the branch tip at clone time; if the author pushes between the diff and the clone, the diff and the checkout can differ by that push.
- Agent Review runs with Claude Code or Codex only. Codex gets the review skill's text but not the other skills it refers to. Gemini CLI is detected but not used for reviews.
- Automatic reviews spend your model quota on every MR waiting for you that the agent has not reviewed (capped by `review.maxPerDay`); set `review.auto: false` to start reviews only by hand.
- Which further skills the model reads while following the review skill can differ between runs and models.
- A model CLI installed outside the folders listed under Overview is not found; there is no setting for its path.
- The menu bar app shows what the agent last recorded and refreshes every 30 seconds; the background agent (or `suica once`) has to have polled for its list to be current.
- Statistics start once the background agent was restarted on this version: there is no history before that, and it is kept for 90 days. The turnaround times stay empty until a request and its review are both recorded.
- The window refreshes every 30 seconds while it is open; the Configuration form is loaded when you open that section or press Reload.
- Saving the config rewrites the whole file: comments and values are kept, but indentation is normalised and flow lists such as `[a,b]` are respaced. Inside a list (`ignoreAuthors`, the working days) and the `people` map, the comments of the entries that stay are kept, and so is the comment after the list; a removed entry takes its comment with it, and a list item you change becomes a new item without one.
- **Restart agent** runs `launchctl kickstart -k`, which stops the running agent. A poll in progress is not waited for, so a Teams message being sent at that moment can be cut off; it stays `sending` and may have been delivered, so check Teams before deciding.
- The CLI's wrapper and the LaunchAgent hold the absolute `node` path, and the app holds the absolute path of the `suica` command: after switching Node versions run `scripts/install-cli.sh` again, and after installing the CLI somewhere else also run `scripts/install-macos-app.sh` again. Moving or deleting the checkout no longer matters once both are installed.
- An install path (`SUICA_PREFIX` or the node path) containing `"`, `$` or a backtick breaks the wrapper that `scripts/install-cli.sh` writes; install under a plain path.
- The app and the CLI speak a versioned JSON format (`contracts/agent-state.v1.json`, `contracts/status.v1.json`, `contracts/stats.v1.json`, `contracts/usage.v1.json`, `contracts/config.v1.json`, `contracts/reviews.v1.json`, `contracts/mr-detail.v1.json`); an app built for a different version shows "The agent speaks a newer protocol. Rebuild the app."
- The menu bar app gives a Send 300 seconds to finish (the CLI's own worst case with the default Teams timeouts is 210 s). If you raise `teams.callTimeoutSeconds`, raise `sendTimeout` in `macos/Suica/Sources/SuicaCore/AgentClient.swift` and run the install script again.
