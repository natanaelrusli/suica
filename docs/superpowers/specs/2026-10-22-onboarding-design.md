# First-run setup — design

Status: written from the Owner's request on 2026-10-22 ("Add an onboarding feature to help new user setup config on suica"). The Owner skipped the questions, so every choice below marked _my call_ is the builder's.

## What already existed

- `make install` writes a one-line `~/.config/suica/config.yaml` (`gitlab.hostname`) and runs `suica agent install`, which refuses to run without a config file.
- Configuration in the app edits every key, and says "No config file yet. Saving creates it." when there is none, but it opens on eight categories with dozens of settings and does not say which ones matter first.
- Nothing checks that `glab` is installed and signed in to the GitLab host before the agent starts polling and failing.

## What it adds

A **Set up Suica** sheet in the app window that a new user walks through once. It opens by itself when the window opens and the config file does not exist (_my call_: a missing file is the one sure sign of a first run; a file that exists but is broken goes to Configuration as before). **Set up Suica…** beside the "No config file yet" line in Configuration opens it again; it is not offered once the file exists, since the sheet creates the file and would conflict (_my call_).

Steps, with **Back** and **Continue**:

1. **Welcome**: what Suica does and what the next steps ask for.
2. **GitLab**: the host after a fixed `https://` (a pasted URL keeps only its host, as in Configuration) and **Check connection**, which runs `suica gitlab check <host> --json`. It shows "Signed in as @user" or what to do: install glab (`brew install glab`), or sign in with `glab auth login --hostname <host>` (with a copy button), or that the host cannot be reached. **Continue** needs a host; a failed or skipped check does not block it (_my call_: glab can be fixed later and the agent reports it), but the step says the agent will fail until it passes.
3. **Coding agent**: the same Auto / Claude Code / Codex / Gemini CLI cards as Configuration, showing which are installed (from `suica status --json`). Default Auto.
4. **Teams**: one switch, off by default, for `teams.enabled`, with what it needs (the Teams MCP at `teams.command`) and which messages wait for approval by default (nudges and most notices) and which go out at once (the findings and approved notices). Everything else about Teams stays in Configuration (_my call_).
5. **Finish**: a summary, then **Save and start agent**: writes the file with `suica config set --json` (`baseSha256: null`, so an existing file is never overwritten), then runs `suica agent install --json`. Only keys that differ from the default are written (`gitlab.hostname` always; `model.cli` unless Auto; `teams.enabled` only when on). On success the sheet says the agent is running and **Done** closes it and refreshes the window; a refused save or a failed install is shown in the sheet, with the agent's message, and the user can go back or retry.

Closing the sheet early (**Not now**) writes nothing; it opens again the next time the window opens while there is still no config file.

## CLI

- `suica gitlab check <host> --json`: works without a config file. Calls `glab api user --hostname <host>` with a 30 s timeout (_my call_) and prints `{"status": …, "username": … | null}` with `status` one of `ok`, `glab-missing`, `gitlab-auth`, `gitlab-unreachable`, `gitlab-error` (the poller's failure kinds) or `bad-host` (anything but a bare host name with an optional port; glab is not run). Exits 0 only for `ok`. Uses `glab` from `PATH` (_my call_: a new user has no `gitlab.glabPath` yet).
- `suica agent install --json`: the same install, printing `{"status": "installed" | "no-config" | "failed"}` and exiting 0 only for `installed`. Without `--json` it prints as before.

## Contracts

- `contracts/gitlab-check.v1.json`: the golden for `gitlab check`, read by the TypeScript test and the Swift decoder test. Action results reuse the existing `{"status": …}` shape.

## Left out

- No step for Agent Review, Agent Fix, polling or working hours: their defaults work, and Configuration covers them.
- No re-run of the sheet over an existing config file, and no "Install agent" button for a config that exists without an agent (Overview already says the agent is not installed).
- No change to the menu bar popover.
