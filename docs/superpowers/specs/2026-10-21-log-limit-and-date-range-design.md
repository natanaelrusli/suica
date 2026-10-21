# Logs page: entry limit and date range — design

## Why

The Logs page showed the latest 500 entries, a number fixed in code, and only the end of the file (128 KB). The Owner wants 200 by default, to pick another number on the page, and to look at the entries of a given date range.

## What changes

- **Show** (a menu on the page) picks the limit: 50, 100, 200, 500, 1000 or 2000. The default is 200. The choice is stored with `@AppStorage("logsLimit")`, so it survives a relaunch. *My call:* a fixed menu, not a free number field, so nobody types 100000 and stalls the page.
- **Date range** (a checkbox and two date pickers) shows only entries written from the start of the first day to the end of the last, in the Mac's time zone; picking the days in reverse order works too. *My call:* whole days, no time of day, since the request said "date range" and two compact date pickers fit one row.
- An entry without a date (a Node stack trace) takes the date of the dated entry before it; one with no dated entry before it is left out while a range is set.
- The limit and the range apply in the model; the search field still filters what the model kept.

## Reading the file

The agent never rotates its logs, so the file grows without end. `LogsModel.load` reads the last 128 KB first and, while that read holds fewer than `limit + 1` entries in the range, reads four times as much again, up to 32 MB. It stops early once the oldest dated entry it read is before the range, since entries come in the order they were written. `truncated` (the "Showing the latest N entries." notice) is set when entries in the range were left out, by the limit or by the 32 MB ceiling.

A changed limit or range is part of the read key, so it reloads at once instead of waiting for the file to change.

## Not done

- No time-of-day in the range, no presets ("last hour"), no paging back past the limit.
- Parsing stays on the main actor, as before; a range far back in a log of tens of MB can take a moment.
