import { IDLE_AFTER_MS, type OfficeStatus } from "./types.ts";

export interface ActivityFacts {
  readonly now: number;
  readonly lastActivityAt: number;
  /** The log says the agent waits for the Owner (a permission, a question). */
  readonly waiting?: boolean;
  /** The log says the agent finished its turn. */
  readonly finished?: boolean;
}

/** For agents that report no status themselves: derive it from the log's last activity. */
export function classifyByActivity(facts: ActivityFacts): OfficeStatus {
  if (facts.waiting === true) return "waiting";
  if (facts.finished === true) return "idle";
  return facts.now - facts.lastActivityAt > IDLE_AFTER_MS ? "idle" : "working";
}
