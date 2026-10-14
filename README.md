# MR Review Assistant

A personal background agent for macOS that polls GitLab on `repo.madhani.one` and shows a notification when someone requests your review (flow A) and when someone reviews or comments on your own merge requests (flow D). Vocabulary: [CONTEXT.md](CONTEXT.md). Design: [spec](docs/superpowers/specs/2026-10-14-mr-review-assistant-design.md). This is Plan 1 of three; Teams chats and agent reviews come in later plans.

It only reads from GitLab. It never posts, approves or changes anything there.

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
| `statePath`                        | `~/Library/Application Support/mr-review-assistant/state.db` | SQLite state file |

The first poll on a fresh state database records a baseline silently and shows one summary ("N MR menunggu review-mu"). History never alerts.

## Commands

```bash
scripts/mra once      # one poll now
scripts/mra status    # paused / baseline / tracked counts
scripts/mra pause     # stop polling (kill switch)
scripts/mra resume
```

## Run in the background

```bash
scripts/install-launchagent.sh     # renders the LaunchAgent for this checkout and starts it
scripts/uninstall-launchagent.sh
```

Logs are JSON lines captured by launchd in `~/Library/Logs/mr-review-assistant/` (`stdout.log`, `stderr.log`). The agent does no rotation; at the default log level it writes only on start, stop, pauses and errors. Set `MRA_LOG_LEVEL=debug` to see every poll. The plist bakes in the absolute path of the `node` found when you ran the installer: re-run it after switching Node versions or moving the repository.

## Development

```bash
npm run check    # typecheck, lint, prettier, tests
```

Source of truth for each behaviour is a test in `test/`. `src/events.ts`, `src/format.ts` and `src/scheduler.ts` are pure; process spawning (`src/exec.ts`), SQLite (`src/store.ts`) and the clock sit behind small interfaces.

## Known limits

- Polling stops while the Mac is fully asleep; the next poll after wake catches up from stored state and collapses a burst into one summary.
- When an MR is merged or closed there is no final alert (only open MRs are watched).
- A comment that arrives in the same poll in which an MR is first tracked, or in which a draft becomes ready, is recorded silently.
- More than 100 open MRs on either list fails the poll with a notification (pagination is not implemented).
- `osascript` notifications cannot be clicked; install `terminal-notifier` for click-to-open.
