# Overview at a glance

## Problem

Overview spent its top row on things that are usually fine (the agent runs, polling polls) and said
some things twice: "Needs your attention" as a tile and as a card, tokens as a tile and in the week
card. It said nothing about your own MRs, and "Review requests 3" next to "Nothing is waiting for your
review" and "All 4" left you to work out what the numbers meant. The two widget columns ended at
different heights, and the week chart had no figures on its bars.

## Design

- **Status bar** replaces the quick-action row and the two health tiles: a dot and one word for the
  agent's health (`AgentHealth`, worst first: not installed, stopped, paused, last poll failed, ok),
  the last poll, interval and pid in a caption (a failed poll's reason on hover), and the quick
  actions as icon buttons named on hover. Tinted green, orange or red.
- **Four tiles**, each opening its page: Waiting for you (`ReviewListDocument.tally`: waiting,
  reviewed, drafts), Ready to approve, Needs your attention, Your MRs (`yourTally`: approved by every
  Reviewer, Agent Fixes ready; orange while a fix waits). Four in a row when wide, two by two otherwise.
- **Cards**: Waiting for your review beside Agent Review at one height (`Card.fillsHeight`); the
  messages card only while messages need you (the tile already says zero); the week across the page.
- **Last 7 days**: each day's count over its bar; the week's figures and token totals as a
  label/figure grid beside the chart, or side by side under it when narrow.

My call: the tokens tile went; the totals stay one glance down in the week card and on Token usage.
My call: the week card runs full width so the chart has room for its labels.

## Tests

`ShortcutsTests`: the tally with and without `me`, `yourTally` with ready and other fix states, the
health order, and their copy.
