# System monitor — design

Status: written from the Owner's request on 2026-10-21 ("make a feature to monitor mac resource usages"). Choices marked _my call_ are the builder's.

## What it is

A **System** page in the app window that shows how hard this Mac is working right now: CPU, memory, disk, network, battery and thermal state, plus the processes using the most CPU or memory. It lives in the app only: the background agent and `suica` CLI do not take part (_my call_: the numbers belong to the Mac the app runs on, and the app can read them itself without a new CLI command or contract).

## Page

- Sidebar: **System** under **Insights**, after Logs, with a `cpu` symbol. The Go menu opens it with ⌘0, since ⌘1 to ⌘9 are taken (_my call_).
- Tiles, two columns when the page is wide, one when narrow:
  - **CPU**: total usage in percent (user + system, and nice time, which `top` also counts as busy: _my call_, while building), a line of the last two minutes, the load averages (1, 5, 15 minutes) and the core count.
  - **Memory**: used of total (Activity Monitor's "Memory Used": app memory + wired + compressed), a bar, swap used, and a line of the last two minutes.
  - **Disk**: used and free of the start-up volume ("available for important usage", as Finder counts it), with a bar.
  - **Network**: download and upload rates summed over every interface except loopback, and a line of the last two minutes.
  - **Battery**: charge, charging or on battery, and time left when macOS knows it. Hidden on a Mac without a battery.
  - **Thermal**: macOS's thermal state (nominal, fair, serious, critical) and the uptime.
- Bars and lines turn orange above 75 % and red above 90 % (_my call_). This applies to the CPU and memory lines and the memory and disk bars; the network lines have no ceiling to be a share of, and the battery bar stays green, since a full battery is good (_my call_, while building).
- **Top processes**: the ten processes with the highest CPU, or with the most memory, switched by a segmented control; name, PID, CPU % and memory. Read with `/bin/ps -Aceo pid=,pcpu=,rss=,comm=`, so processes of other users and root show too, without extra permissions.
- The page samples every two seconds while it is open and stops with it, as the Office does. History is kept in memory for the page's lifetime only (60 samples), never written to disk.

## Not done

- No menu bar readout, no alerts on high usage, no per-process history, no GPU or per-core figures, no killing processes. Each could come later; none was asked for.

## Tests

- Unit tests (SuicaCore): CPU usage from two tick samples (including a zero-delta sample), network rate from two counter samples (including a counter that wrapped or reset, which counts as zero), memory-used arithmetic from page counts, `ps` output parsing (spaces in command names, bad lines skipped) and the top-ten ordering, and the colour thresholds.
- The page itself is checked by eye with the scratch `NSHostingView` harness.
