import type { Intent, TeamsPlan, TeamsState } from "../src/teams/types.ts";
import { person } from "./builders.ts";

export const NOW = Date.UTC(2026, 9, 14, 3, 0);

export function intent(slot: number, overrides: Partial<Intent> = {}): Intent {
  return {
    dedupeKey: `nudge:g/p!5|bob:${slot}`,
    kind: "nudge",
    variant: "nudge",
    mr: {
      key: "g/p!5",
      iid: 5,
      projectPath: "g/p",
      title: "Add thing",
      url: "https://gitlab.example/g/p/-/merge_requests/5",
    },
    recipient: person("bob", "Bob"),
    ...overrides,
  };
}

export function teamsPlan(overrides: Partial<TeamsPlan> = {}): TeamsPlan {
  return {
    intents: [],
    nudgeUpdates: [],
    roundUpdates: [],
    keepNudges: [],
    keepRounds: [],
    rereviewMrs: new Map(),
    rereviewReviewers: new Map(),
    baselineDone: true,
    ...overrides,
  };
}

export function teamsState(overrides: Partial<TeamsState> = {}): TeamsState {
  return {
    baselineDone: true,
    nudges: new Map(),
    rounds: new Map(),
    undelivered: new Set(),
    rereviewMrs: new Map(),
    rereviewReviewers: new Map(),
    ...overrides,
  };
}
