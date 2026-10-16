# MR Review Assistant

A personal background agent for macOS that polls GitLab on `repo.madhani.one` and shows a notification when someone requests your review (flow A) and when someone reviews or comments on your own merge requests (flow D). Vocabulary: [CONTEXT.md](CONTEXT.md). Design: [spec](docs/superpowers/specs/2026-10-14-mr-review-assistant-design.md). Plan 1 (alerts) and Plan 2 (Teams chats) are implemented; agent reviews come in Plan 3.

It only reads from GitLab. It never posts, approves or changes anything there. With Teams enabled it also chats colleagues as you, from fixed templates.

## Requirements

- Node 24 (see `.nvmrc`)
- [`glab`](https://gitlab.com/gitlab-org/cli) logged in to `repo.madhani.one` (`glab auth status`)
- Optional: `terminal-notifier` (`brew install terminal-notifier`) so that clicking a notification opens the MR. Without it the agent falls back to `osascript` and the notification is not clickable.

## Setup

```bash
npm ci
mkdir -p ~/.config/mr-review-assistant
printf 'gitlab:\n  hostname: repo.madhani.one\n' > ~/.config/mr-review-assistant/config.yaml
```

Config file: `~/.config/mr-review-assistant/config.yaml` (override the path with `MRA_CONFIG`). Unknown keys are rejected so typos fail loudly.

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
| `teams.templatesPath`              | `~/.config/mr-review-assistant/templates` | Folder with template files                              |
| `teams.people`                     | `{}`                             | GitLab username → email, for people Teams cannot find by name    |
| `statePath`                        | `~/Library/Application Support/mr-review-assistant/state.db` | SQLite state file |

The first poll on a fresh state database records a baseline silently and shows one summary ("N MR menunggu review-mu"). History never alerts.

## Commands

```bash
scripts/mra once      # one poll now
scripts/mra status    # paused / baseline / tracked counts
scripts/mra pause     # stop polling (kill switch)
scripts/mra resume
```

## Teams

Teams is off until `teams.enabled: true`. Messages are chats from you, written from fixed Indonesian templates, sent as plain text and never by a language model.

- **Reviewer Nudge** to a Reviewer who is added to, or re-requested on, one of your non-draft MRs; one reminder if they are still `UNREVIEWED` 24 hours later; never to someone who already reviewed.
- **Review Notice** to the Author of an MR you reviewed (approved, requested changes or comments only), 10 minutes after you stopped changing your review.

Each flow has a send mode: `approval` (default; the message waits for you), `auto` (sent when due) or `dry-run` (rendered and recorded, never sent). Messages only go out in working hours (Mac local time) and wait in the queue otherwise.

```bash
scripts/mra pending [--all]   # list messages that need you (all statuses with --all)
scripts/mra send <id>         # send a pending message
scripts/mra skip <id>         # drop a message
scripts/mra retry <id>        # look the person up again after fixing teams.people
scripts/mra selftest          # send one test line to your own Teams notes chat
```

Statuses in `mra pending`: `pending` waits for you; `unresolved` needs a `teams.people` line (then `mra retry`); `failed` is final; `sending` may have been delivered, so check Teams before deciding.

Templates are files in the templates folder: `nudge.txt`, `reminder.txt`, `notice.approved.txt`, `notice.changes.txt`, `notice.comments.txt`. Placeholders: `{{mr.title}}`, `{{mr.url}}`, `{{mr.iid}}`, `{{mr.project}}`, `{{person.name}}`, `{{owner.name}}`. An unknown placeholder stops startup instead of sending a broken message.

People are found through `teams.people`, then a cache, then an exact display-name match in Teams; anything uncertain is left for you.

## Run in the background

```bash
scripts/install-launchagent.sh     # renders the LaunchAgent for this checkout and starts it
scripts/uninstall-launchagent.sh
```

Logs are JSON lines captured by launchd in `~/Library/Logs/mr-review-assistant/` (`stdout.log`, `stderr.log`). The agent does no rotation; at the default log level it writes only on start, stop and errors (an error is logged once per failure streak). Set `MRA_LOG_LEVEL=debug` to see every poll. launchd restarts the agent only when it exits with an error, at most once a minute, and the installer refuses to run without a config file. The plist bakes in the absolute path of the `node` found when you ran the installer: re-run it after switching Node versions or moving the repository.

## Development

```bash
npm run check    # typecheck, lint, prettier, tests
```

Source of truth for each behaviour is a test in `test/`. `src/events.ts`, `src/format.ts` and `src/scheduler.ts` are pure; process spawning (`src/exec.ts`), SQLite (`src/store.ts`) and the clock sit behind small interfaces.

## Known limits

- Polling stops while the Mac is fully asleep; the next poll after wake (within about 15 seconds) catches up from stored state and collapses a burst into one summary.
- Do not run `scripts/mra once` while the background agent is running: the two processes are not coordinated and can alert on the same event twice.
- If a notification fails halfway, the ones already shown are not repeated and the rest are dropped (an error is logged and reported once).
- If the state database cannot be written, alerts can repeat until it recovers; you are told once.
- "GitLab unreachable" is only reported after two failed polls in a row, because the network is often not up yet right after a wake.
- When an MR is merged or closed there is no final alert (only open MRs are watched).
- A comment that arrives in the same poll in which an MR is first tracked, or in which a draft becomes ready, is recorded silently.
- More than 100 open MRs on either list fails the poll with a notification (pagination is not implemented).
- `osascript` notifications cannot be clicked; install `terminal-notifier` for click-to-open.
- A Teams message is sent at most once: a failed or interrupted send is never repeated automatically.
- An MR is announced to its Author only once per round of your review.
- Teams planning starts from the moment Teams is enabled; older history is never announced.
- The Agent Review flow is not implemented yet.
