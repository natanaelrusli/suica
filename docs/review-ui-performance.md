# Review UI performance tooling

Status: **partial; runnable parser/cache benchmark measured.** The broader model, UI, and accessibility work below remains outstanding.

## Runnable presentation parser/cache benchmark

Run from the repository root:

```sh
swift run -c release --package-path macos/Suica ReviewPresentationBenchmark
```

The executable constructs 100 `DiffFile` values with meaningful diff headers and repeated Swift code changes, totaling exactly 1,500,000 diff characters, plus a 100,000-byte Markdown body repeating a review link, Swift code block, table, and task list. It calls the production `ReviewPresentationCache.diffs` and `.blocks` once cold and once warm, measures each pair with `ContinuousClock`, and checks that warm results match cold results and retained source cost stays within the configured cache limit. It prints timings, cache cost/limit, OS version, and hardware architecture. It does not measure model selection, main-actor responsiveness, rendering, or paint latency; there is no wall-clock pass threshold.

Measured on the machine below with the command above:

```text
fixture.diffCharacters=1500000
fixture.markdownBytes=100000
cold.ms=50.827958
warm.ms=0.910166
cachedSourceCost=1605580
byteLimit=8388608
os=Version 26.2 (Build 25C56)
hardwareArchitecture=arm64
```

## Required fixture and metrics

The planned fixture has 200 `ReviewSummary` values, a selected detail with 1,500,000 diff characters, a 100 KB Markdown body, and fake detail reads delayed by 2 seconds. It must use the production `ReviewsModel(client:now:)` and `ReviewPresentationCache(byteLimit:)`, with a fake conforming to `ReviewsClient`; it must never instantiate `AgentClient`.

The harness must report cold and warm content preparation duration, cached model selection duration (selection completion only; **not paint latency**), list/detail fake call counts, `cachedSourceCost`, and machine model plus macOS version. For main-actor responsiveness, sample a main-actor heartbeat on a fixed cadence while preparation runs in a detached/background task; report maximum observed scheduling gap and cadence/sample count. This is only a scheduler responsiveness proxy: it does not measure SwiftUI rendering or user-visible paint latency.

## Broader model benchmark (outstanding)

The broader benchmark still requires a model fixture with the metrics below. No measurements for those metrics are available. The parser/cache slice above does not substitute for it. The intended command for that broader harness may be:

```sh
swift run --package-path macos/Suica -c release ReviewUIPerformance
```

Before/after comparison requires running the identical committed harness and fixture against the baseline and changed revisions on the same Mac and OS, recording both outputs. No before/after values have been collected.

## Manual UI procedure (outstanding)

Launch the real ReviewsView with offline clients using:

```sh
swift run --package-path macos/Suica Suica --review-ui-fixture
```

This separate entry point bypasses normal SuicaApp initialization, CLI clients, and startup services. It supplies 200 MRs, two-second detail reads, 100 files totaling 1,500,000 ASCII diff characters, and 100,000 Markdown bytes. Every mutation fails locally. The window starts at 1280 × 800 with a 760 × 480 minimum. Quit the fixture after checking it; no installed app is replaced.

The fixture compiled and launched at 1280 × 800 on the reference Mac. Automated native accessibility inspection failed with `process-identity-unavailable: Selected application does not expose a launch time; stable PID reuse checks are unavailable`. Thus no keyboard/VoiceOver/manual visual pass is claimed. Check 760 × 480 and 1280 × 800 sizes, resize with detail selected across the 900-point breakpoint, keyboard Back and focus restoration, VoiceOver action names, Reduce Motion, and scrolling during refresh. Never use real post/approve actions.

## Reference environment and broader results (outstanding)

Reference environment for parser/cache measurement: arm64, Version 26.2 (Build 25C56). The cold/warm numbers above cover only actor parsing and cache reuse. Cached selection, fake call counts, heartbeat, Instruments traces, paint latency, and main-thread interval claims remain unmeasured. No fabricated values are supplied.
