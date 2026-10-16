# Suica

A personal background agent for macOS that polls GitLab on `repo.madhani.one` and shows a notification when someone requests your review (flow A) and when someone reviews or comments on your own merge requests (flow D). Vocabulary: [CONTEXT.md](CONTEXT.md). Design: [spec](docs/superpowers/specs/2026-10-14-mr-review-assistant-design.md). Plan 1 (alerts) and Plan 2 (Teams chats) are implemented; agent reviews come in Plan 3.

It only reads from GitLab. It never posts, approves or changes anything there. With Teams enabled it also chats colleagues as you, from fixed templates.

## Requirements

- Node 24 (see `.nvmrc`)
- [`glab`](https://gitlab.com/gitlab-org/cli) logged in to `repo.madhani.one` (`glab auth status`)
- Optional: `terminal-notifier` (`brew install terminal-notifier`) so that clicking a notification opens the MR. Without it the agent falls back to `osascript` and the notification is not clickable.

## Setup

```bash
npm ci
mkdir -p ~/.config/suica
printf 'gitlab:\n  hostname: repo.madhani.one\n' > ~/.config/suica/config.yaml
```

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
| `statePath`                        | `~/Library/Application Support/suica/state.db` | SQLite state file |

The first poll on a fresh state database records a baseline silently and shows one summary ("N MR menunggu review-mu"). History never alerts.

## Commands

```bash
scripts/suica once      # one poll now
scripts/suica status    # paused / baseline / tracked counts
scripts/suica pause     # stop polling (kill switch)
scripts/suica resume
```

The app window (below) runs these commands. They print one JSON document on stdout, can be used from a script, and (except `stats`) work even when the config file is broken:

```bash
scripts/suica status --json         # agent service, last poll, paused, intervals, paths; a broken config shows up as configError
scripts/suica stats                 # history statistics: last 14 days per day, turnaround over 30 days
scripts/suica config show --json    # every config key with the value in the file, the effective value, and the problems found
scripts/suica config set --json     # applies edits read from stdin (see below)
scripts/suica agent restart --json  # launchctl kickstart -k of the background agent
```

`config set --json` reads at most 1 MiB from stdin:

```json
{ "baseSha256": "<sha256 from config show, or null if the file does not exist>",
  "edits": [{ "path": ["polling", "activeSeconds"], "value": 90 }] }
```

A `value` of `null` removes the key, so the agent's default applies. It prints `{"status": …, "issues": [{"path": …, "message": …}], "sha256": …}` and exits 0 only for `saved`. The other statuses write nothing: `invalid` (the edited config would not load, or Teams is on and the templates folder does not load; `issues` names the keys), `conflict` (the file changed since `baseSha256` was read) and `bad-request` (not valid JSON, larger than 1 MiB, or it names a key that does not exist). A save is atomic and the file keeps mode `0600`. `agent restart --json` prints `{"status": …}` with `restarted`, `not-installed` or `failed` and exits 0 only for `restarted`.

## Teams

Teams is off until `teams.enabled: true`. Messages are chats from you, written from fixed Indonesian templates, sent as plain text and never by a language model.

- **Reviewer Nudge** to a Reviewer who is added to, or re-requested on, one of your non-draft MRs; one reminder if they are still `UNREVIEWED` 24 hours later; never to someone who already reviewed.
- **Review Notice** to the Author of an MR you reviewed (approved, requested changes or comments only), 10 minutes after you stopped changing your review.

A message that is no longer needed (the Reviewer has reviewed, the MR is gone) is skipped, also while it waits for your approval; `suica send` refuses it with `obsolete`. A reminder is due 24 hours after the nudge was actually delivered, never before.

Each flow has a send mode: `approval` (default; the message waits for you), `auto` (sent when due) or `dry-run` (rendered and recorded, never sent). Messages only go out in working hours (Mac local time) and wait in the queue otherwise.

```bash
scripts/suica pending [--all]   # list messages that need you (all statuses with --all)
scripts/suica send <id>         # send a pending message
scripts/suica skip <id>         # drop a message
scripts/suica retry <id>        # look the person up again after fixing teams.people
scripts/suica selftest          # send one test line to your own Teams notes chat
scripts/suica state             # the agent's state as one JSON document (used by the menu bar app)
```

Statuses in `suica pending`: `pending` waits for you; `unresolved` needs a `teams.people` line (then `suica retry`), or Teams returned an error for that person's lookup; `failed` is final; `sending` may have been delivered, so check Teams before deciding.

Templates are files in the templates folder: `nudge.txt`, `reminder.txt`, `notice.approved.txt`, `notice.changes.txt`, `notice.comments.txt`. Placeholders: `{{mr.title}}`, `{{mr.url}}`, `{{mr.iid}}`, `{{mr.project}}`, `{{person.name}}`, `{{owner.name}}`. An unknown placeholder stops startup instead of sending a broken message.

People are found through `teams.people`, then a cache, then an exact display-name match in Teams; anything uncertain is left for you.

## Moving from MR Review Assistant

Suica used to be called MR Review Assistant. If you ran it under the old name, run these three commands from the checkout, in this order:

```bash
scripts/migrate-to-suica.sh
scripts/install-launchagent.sh
scripts/install-macos-app.sh
```

`scripts/migrate-to-suica.sh` is a one-time move and is safe to run twice (a second run prints `already migrated` and changes nothing). It:

- stops the old LaunchAgent (`com.madhani.mr-review-assistant`) and quits the old menu bar app;
- refuses, before moving anything, if an old agent or app process is still running, if the old LaunchAgent is still loaded, or if any process (for example an agent started by hand with `npm start`) holds the old state database open;
- refuses, naming both paths, if an old folder and its new counterpart both exist (merge them by hand);
- moves `~/.config/mr-review-assistant` to `~/.config/suica`, `~/Library/Application Support/mr-review-assistant` to `~/Library/Application Support/suica`, and `~/Library/Logs/mr-review-assistant` to `~/Library/Logs/suica`, so the state database moves as it is;
- removes the old LaunchAgent plist and `~/Applications/MR Review Assistant.app`, so two menu bar icons never run against different paths;
- warns, without editing the file, for every line of the moved config that still names `mr-review-assistant` (for example an explicit `statePath` or `teams.templatesPath`; change those by hand);
- when it warns about such a line, ends by telling you to fix those keys first and only then run the two install scripts (an explicit old `statePath` would make the new agent recreate the old folder with a fresh database);
- warns if `MRA_CONFIG` is set. The agent and CLI no longer read it and refuse to start while it is set without `SUICA_CONFIG`: rename it to `SUICA_CONFIG` in your shell profile.

The migration deletes the old app bundle, so replace **MR Review Assistant** with **Suica** under System Settings → General → Login Items; an old Login Item would point at nothing.

If the script says an old process is still running: its process check also matches any process whose command line contains `mr-review-assistant` or `MRAMenuBar` (for example an editor or `tail` on the old log files, or a checkout folder still named `mr-review-assistant`). Close it or run the script from a renamed folder, then run the script again.

## Menu bar app

A native macOS menu bar app shows what the agent last recorded and lets you handle held Teams messages without typing `suica` commands. The icon shows how many messages need you; click it to see the status, the messages that need you (with **Send…**, **Skip** and **Retry**; Send asks you to confirm the text first), recent messages, and **Pause polling** / **Resume polling**, **Refresh**, **Open Suica…** (the app window, below) and **Quit**. The app is in English; the Teams messages it sends are not. It runs the `suica` CLI for everything (`suica state`, `suica send <id> --json`, …), so it follows the same rules as the CLI: at most once, working hours, obsolete messages skipped.

```bash
scripts/install-macos-app.sh      # builds, installs ~/Applications/Suica.app and starts it
scripts/uninstall-macos-app.sh
```

Add it under System Settings → General → Login Items to start it at login. The app's own tests: `cd macos/Suica && swift test`. It needs Swift (Xcode or the Command Line Tools) and Node.

## App window

**Open Suica…** in the menu bar popover opens a window with four sections. The app is in English. The window shows in the Dock while it is open and the app goes back to menu-bar-only when you close it.

- **Overview**: whether the background agent is running (with its pid), is installed but not running, or is not installed; **Restart agent**; paused or polling with **Pause polling** / **Resume polling**, the poll intervals, the last recorded poll (ok or failed, and the reason) and how many MRs are tracked and waiting; whether Teams is on; the config file, state folder, logs folder and templates folder with a Show in Finder button each. A config error is shown here in red.
- **Messages**: the same list and actions as the popover (Send…, Skip, Retry). The window and the popover share one model, so a message acted on in one cannot be sent twice from the other.
- **Statistics**: polls in the last 24 hours (ok and failed), counts over the last 14 days of Review Requests, activity on your MRs (reviewer state changes and comments that passed `ignoreAuthors`), nudges and Review Notices sent, a bar chart per day, and two turnaround times (median and 90th percentile, in whole minutes): from a Review Request to your review, and from a delivered nudge to that Reviewer's review, for reviews in the last 30 days. Review Requests and activity are counted as detected, before they are grouped into a summary notification; Teams messages are counted on the day of their last change. Paused polls are not logged.
- **Configuration**: a form with every key of the table above, grouped as GitLab, Polling, Notifications, Teams and Storage; **Use default** removes a key from the file. **Save** is disabled while a field holds text that is not a value yet (an empty number box, a half-typed time like `09:3`) and while nothing changed. The agent checks the edit before it writes: unknown or wrong values and, with Teams on, a templates folder that does not load, are refused with a message next to the field and the file is left alone. **Open config in editor** and **Open templates folder** are in the toolbar; templates are not edited in the app. If the file changed on disk while you were editing, Save is refused (`conflict`), your edits are kept and **Reload** shows the new file.

Edits apply only after **Restart agent**, which the window offers right after a save (and which is also on Overview). The agent reads its config once at start.

History starts when this version is installed; nothing from before is reconstructed. Poll log and history are kept for 90 days, like the Teams outbox.

## Run in the background

```bash
scripts/install-launchagent.sh     # renders the LaunchAgent (com.madhani.suica.agent) for this checkout and starts it
scripts/uninstall-launchagent.sh
```

Logs are JSON lines captured by launchd in `~/Library/Logs/suica/` (`stdout.log`, `stderr.log`). The agent does no rotation; at the default log level it writes only on start, stop and errors (an error is logged once per failure streak). Set `SUICA_LOG_LEVEL=debug` to see every poll. launchd restarts the agent only when it exits with an error, at most once a minute, and the installer refuses to run without a config file. The plist bakes in the absolute path of the `node` found when you ran the installer: re-run it after switching Node versions or moving the repository.

## Development

```bash
npm run check    # typecheck, lint, prettier, tests
```

Source of truth for each behaviour is a test in `test/`. `src/events.ts`, `src/format.ts` and `src/scheduler.ts` are pure; process spawning (`src/exec.ts`), SQLite (`src/store.ts`) and the clock sit behind small interfaces.

## Known limits

- Polling stops while the Mac is fully asleep; the next poll after wake (within about 15 seconds) catches up from stored state and collapses a burst into one summary.
- Do not run `scripts/suica once` while the background agent is running: the two processes are not coordinated and can alert on the same event twice.
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
- The Agent Review flow is not implemented yet.
- The menu bar app shows what the agent last recorded and refreshes every 30 seconds; the background agent (or `scripts/suica once`) has to have polled for its list to be current.
- Statistics start when this version is installed: there is no history before the upgrade, and it is kept for 90 days. The turnaround times stay empty until a request and its review are both recorded.
- The window refreshes every 30 seconds while it is open; the Configuration form is loaded when you open that section or press Reload.
- Saving the config rewrites the whole file: comments and values are kept, but indentation is normalised and flow lists such as `[a,b]` are respaced.
- A config file whose section is empty or `null` (for example a bare `teams:` line) cannot be repaired in the window: saving a key inside that section is refused. Fix the file in an editor.
- **Restart agent** runs `launchctl kickstart -k`, which stops the running agent. A poll in progress is not waited for, so a Teams message being sent at that moment can be cut off; it stays `sending` and may have been delivered, so check Teams before deciding.
- The install script bakes the absolute `node` and repository paths into the app: after moving the repository or switching Node versions, run `scripts/install-macos-app.sh` again.
- The app and the CLI speak a versioned JSON format (`contracts/agent-state.v1.json`, `contracts/status.v1.json`, `contracts/stats.v1.json`, `contracts/config.v1.json`); an app built for a different version shows "The agent speaks a newer protocol. Rebuild the app."
- The menu bar app gives a Send 300 seconds to finish (the CLI's own worst case with the default Teams timeouts is 210 s). If you raise `teams.callTimeoutSeconds`, raise `sendTimeout` in `macos/Suica/Sources/SuicaCore/AgentClient.swift` and run the install script again.
