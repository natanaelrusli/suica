# Logs page — design

Status: written from the Owner's request on 2026-10-20 ("Add a log menu in the app to see error output or standard output log"). Choices marked _my call_ are the builder's and can be changed. Vocabulary is in `CONTEXT.md`.

## Intent

The background agent's logs live in `~/Library/Logs/suica/` (`stdout.log`, `stderr.log`, written by launchd). Until now the app could only show that folder in Finder. The Owner wants to read them in the app.

## Goals

- A **Logs** section in the window's sidebar (Insights group, after Token usage, ⌘6 in the Go menu) with **Output** and **Errors**.
- The page follows the file while it is open, like `tail -f`.

## Non-goals

- Clearing, rotating or exporting logs (_my call_: the files belong to launchd and the agent; Show in Finder covers the rest).
- Logs of the menu bar app itself: it writes none.
- A log tab in the menu bar popover (_my call_: too small for log lines; the window is one click away).

## Behaviour

- The folder comes from `suica status` (`paths.logs`), as on Overview; the app reads the files directly, without the CLI (_my call_: a read-only local file, and the CLI would add a process per tick).
- Only the last 512 KB is read, the first cut line dropped, with a note saying so (_my call_: the agent never rotates, so the file can grow without limit).
- The file is checked every two seconds and parsed again only when its size or modification date changed.
- JSON lines (the agent's logger) show time, level, message and `key=value` attributes; other lines are grouped into one entry until the next JSON line, so a stack trace stays readable.
- Oldest first, scrolled to the newest entry whenever one arrives. A search field filters on message, attributes and level.
- Overview's **Open logs** quick action now opens this page instead of Finder (_my call_); the System card keeps the folder's Show in Finder button.

## Tests

- `LogsTests.swift`: JSON parsing with sorted attributes and dates; plain lines grouped; JSON without a message treated as plain; search matching; reading the tail of a file and dropping the cut line; a missing file; the model switching streams.
